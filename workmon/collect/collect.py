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
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Execution happens via the symlink /usr/local/bin/workmon-collect -> /opt/.../collect.py.
# We make sure the directory next to the real file is in sys.path, so that importing
# collect_common doesn't depend on exactly how the interpreter resolves the symlink.
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
    sanitize_name,
    setup_logging,
    unmount_if_needed,
)


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
    the worker's hostname (we make these unique during hardware provisioning) →
    the host string as a last-resort fallback."""
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
) -> bool:
    upload_date = date_from_filename(encrypted)
    remote_output = config.get("REMOTE_OUTPUT_DIR", "out").strip("/")
    png_name = png_name_for(encrypted)
    # Path on the share: <output>/<hostname>/<date>/<file>, e.g. out/tc-01/2026-07-08/…
    remote_final = screenshot_mount / remote_output / asset / upload_date / png_name

    decrypted_partial = decrypt_tmp_dir / f"{png_name}.partial"
    decrypted_final = decrypt_tmp_dir / png_name

    cleanup_paths(decrypted_partial, decrypted_final)
    try:
        decrypt_age(config, logger, encrypted, private_key, decrypted_partial)
        if not is_png(decrypted_partial):
            # age returned 0, but the output isn't a PNG — don't upload garbage to the share.
            raise CollectError("decrypted output is not a valid PNG (bad magic bytes)")
        decrypted_partial.replace(decrypted_final)
        copy_atomic_to_share(decrypted_final, remote_final)
        logger.info("Uploaded: %s -> %s", encrypted.name, remote_final)

        if get_bool(config, "DELETE_STAGED_AFTER_UPLOAD"):
            encrypted.unlink()
        else:
            moved = move_processed(encrypted, processed_root, asset, upload_date)
            logger.info("Archived staged file: %s", moved)
        return True
    except (CommandError, CollectError, OSError) as exc:
        # The only copy right now is here (already deleted on the worker). We do NOT touch
        # staged, so it gets retried on the next run.
        logger.error("Failed to process %s (kept in staging for retry): %s", encrypted.name, exc)
        return False
    finally:
        cleanup_paths(decrypted_partial, decrypted_final)


def process_host(
    config: dict,
    logger: logging.Logger,
    host: str,
    asset: str,
    private_key: Path,
    screenshot_mount: Path,
    decrypt_tmp_dir: Path,
    *,
    remove_source: bool,
) -> Tuple[str, int, int]:
    """Pull + process. Reachability and the worker's name have already been determined
    by the caller. Returns (status, uploaded, failed). status: ok|pull_error."""
    staging_root = Path(config.get("STAGING_DIR", "/var/lib/workmon-collect/staging"))
    processed_root = Path(config.get("PROCESSED_DIR", "/var/lib/workmon-collect/processed"))
    host_dir = staging_root / asset
    ensure_dir(host_dir, 0o700)

    ok, stats = rsync_pull(config, host, host_dir, logger, remove_source=remove_source, dry_run=False)
    if not ok:
        logger.error("Host %s: rsync pull failed: %s", host, stats)
        # Still try to process whatever is already sitting in staging from previous runs.
    else:
        logger.info("Host %s: pull complete", host)

    staged = list_staged(host_dir)
    if not staged:
        logger.info("Host %s: nothing to process in staging", host)
        return (("ok" if ok else "pull_error"), 0, 0)

    uploaded = failed = 0
    for enc in staged:
        if process_staged_file(config, logger, enc, asset, private_key, screenshot_mount, decrypt_tmp_dir, processed_root):
            uploaded += 1
        else:
            failed += 1
    logger.info("Host %s: uploaded=%s failed=%s", host, uploaded, failed)
    return (("ok" if ok else "pull_error"), uploaded, failed)


def do_dry_run(config: dict, logger: logging.Logger, hosts: List[Tuple[str, Optional[str]]]) -> int:
    logger.info("DRY-RUN: reachability + hostname + rsync file listing, no removal, no upload")
    staging_root = Path(config.get("STAGING_DIR", "/var/lib/workmon-collect/staging"))
    seen_assets: Dict[str, str] = {}
    for host, explicit in hosts:
        reachable, remote_hostname = probe_host(config, host, logger)
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
        if ok:
            transferred = next((ln.strip() for ln in stats.splitlines() if "files transferred" in ln.lower()), "stats unavailable")
            logger.info("Host %s -> asset=%s (src=%s); %s", host, asset, src, transferred)
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
    """Non-blocking exclusive lock on /run/workmon-collect/run.lock. Prevents two real
    runs from overlapping: two rsync --remove-source-files calls against the same
    spool would corrupt data. We keep the fd open for the whole run; the OS releases
    the lock when the process exits. Returns the fd, or None if the lock is already
    held by another run."""
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
    totals = {"ok": 0, "unreachable": 0, "pull_error": 0}
    uploaded_total = failed_total = 0
    seen_assets: Dict[str, str] = {}
    try:
        for host, explicit in hosts:
            try:
                reachable, remote_hostname = probe_host(config, host, logger)
                if not reachable:
                    logger.warning("Host %s unreachable over SSH; skipping", host)
                    totals["unreachable"] += 1
                    continue
                asset = resolve_asset(explicit, remote_hostname, host)
                src = "explicit" if explicit else ("hostname" if remote_hostname else "host-fallback")
                if asset in seen_assets:
                    logger.error(
                        "Host %s: resolved asset %r already used by host %s (src=%s); skipping "
                        "to avoid mixing screenshots from different machines",
                        host, asset, seen_assets[asset], src,
                    )
                    totals["pull_error"] += 1
                    continue
                seen_assets[asset] = host
                logger.info("Host %s -> asset=%s (src=%s)", host, asset, src)
                status, up, fail = process_host(
                    config, logger, host, asset, private_key, screenshot_mount, decrypt_tmp_dir,
                    remove_source=remove_source,
                )
            except Exception as exc:  # one bad host shouldn't take down the whole run
                logger.exception("Host %s: unexpected error: %s", host, exc)
                status, up, fail = "pull_error", 0, 0
            totals[status] = totals.get(status, 0) + 1
            uploaded_total += up
            failed_total += fail
    finally:
        # Clean up any leftover plaintext remnants in tmpfs.
        cleanup_paths(*decrypt_tmp_dir.glob("*.png"), *decrypt_tmp_dir.glob("*.partial"))
        unmount_if_needed(screenshot_mount, mounted, logger)

    logger.info(
        "Run finished: hosts_ok=%s unreachable=%s pull_error=%s uploaded=%s failed=%s",
        totals.get("ok", 0), totals.get("unreachable", 0), totals.get("pull_error", 0),
        uploaded_total, failed_total,
    )
    if totals.get("unreachable", 0) or totals.get("pull_error", 0) or failed_total:
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
