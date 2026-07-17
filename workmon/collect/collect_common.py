#!/usr/bin/env python3
"""
Shared helpers for workmon-collect (runs on the admin laptop only).

Pulls encrypted .age screenshots from remote workers over SSH+rsync, decrypts
them locally with the single private age identity, and pushes plaintext PNGs to
the SMB screenshot share. The private key lives ONLY on this machine.
"""
from __future__ import annotations

import datetime as _dt
import logging
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

APP_NAME = "workmon-collect"
VERSION = "0.1.3"
CONFIG_FILE = Path(os.environ.get("WORKMON_COLLECT_CONFIG", "/etc/workmon-collect/collect.conf"))

DEFAULTS: Dict[str, str] = {
    "HOSTS_FILE": "/etc/workmon-collect/hosts",
    # Collection over SSH
    "REMOTE_USER": "root",
    "REMOTE_SUDO": "false",
    "REMOTE_SPOOL": "/var/lib/workmon/spool",
    "SSH_KEY": "/etc/workmon-collect/id_collect",
    "SSH_CONNECT_TIMEOUT": "8",
    "SSH_STRICT_HOST_KEY": "accept-new",
    "SSH_KNOWN_HOSTS": "/var/lib/workmon-collect/known_hosts",
    "SSH_EXTRA_OPTS": "",
    "RSYNC_IO_TIMEOUT_SECONDS": "120",
    "RSYNC_TIMEOUT_SECONDS": "1800",
    # Local paths on the admin laptop
    "PRIVATE_KEY_FILE": "/etc/workmon-collect/private.key",
    "STAGING_DIR": "/var/lib/workmon-collect/staging",
    "PROCESSED_DIR": "/var/lib/workmon-collect/processed",
    "DECRYPT_TMP_DIR": "/run/workmon-collect/decrypted",
    "DELETE_STAGED_AFTER_UPLOAD": "true",
    # SMB receiver (plaintext screenshots)
    "SHARE_HOST": "smb.example.local",
    "SCREENSHOT_SHARE": "//smb.example.local/workmon-screenshots",
    "MOUNT_POINT_SCREENSHOTS": "/mnt/workmon-screenshots",
    "SMB_CREDENTIALS": "/etc/workmon-collect/smb.credentials",
    "SMB_VERSION": "3.1.1",
    "SMB_SEAL": "true",
    "CIFS_EXTRA_OPTIONS": "",
    "REMOTE_OUTPUT_DIR": "out",
    "MOUNT_TIMEOUT_SECONDS": "15",
    "COMMAND_TIMEOUT_SECONDS": "120",
    "LOG_LEVEL": "INFO",
}

SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9_.-]+")
STAMP_RE = re.compile(r"(20\d\d-[01]\d-[0-3]\d)_[0-2]\d-[0-5]\d-[0-5]\d")

PROGRAM_TO_PACKAGE: Dict[str, str] = {
    "ssh": "openssh-client",
    "rsync": "rsync",
    "age": "age",
    "mount": "util-linux",
    "umount": "util-linux",
    "findmnt": "util-linux",
}


class CollectError(RuntimeError):
    """Expected operational failure."""


class CommandError(CollectError):
    def __init__(self, message: str, result: Optional[subprocess.CompletedProcess[str]] = None):
        super().__init__(message)
        self.result = result


def load_config(path: Path = CONFIG_FILE) -> Dict[str, str]:
    config = DEFAULTS.copy()
    if path.exists():
        for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise CollectError(f"Invalid config line {line_no} in {path}: missing '='")
            key, value = line.split("=", 1)
            key = key.strip().upper()
            value = value.strip().strip('"').strip("'")
            if not key:
                raise CollectError(f"Invalid config line {line_no} in {path}: empty key")
            config[key] = value
    return config


def get_bool(config: Mapping[str, str], key: str) -> bool:
    return str(config.get(key, DEFAULTS.get(key, ""))).strip().lower() in {"1", "yes", "true", "on"}


def get_int(config: Mapping[str, str], key: str) -> int:
    value = str(config.get(key, DEFAULTS.get(key, "0"))).strip()
    try:
        return int(value)
    except ValueError as exc:
        raise CollectError(f"Config key {key} must be integer, got {value!r}") from exc


