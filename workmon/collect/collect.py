#!/usr/bin/env python3
"""workmon-collect: pull encrypted screenshots from workers, decrypt locally, push to SMB.

Runs on the admin laptop, which holds the ONLY private age identity. One pass over
all hosts in the hosts file; unreachable hosts are logged and skipped. Each host is
processed fully (pull -> decrypt -> upload -> free staging) before the next, to keep
memory/disk bounded.
"""
from __future__ import annotations

import argparse
import fcntl
import logging
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Execution happens via the symlink /usr/local/bin/workmon-collect -> /opt/.../collect.py.
# Make sure the directory next to the real file is in sys.path, so importing
# collect_common does not depend on exactly how the interpreter resolves the symlink.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

from collect_common import (  # noqa: E402
    DEFAULTS,
    VERSION,
    CollectError,
    CommandError,
    cleanup_paths,
    copy_atomic_to_share,
    date_from_filename,
    decrypt_age,
    describe_missing,
    ensure_dir,
    is_png,
    get_bool,
    load_config,
    mount_screenshots,
    parse_hosts_file,
    probe_host,
    require_programs,
    require_root,
    rsync_pull,
    rsync_pull_stream,
    sanitize_name,
    setup_logging,
    unmount_if_needed,
)


@dataclass
class HostReport:
    """Per-host result for the final run report."""
    host: str
    asset: Optional[str] = None
    # ok | unreachable | pull_error | skipped | error
    status: str = "ok"
    total: Optional[int] = None   # .age files on the worker at probe time (denominator)
    pulled: int = 0               # pulled during THIS run
    uploaded: int = 0             # successfully decrypted and uploaded to the share
    failed: int = 0               # failed to process (left in staging)
    note: str = ""                # explanation for the report (drop/skip reason)


class LiveProgress:
    """One-line live progress indicator for interactive runs. The same
    mechanism is used for both phases: pulling from the worker ('pull') and
    uploading to the share ('upload'). The phase is passed to each call.

    It redraws progress with '\\r' only when stdout is a terminal; under cron/systemd
    (non-TTY) it stays quiet, and per-host summaries plus normal logs provide the picture.
    It redraws at most once per second (min_interval) so fast runs do not flicker.
    """

    def __init__(self, min_interval: float = 1.0) -> None:
        self.enabled = sys.stdout.isatty()
        self.min_interval = min_interval
        self._last = 0.0
        self._active = False  # whether there is an active in-place line on screen

    def update(self, host: str, phase: str, done: int, total: Optional[int], *, force: bool = False) -> None:
        if not self.enabled:
            return
        now = time.monotonic()
        if not force and (now - self._last) < self.min_interval:
            return
        self._last = now
        denom = str(total) if total is not None else "?"
        line = f"[{host}] {phase}: {done}/{denom} files"
        # Return to the beginning of the line and clear the tail, without newline.
        sys.stdout.write("\r\x1b[2K" + line)
        sys.stdout.flush()
        self._active = True

    def interrupt(self) -> None:
        """Clear the current live line BEFORE logging anything over it; otherwise
        the log line would stick to the counter. The next update redraws it."""
        if not self.enabled or not self._active:
            return
        sys.stdout.write("\r\x1b[2K")
        sys.stdout.flush()
        self._active = False
        self._last = 0.0  # let the next update draw immediately instead of waiting a second

    def finish(self, host: str, phase: str, done: int, total: Optional[int]) -> None:
        """Final redraw plus newline so later logs do not stick to the live line."""
        if not self.enabled or not self._active:
            return
        self.update(host, phase, done, total, force=True)
        sys.stdout.write("\n")
        sys.stdout.flush()
        self._active = False

    def cleanup(self) -> None:
        """Emergency-close the live line with a newline, used by exception handling in main."""
        if self.enabled and self._active:
            sys.stdout.write("\n")
            sys.stdout.flush()
            self._active = False


def list_staged(staging_host_dir: Path) -> List[Path]:
    if not staging_host_dir.exists():
        return []
    return sorted(staging_host_dir.glob("*.age"), key=lambda p: (p.stat().st_mtime, p.name))


def png_name_for(encrypted: Path) -> str:
    name = encrypted.name
    if name.endswith(".age"):
        name = name[:-4]
    if not name.endswith(".png"):
        name = name + ".png"
    return name


def resolve_asset(explicit: Optional[str], remote_hostname: Optional[str], host: str) -> str:
    """Receiving folder name. Priority: explicit asset_id from hosts (if set) →
    worker hostname (made unique during hardware provisioning) →
    host string as a last-resort fallback."""
    if explicit:
        return explicit
    if remote_hostname:
        return sanitize_name(remote_hostname)
    return sanitize_name(host)


def move_processed(encrypted: Path, processed_root: Path, asset: str, upload_date: str) -> Path:
    target_dir = processed_root / asset / upload_date
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / encrypted.name
    idx = 1
    while target.exists():
        target = target_dir / f"{encrypted.name}.{idx}"
        idx += 1
    encrypted.replace(target)
    return target


def process_staged_file(
    config: dict,
    logger: logging.Logger,
    encrypted: Path,
    asset: str,
    private_key: Path,
    screenshot_mount: Path,
    decrypt_tmp_dir: Path,
    processed_root: Path,
) -> Tuple[bool, Optional[str]]:
    """Decrypt one .age file and upload the PNG to the share. Returns (ok, note):
    (True, None) on success, (False, <error text>) on failure. This function
    does not log success/failure at INFO level; the caller owns live progress and
    interrupts it only for real errors. The full upload path remains in DEBUG for troubleshooting."""
    upload_date = date_from_filename(encrypted)
    remote_output = config.get("REMOTE_OUTPUT_DIR", "out").strip("/")
    png_name = png_name_for(encrypted)
    # Path on the share: <output>/<date>/<hostname>/<file>, for example out/2026-07-08/tc-01/...
    remote_final = screenshot_mount / remote_output / upload_date / asset / png_name

    decrypted_partial = decrypt_tmp_dir / f"{png_name}.partial"
    decrypted_final = decrypt_tmp_dir / png_name

    cleanup_paths(decrypted_partial, decrypted_final)
    try:
        decrypt_age(config, logger, encrypted, private_key, decrypted_partial)
        if not is_png(decrypted_partial):
            # age returned 0, but the output is not a PNG — do not upload garbage to the share.
            raise CollectError("decrypted output is not a valid PNG (bad magic bytes)")
        decrypted_partial.replace(decrypted_final)
        copy_atomic_to_share(decrypted_final, remote_final)
        logger.debug("Uploaded: %s -> %s", encrypted.name, remote_final)

        if get_bool(config, "DELETE_STAGED_AFTER_UPLOAD"):
            encrypted.unlink()
        else:
            moved = move_processed(encrypted, processed_root, asset, upload_date)
            logger.debug("Archived staged file: %s", moved)
        return (True, None)
    except (CommandError, CollectError, OSError) as exc:
        # The only copy right now is here (already deleted on the worker). Do NOT touch
        # staged, so it can be retried on the next run. The caller logs the error.
        return (False, str(exc))
    finally:
        cleanup_paths(decrypted_partial, decrypted_final)


def process_host(
    config: dict,
    logger: logging.Logger,
    report: HostReport,
    private_key: Path,
    screenshot_mount: Path,
    decrypt_tmp_dir: Path,
    live: LiveProgress,
    *,
    remove_source: bool,
) -> None:
    """Pull + process one host. Reachability, worker name, and remote file count are
    already determined by the caller and stored in report. This function mutates
    report (pulled/uploaded/failed/status/note). It normally does not raise, but
    if something still bubbles up, main catches it and continues with the next host
    instead of aborting the whole run."""
    staging_root = Path(config.get("STAGING_DIR", "/var/lib/workmon-collect/staging"))
    processed_root = Path(config.get("PROCESSED_DIR", "/var/lib/workmon-collect/processed"))
    host = report.host
    asset = report.asset or sanitize_name(host)
    host_dir = staging_root / asset
    ensure_dir(host_dir, 0o700)

    def _on_progress(pulled: int) -> None:
        report.pulled = pulled
        live.update(host, "pull", pulled, report.total)

    live.update(host, "pull", 0, report.total, force=True)  # show the line immediately, before the first file
    ok, text, pulled = rsync_pull_stream(
        config, host, host_dir, logger, remove_source=remove_source, on_progress=_on_progress,
    )
    report.pulled = pulled
    live.finish(host, "pull", pulled, report.total)
    if ok:
        logger.info("Host %s: pull finished (%d files)", host, pulled)
    else:
        # The host dropped or the transfer broke. Mark it for the report, but do NOT
        # abort the run; below we still try to process whatever already landed in staging.
        report.status = "pull_error"
        report.note = f"pull interrupted: {text}"
        logger.error("Host %s: rsync pull failed: %s", host, text)

    staged = list_staged(host_dir)
    total = len(staged)
    if not staged:
        logger.info("Host %s: nothing to process in staging", host)
        return

    # Upload to the share uses the same live counter with phase "upload". The denominator
    # is known up front (how many .age files are in staging). There are no per-file
    # success logs: success is visible in the counter and per-host summary; each
    # failure interrupts the live line and gets logged.
    live.update(host, "upload", 0, total, force=True)
    done = 0
    for enc in staged:
        ok_file, err = process_staged_file(config, logger, enc, asset, private_key,
                                           screenshot_mount, decrypt_tmp_dir, processed_root)
        done += 1
        if ok_file:
            report.uploaded += 1
        else:
            report.failed += 1
            live.interrupt()  # clear the counter so the error does not stick to the line
            logger.error("Host %s: not processed %s (left in staging): %s", host, enc.name, err)
        live.update(host, "upload", done, total)
    live.finish(host, "upload", done, total)

    logger.info("Host %s: uploaded=%d failed=%d", host, report.uploaded, report.failed)
    # Failed decrypts/uploads are not a host drop; record a separate note without
    # overwriting the more important pull_error status.
    if report.failed and report.status == "ok":
        report.note = f"{report.failed} file(s) failed, left in staging"