def setup_logging(config: Optional[Mapping[str, str]] = None, name: str = APP_NAME) -> logging.Logger:
    level_name = (config or DEFAULTS).get("LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    logger = logging.getLogger(name)
    logger.setLevel(level)
    logger.handlers.clear()
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    handler.setLevel(level)
    logger.addHandler(handler)
    logger.propagate = False
    return logger


def run_cmd(
    cmd: Sequence[str],
    *,
    logger: Optional[logging.Logger] = None,
    timeout: int = 120,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    safe_cmd = " ".join(shlex.quote(c) for c in cmd)
    if logger:
        logger.debug("Running command: %s", safe_cmd)
    try:
        result = subprocess.run(
            list(cmd), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise CommandError(f"Command timed out after {timeout}s: {safe_cmd}") from exc
    if check and result.returncode != 0:
        details = (result.stderr or "").strip() or (result.stdout or "").strip() or f"exit code {result.returncode}"
        raise CommandError(f"Command failed: {safe_cmd}: {details}", result)
    return result


def require_root() -> None:
    if os.geteuid() != 0:
        raise CollectError("This command must be run as root")


def require_programs(programs: Iterable[str]) -> List[str]:
    return [prog for prog in programs if shutil.which(prog) is None]


def describe_missing(programs: Iterable[str]) -> str:
    parts = []
    for prog in sorted(set(programs)):
        pkg = PROGRAM_TO_PACKAGE.get(prog)
        parts.append(f"{prog} (apt-get install {pkg})" if pkg else prog)
    return ", ".join(parts)


def sanitize_name(value: str) -> str:
    value = SAFE_NAME_RE.sub("-", value.strip()).strip(".-_")
    return (value or "unknown")[:128]


def ensure_dir(path: Path, mode: int = 0o700) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, mode)


def file_size_bytes(path: Path) -> int:
    try:
        return path.stat().st_size
    except FileNotFoundError:
        return 0


def date_from_filename(path: Path) -> str:
    match = STAMP_RE.search(path.name)
    if match:
        return match.group(1)
    return _dt.datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d")


def fsync_dir(path: Path) -> None:
    try:
        fd = os.open(str(path), os.O_DIRECTORY | os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# Hosts file
# ---------------------------------------------------------------------------

def parse_hosts_file(path: Path) -> List[Tuple[str, Optional[str]]]:
    """Lines: '<host> [asset_id]'. '#' comments and blank lines are ignored.
    asset_id is optional. If given, it is used as the sanitized folder name.
    If not given, None is returned and the caller falls back to the worker hostname.

    Explicit duplicate asset_ids are a config error and fail fast: two workers with
    the same name would merge screenshots into one folder without a log trace."""
    if not path.exists():
        raise CollectError(f"Hosts file not found: {path}")
    hosts: List[Tuple[str, Optional[str]]] = []
    explicit_seen: Dict[str, str] = {}
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        host = parts[0]
        asset: Optional[str] = None
        if len(parts) > 1:
            asset = sanitize_name(parts[1])
            if asset in explicit_seen:
                raise CollectError(
                    f"Hosts file line {line_no}: asset_id {asset!r} already used by "
                    f"host {explicit_seen[asset]!r}. Asset ids must be unique."
                )
            explicit_seen[asset] = host
        hosts.append((host, asset))
    return hosts


# ---------------------------------------------------------------------------
# SSH / rsync
# ---------------------------------------------------------------------------

def ssh_base_args(config: Mapping[str, str]) -> List[str]:
    args = ["ssh"]
    key = config.get("SSH_KEY", "").strip()
    if key:
        args += ["-i", key]
    args += [
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={get_int(config, 'SSH_CONNECT_TIMEOUT')}",
        "-o", f"StrictHostKeyChecking={config.get('SSH_STRICT_HOST_KEY', 'accept-new')}",
    ]
    known = config.get("SSH_KNOWN_HOSTS", "").strip()
    if known:
        args += ["-o", f"UserKnownHostsFile={known}"]
    extra = config.get("SSH_EXTRA_OPTS", "").strip()
    if extra:
        args += shlex.split(extra)
    return args


def probe_host(config: Mapping[str, str], host: str, logger: logging.Logger) -> Tuple[bool, Optional[str], Optional[int]]:
    """A single SSH connection checks reachability, pulls the worker short hostname
    (`hostname -s`) for the receiving folder name, and counts how many *.age files
    are in the remote spool. That count is the denominator for live pull progress.
    Returns (reachable, hostname, remote_age_count). hostname/count are None when
    the host is unreachable or output cannot be parsed; then the caller falls back
    to another naming source and progress runs without a denominator. Reading
    hostname does not require sudo; find over the spool uses sudo -n when configured
    (REMOTE_SUDO and non-root user)."""
    user = config.get("REMOTE_USER", "root")
    timeout = get_int(config, "SSH_CONNECT_TIMEOUT") + 5
    spool = config.get("REMOTE_SPOOL", "/var/lib/workmon/spool").rstrip("/")
    find_expr = f"find {shlex.quote(spool)} -maxdepth 1 -type f -name '*.age'"
    if get_bool(config, "REMOTE_SUDO") and user != "root":
        find_expr = "sudo -n " + find_expr
    # Prefix lines with H:/C: so parsing stays stable even if hostname is empty or
    # find writes something to stderr (which we suppress anyway).
    remote = (
        f'printf "H:%s\\n" "$(hostname -s 2>/dev/null)"; '
        f'printf "C:%s\\n" "$({find_expr} 2>/dev/null | wc -l)"'
    )
    result = run_cmd(
        ssh_base_args(config) + [f"{user}@{host}", remote],
        logger=logger, check=False, timeout=timeout,
    )
    if result.returncode != 0:
        return (False, None, None)
    hostname: Optional[str] = None
    count: Optional[int] = None
    for line in (result.stdout or "").splitlines():
        line = line.strip()
        if line.startswith("H:"):
            raw = line[2:].strip()
            # First token and the part before the first dot, in case -s returned an FQDN.
            short = raw.split()[0].split(".")[0] if raw else ""
            hostname = short or None
        elif line.startswith("C:"):
            raw = line[2:].strip()
            if raw.isdigit():
                count = int(raw)
    return (True, hostname, count)


def rsync_pull(
    config: Mapping[str, str],
    host: str,
    dest_dir: Path,
    logger: logging.Logger,
    *,
    remove_source: bool,
    dry_run: bool,
) -> Tuple[bool, str]:
    """Pulls only *.age files. remove_source=True removes ONLY successfully transferred
    files on the worker (rsync --remove-source-files). Returns (ok, stats_text)."""
    user = config.get("REMOTE_USER", "root")
    remote_spool = config.get("REMOTE_SPOOL", "/var/lib/workmon/spool").rstrip("/")
    ssh_cmd = " ".join(shlex.quote(a) for a in ssh_base_args(config))

    ensure_dir(dest_dir, 0o700)
    cmd = [
        "rsync", "-a",
        "--timeout", str(get_int(config, "RSYNC_IO_TIMEOUT_SECONDS")),
        "-e", ssh_cmd,
        # Pull and clean only .age files on the source, nothing else.
        "--include=*.age", "--exclude=*",
        "--stats",
    ]
    if get_bool(config, "REMOTE_SUDO") and user != "root":
        cmd += ["--rsync-path", "sudo -n rsync"]
    if dry_run:
        cmd += ["--dry-run"]
    elif remove_source:
        cmd += ["--remove-source-files"]
    cmd += [f"{user}@{host}:{remote_spool}/", f"{dest_dir}/"]

    timeout = get_int(config, "RSYNC_TIMEOUT_SECONDS")
    result = run_cmd(cmd, logger=logger, check=False, timeout=timeout)
    stats = (result.stdout or "").strip()
    if result.returncode != 0:
        err = (result.stderr or "").strip() or stats or f"exit {result.returncode}"
        return (False, err)
    return (True, stats)


def rsync_pull_stream(
    config: Mapping[str, str],
    host: str,
    dest_dir: Path,
    logger: logging.Logger,
    *,
    remove_source: bool,
    on_progress: Optional[Callable[[int], None]] = None,
) -> Tuple[bool, str, int]:
    """Like rsync_pull, but streams output. For each incoming *.age line it calls
    on_progress(pulled), which feeds the live pull counter. Returns
    (ok, text, pulled). IMPORTANT: pulled is the number of files transferred during
    THIS run only (rsync --out-format=%n lines); the true number of files in staging
    is still counted by the caller through list_staged, because previous leftovers
    may exist."""
    user = config.get("REMOTE_USER", "root")
    remote_spool = config.get("REMOTE_SPOOL", "/var/lib/workmon/spool").rstrip("/")
    ssh_cmd = " ".join(shlex.quote(a) for a in ssh_base_args(config))

    ensure_dir(dest_dir, 0o700)
    cmd: List[str] = []
    # stdbuf -oL (when available) line-buffers rsync stdout, so the counter ticks
    # smoothly instead of flushing in a batch at the end. Not critical: updates are
    # still throttled by the caller.
    if shutil.which("stdbuf"):
        cmd += ["stdbuf", "-oL"]
    cmd += [
        "rsync", "-a",
        "--timeout", str(get_int(config, "RSYNC_IO_TIMEOUT_SECONDS")),
        "-e", ssh_cmd,
        "--include=*.age", "--exclude=*",
        "--out-format=%n",   # exactly one line per transferred item
        "--stats",
    ]
    if get_bool(config, "REMOTE_SUDO") and user != "root":
        cmd += ["--rsync-path", "sudo -n rsync"]
    if remove_source:
        cmd += ["--remove-source-files"]
    cmd += [f"{user}@{host}:{remote_spool}/", f"{dest_dir}/"]

    timeout = get_int(config, "RSYNC_TIMEOUT_SECONDS")
    logger.debug("Running (stream): %s", " ".join(shlex.quote(c) for c in cmd))
    try:
        proc = subprocess.Popen(
            cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as exc:
        return (False, f"failed to start rsync: {exc}", 0)

    # Overall time ceiling. rsync --timeout catches stalled transfers (I/O), while
    # this watchdog limits the whole run. Kill the whole process group to catch
    # rsync SSH children too, not just rsync itself.
    killed = {"by_timeout": False}

    def _kill() -> None:
        killed["by_timeout"] = True
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except OSError:
            try:
                proc.kill()
            except OSError:
                pass

    watchdog = threading.Timer(timeout, _kill)
    watchdog.daemon = True
    watchdog.start()

    # Drain stderr in a separate thread: if only stdout is read, rsync can block
    # writing to a full stderr pipe (classic deadlock).
    stderr_chunks: List[str] = []

    def _drain_stderr() -> None:
        if proc.stderr is not None:
            stderr_chunks.append(proc.stderr.read() or "")

    err_thread = threading.Thread(target=_drain_stderr, daemon=True)
    err_thread.start()

    pulled = 0
    out_lines: List[str] = []
    try:
        if proc.stdout is not None:
            for raw in proc.stdout:
                line = raw.rstrip("\n")
                out_lines.append(line)
                # Count only .age files: the base directory line and --stats block do not end
                # with .age and should not contribute to the counter.
                if line.endswith(".age"):
                    pulled += 1
                    if on_progress is not None:
                        on_progress(pulled)
    finally:
        proc.wait()
        watchdog.cancel()
        err_thread.join(timeout=5)

    stderr = "".join(stderr_chunks).strip()
    if killed["by_timeout"]:
        return (False, f"rsync killed by overall timeout {timeout}s (pulled {pulled})", pulled)
    if proc.returncode != 0:
        err = stderr or "\n".join(out_lines).strip() or f"exit {proc.returncode}"
        return (False, err, pulled)
    return (True, "\n".join(out_lines).strip(), pulled)


# ---------------------------------------------------------------------------
# age decrypt
# ---------------------------------------------------------------------------

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def is_png(path: Path) -> bool:
    """PNG signature check (first 8 bytes). Cheap safety net for cases where age exits
    0 but the output is not an image (garbage/tampering). Reading a full hash back
    over SMB is expensive; magic bytes are almost free."""
    try:
        with path.open("rb") as fh:
            return fh.read(len(PNG_MAGIC)) == PNG_MAGIC
    except OSError:
        return False


def decrypt_age(config: Mapping[str, str], logger: logging.Logger, encrypted: Path, private_key: Path, output_partial: Path) -> None:
    timeout = get_int(config, "COMMAND_TIMEOUT_SECONDS")
    cmd = ["age", "--decrypt", "--identity", str(private_key), "--output", str(output_partial), str(encrypted)]
    run_cmd(cmd, logger=logger, timeout=timeout)
    if not output_partial.exists() or output_partial.stat().st_size == 0:
        raise CollectError("age decrypt completed but plaintext output is missing or empty")


# ---------------------------------------------------------------------------
# CIFS mount / copy
# ---------------------------------------------------------------------------

def is_mountpoint(path: Path, logger: logging.Logger) -> bool:
    # IMPORTANT: --target returns the mount containing the path (for a normal directory
    # that is the parent mount, e.g. '/'), producing a false True for any folder.
    # We need an exact test of this mount point; --mountpoint matches only it.
    result = run_cmd(["findmnt", "-rn", "--mountpoint", str(path)], logger=logger, check=False, timeout=10)
    return result.returncode == 0 and bool(result.stdout.strip())


def cifs_options(config: Mapping[str, str], *, credentials: str) -> str:
    opts = [
        f"credentials={credentials}",
        f"vers={config.get('SMB_VERSION', '3.1.1')}",
        "iocharset=utf8", "noserverino", "nosuid", "nodev", "noexec", "rw",
        "uid=0", "gid=0", "file_mode=0600", "dir_mode=0700",
    ]
    if get_bool(config, "SMB_SEAL"):
        opts.append("seal")
    extra = config.get("CIFS_EXTRA_OPTIONS", "").strip()
    if extra:
        opts.append(extra)
    return ",".join(opts)


def mount_screenshots(config: Mapping[str, str], logger: logging.Logger) -> Tuple[Path, bool]:
    share = config.get("SCREENSHOT_SHARE", "")
    mount_point = Path(config.get("MOUNT_POINT_SCREENSHOTS", "/mnt/workmon-screenshots"))
    if not share:
        raise CollectError("SCREENSHOT_SHARE is empty")
    ensure_dir(mount_point, 0o700)
    if is_mountpoint(mount_point, logger):
        logger.info("Screenshot share already mounted at %s", mount_point)
        return mount_point, False
    credentials = config.get("SMB_CREDENTIALS", "/etc/workmon-collect/smb.credentials")
    opts = cifs_options(config, credentials=credentials)
    run_cmd(["mount", "-t", "cifs", share, str(mount_point), "-o", opts],
            logger=logger, timeout=get_int(config, "MOUNT_TIMEOUT_SECONDS"))
    if not is_mountpoint(mount_point, logger):
        # mount returned 0, but the mount point is not active — do not write plaintext to local disk.
        raise CollectError(f"mount reported success but {mount_point} is not a mountpoint")
    logger.info("Mounted screenshot share %s at %s", share, mount_point)
    return mount_point, True


def unmount_if_needed(mount_point: Path, mounted_by_us: bool, logger: logging.Logger) -> None:
    if not mounted_by_us:
        return
    try:
        run_cmd(["umount", str(mount_point)], logger=logger, timeout=20)
        logger.info("Unmounted %s", mount_point)
    except Exception as exc:
        logger.warning("Failed to unmount %s: %s", mount_point, exc)


def copy_atomic_to_share(src: Path, dst: Path) -> None:
    """Write to *.partial → fsync → rename → fsync directory → size verification.
    This prevents a truncated file from appearing on the share as if it were complete.
    NB: over CIFS, rename-over-existing atomicity and fsync durability depend on the
    SMB server; this is good hygiene, not a hard POSIX guarantee like on a local FS."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    expected = file_size_bytes(src)
    partial = dst.with_name(dst.name + ".partial")
    try:
        if partial.exists():
            partial.unlink()
        with src.open("rb") as in_fh, partial.open("wb") as out_fh:
            shutil.copyfileobj(in_fh, out_fh, length=1024 * 1024)
            out_fh.flush()
            os.fsync(out_fh.fileno())
        os.replace(partial, dst)
        fsync_dir(dst.parent)
        actual = file_size_bytes(dst)
        if actual != expected or actual == 0:
            raise CollectError(f"Copied file verification failed: {dst} expected={expected} actual={actual}")
    finally:
        try:
            if partial.exists():
                partial.unlink()
        except OSError:
            pass


def cleanup_paths(*paths: Path) -> None:
    for path in paths:
        try:
            if path.exists():
                path.unlink()
        except OSError:
            pass