def do_dry_run(config: dict, logger: logging.Logger, hosts: List[Tuple[str, Optional[str]]]) -> int:
    logger.info("DRY-RUN: reachability + hostname + rsync file listing, no removal, no upload")
    staging_root = Path(config.get("STAGING_DIR", "/var/lib/workmon-collect/staging"))
    seen_assets: Dict[str, str] = {}
    for host, explicit in hosts:
        reachable, remote_hostname, remote_count = probe_host(config, host, logger)
        if not reachable:
            logger.warning("Host %s: UNREACHABLE", host)
            continue
        asset = resolve_asset(explicit, remote_hostname, host)
        src = "explicit" if explicit else ("hostname" if remote_hostname else "host-fallback")
        if asset in seen_assets:
            logger.error("Host %s: asset %r collides with host %s (src=%s); would be SKIPPED",
                         host, asset, seen_assets[asset], src)
            continue
        seen_assets[asset] = host
        host_dir = staging_root / asset
        ok, stats = rsync_pull(config, host, host_dir, logger, remove_source=False, dry_run=True)
        cnt = f"{remote_count} files on worker" if remote_count is not None else "count unknown"
        if ok:
            transferred = next((ln.strip() for ln in stats.splitlines() if "files transferred" in ln.lower()), "stats unavailable")
            logger.info("Host %s -> asset=%s (src=%s); %s; %s", host, asset, src, cnt, transferred)
        else:
            logger.error("Host %s (asset=%s): rsync dry-run failed: %s", host, asset, stats)
    return 0


def validate_startup(config: dict, logger: logging.Logger) -> Optional[Path]:
    missing = require_programs(["ssh", "rsync", "age", "mount", "umount", "findmnt"])
    if missing:
        logger.error("Missing required program(s): %s", describe_missing(missing))
        return None
    private_key = Path(config.get("PRIVATE_KEY_FILE", "/etc/workmon-collect/private.key"))
    if not private_key.exists() or private_key.stat().st_size == 0:
        logger.error("Private age identity missing or empty: %s", private_key)
        return None
    smb_creds = Path(config.get("SMB_CREDENTIALS", "/etc/workmon-collect/smb.credentials"))
    if not smb_creds.exists():
        logger.error("SMB credentials file does not exist: %s", smb_creds)
        return None
    return private_key


def acquire_singleton_lock(logger: logging.Logger) -> Optional[int]:
    """Non-blocking exclusive lock on /run/workmon-collect/run.lock. Prevent two
    real runs from overlapping: two rsync --remove-source-files calls against the
    same spool can corrupt data. Keep the fd open for the whole run; the OS releases
    the lock when the process exits. Returns the fd, or None if another run holds it."""
    lock_dir = Path("/run/workmon-collect")
    try:
        ensure_dir(lock_dir, 0o700)
    except OSError:
        pass
    fd = os.open(str(lock_dir / "run.lock"), os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def main() -> int:
    parser = argparse.ArgumentParser(description="Collect, decrypt and upload WorkMon screenshots.")
    parser.add_argument("--dry-run", action="store_true", help="reachability + listing only")
    parser.add_argument("--hosts", type=str, default=None, help="override hosts file path")
    parser.add_argument("--host", action="append", default=None, help="limit to this host (repeatable)")
    parser.add_argument("--no-remove", action="store_true", help="do NOT delete source files on workers after pull")
    args = parser.parse_args()

    require_root()
    config = load_config()
    logger = setup_logging(config, "workmon.collect")
    logger.info("workmon-collect starting (v%s)", VERSION)

    for key in sorted(set(config) - set(DEFAULTS)):
        logger.warning("Unknown config key %r ignored (typo? not part of the schema)", key)

    hosts_file = Path(args.hosts) if args.hosts else Path(config.get("HOSTS_FILE", "/etc/workmon-collect/hosts"))
    try:
        hosts = parse_hosts_file(hosts_file)
    except CollectError as exc:
        logger.error("%s", exc)
        return 1
    if args.host:
        wanted = set(args.host)
        hosts = [(h, a) for (h, a) in hosts if h in wanted or (a is not None and a in wanted)]
    if not hosts:
        logger.error("No hosts to process (check %s / --host filter)", hosts_file)
        return 1

    if args.dry_run:
        return do_dry_run(config, logger, hosts)

    lock_fd = acquire_singleton_lock(logger)  # keep the fd open until the process ends
    if lock_fd is None:
        logger.error("Another workmon-collect run is already in progress; refusing to start.")
        return 1

    private_key = validate_startup(config, logger)
    if private_key is None:
        return 1

    decrypt_tmp_dir = Path(config.get("DECRYPT_TMP_DIR", "/run/workmon-collect/decrypted"))
    ensure_dir(Path(config.get("STAGING_DIR", "/var/lib/workmon-collect/staging")), 0o700)
    ensure_dir(decrypt_tmp_dir, 0o700)

    try:
        screenshot_mount, mounted = mount_screenshots(config, logger)
    except (CommandError, CollectError) as exc:
        logger.error("Cannot mount screenshot share; aborting (nothing pulled): %s", exc)
        return 1

    remove_source = not args.no_remove
    live = LiveProgress()
    reports: List[HostReport] = []
    seen_assets: Dict[str, str] = {}
    try:
        for host, explicit in hosts:
            report = HostReport(host=host)
            reports.append(report)
            try:
                reachable, remote_hostname, remote_count = probe_host(config, host, logger)
                if not reachable:
                    report.status = "unreachable"
                    report.note = "SSH unreachable"
                    logger.warning("Host %s unreachable over SSH; skipping", host)
                    continue
                asset = resolve_asset(explicit, remote_hostname, host)
                report.asset = asset
                report.total = remote_count
                src = "explicit" if explicit else ("hostname" if remote_hostname else "host-fallback")
                if asset in seen_assets:
                    report.status = "skipped"
                    report.note = f"asset {asset!r} already used by host {seen_assets[asset]}"
                    logger.error(
                        "Host %s: asset %r already used by host %s (src=%s); skipping "
                        "to avoid mixing screenshots from different machines",
                        host, asset, seen_assets[asset], src,
                    )
                    continue
                seen_assets[asset] = host
                logger.info("Host %s -> asset=%s (src=%s, files on worker: %s)",
                            host, asset, src, remote_count if remote_count is not None else "?")
                process_host(
                    config, logger, report, private_key, screenshot_mount, decrypt_tmp_dir, live,
                    remove_source=remove_source,
                )
            except Exception as exc:  # one bad host should not take down the whole run
                # Clear any possible live line and continue with the next host.
                live.cleanup()
                report.status = "error"
                report.note = str(exc)
                logger.exception("Host %s: unexpected error: %s", host, exc)
    finally:
        # Clean up any leftover plaintext remnants in tmpfs.
        cleanup_paths(*decrypt_tmp_dir.glob("*.png"), *decrypt_tmp_dir.glob("*.partial"))
        unmount_if_needed(screenshot_mount, mounted, logger)

    # ---- Final per-host report ----
    logger.info("──────── Per-host summary ────────")
    for r in reports:
        label = r.asset or r.host
        if r.status == "ok":
            processed = r.uploaded + r.failed
            note = f" — {r.note}" if r.note else ""
            logger.info("  %-20s uploaded %d of %d%s", label, r.uploaded, processed, note)
        elif r.status == "pull_error":
            denom = r.total if r.total is not None else "?"
            logger.warning("  %-20s DROP during pull: pulled %s/%s, uploaded %d — %s",
                           label, r.pulled, denom, r.uploaded, r.note)
        elif r.status == "unreachable":
            logger.warning("  %-20s UNREACHABLE over SSH — skipped", label)
        elif r.status == "skipped":
            logger.warning("  %-20s SKIPPED — %s", label, r.note)
        else:  # error
            logger.error("  %-20s ERROR — %s", label, r.note)

    hosts_ok = sum(1 for r in reports if r.status == "ok")
    unreachable = sum(1 for r in reports if r.status == "unreachable")
    skipped = sum(1 for r in reports if r.status == "skipped")
    dropped = [r for r in reports if r.status in ("pull_error", "error")]
    uploaded_total = sum(r.uploaded for r in reports)
    failed_total = sum(r.failed for r in reports)

    logger.info(
        "Total: hosts=%d ok=%d dropped=%d unreachable=%d skipped=%d | uploaded=%d failed=%d",
        len(reports), hosts_ok, len(dropped), unreachable, skipped, uploaded_total, failed_total,
    )
    if dropped:
        logger.warning("Dropped/failed during the run: %s",
                       ", ".join((r.asset or r.host) for r in dropped))

    if dropped or unreachable or skipped or failed_total:
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
    except Exception as exc:
        logging.basicConfig(level=logging.ERROR)
        logging.getLogger("workmon.collect").error("Fatal error: %s", exc)
        raise SystemExit(1)
