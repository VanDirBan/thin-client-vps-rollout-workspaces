#!/usr/bin/env python3
"""
Shared helpers for the WorkMon worker agent (capture-only).

This slim agent only captures the local X11 screen, encrypts each frame with a
public age recipient, and stores .age files in a root-only spool. It performs NO
network I/O, NO decryption, and never holds a private key. Collection and
decryption happen off-box on a separate admin laptop (see workmon-collect).
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import logging
import os
import pwd
import re
import shlex
import shutil
import socket
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, Iterator, List, Mapping, Optional, Sequence, Tuple

APP_NAME = "workmon"
VERSION = "0.4.0"
CONFIG_FILE = Path(os.environ.get("WORKMON_CONFIG", "/etc/workmon/workmon.conf"))

OPT_DIR = Path("/opt/workmon")
ETC_DIR = Path("/etc/workmon")
STATE_DIR = Path("/var/lib/workmon")
TMP_DIR = STATE_DIR / "tmp"
SPOOL_DIR = STATE_DIR / "spool"

DEFAULTS: Dict[str, str] = {
    "SCREENSHOT_INTERVAL_SECONDS": "5",
    "LOCAL_SPOOL_MAX_MB": "5000",
    "ASSET_ID_FILE": "/etc/workmon/asset_id",
    "PUBLIC_KEY_FILE": "/etc/workmon/public.key",
    "SCREENSHOT_FORMAT": "png",
    "CAPTURE_BACKEND": "scrot",
    "ENCRYPTION_BACKEND": "age",
    "SKIP_IDENTICAL_FRAMES": "true",
    "GUI_USER": "",
    "PRIMARY_USER": "",
    "COMMAND_TIMEOUT_SECONDS": "60",
    "LOG_LEVEL": "INFO",
}

SAFE_ASSET_RE = re.compile(r"[^A-Za-z0-9_.-]+")

PROGRAM_TO_PACKAGE: Dict[str, str] = {
    "scrot": "scrot",
    "import": "imagemagick",
    "age": "age",
}


class WorkMonError(RuntimeError):
    """Base error for expected operational failures."""


class CommandError(WorkMonError):
    def __init__(self, message: str, result: Optional[subprocess.CompletedProcess[str]] = None):
        super().__init__(message)
        self.result = result


@dataclass(frozen=True)
class GuiSession:
    session_id: str
    username: str
    uid: int
    display: str
    xauthority: Path
    env: Dict[str, str]


def load_config(path: Path = CONFIG_FILE) -> Dict[str, str]:
    config = DEFAULTS.copy()
    if path.exists():
        for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise WorkMonError(f"Invalid config line {line_no} in {path}: missing '='")
            key, value = line.split("=", 1)
            key = key.strip().upper()
            value = value.strip().strip('"').strip("'")
            if not key:
                raise WorkMonError(f"Invalid config line {line_no} in {path}: empty key")
            config[key] = value
    return config


def get_bool(config: Mapping[str, str], key: str) -> bool:
    return str(config.get(key, DEFAULTS.get(key, ""))).strip().lower() in {"1", "yes", "true", "on"}


def get_int(config: Mapping[str, str], key: str) -> int:
    value = str(config.get(key, DEFAULTS.get(key, "0"))).strip()
    try:
        return int(value)
    except ValueError as exc:
        raise WorkMonError(f"Config key {key} must be integer, got {value!r}") from exc


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
    env: Optional[Mapping[str, str]] = None,
    timeout: int = 60,
    check: bool = True,
    input_text: Optional[str] = None,
) -> subprocess.CompletedProcess[str]:
    safe_cmd = " ".join(shlex.quote(c) for c in cmd)
    if logger:
        logger.debug("Running command: %s", safe_cmd)
    try:
        result = subprocess.run(
            list(cmd),
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=dict(env) if env is not None else None,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise CommandError(f"Command timed out after {timeout}s: {safe_cmd}") from exc
    if check and result.returncode != 0:
        details = (result.stderr or "").strip() or (result.stdout or "").strip() or f"exit code {result.returncode}"
        raise CommandError(f"Command failed: {safe_cmd}: {details}", result)
    return result


def require_root() -> None:
    if os.geteuid() != 0:
        raise WorkMonError("This command must be run as root")


def require_programs(programs: Iterable[str]) -> List[str]:
    return [prog for prog in programs if shutil.which(prog) is None]


def describe_missing(programs: Iterable[str]) -> str:
    parts = []
    for prog in sorted(set(programs)):
        pkg = PROGRAM_TO_PACKAGE.get(prog)
        parts.append(f"{prog} (apt-get install {pkg})" if pkg else prog)
    return ", ".join(parts)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_dir(path: Path, mode: int = 0o700) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, mode)


def ensure_base_dirs() -> None:
    ensure_dir(TMP_DIR, 0o700)
    ensure_dir(SPOOL_DIR, 0o700)


def sanitize_asset_id(value: str) -> str:
    value = value.strip()
    value = SAFE_ASSET_RE.sub("-", value)
    value = value.strip(".-_")
    return (value or "unknown-asset")[:128]


def get_hostname() -> str:
    return sanitize_asset_id(socket.gethostname().split(".", 1)[0] or "unknown-host")


def get_asset_id(config: Mapping[str, str]) -> str:
    asset_file = Path(config.get("ASSET_ID_FILE", DEFAULTS["ASSET_ID_FILE"]))
    if asset_file.exists():
        return sanitize_asset_id(asset_file.read_text(encoding="utf-8").strip())
    return get_hostname()


def preferred_gui_user(config: Mapping[str, str]) -> str:
    return (config.get("GUI_USER", "").strip() or config.get("PRIMARY_USER", "").strip())


def now_local() -> _dt.datetime:
    return _dt.datetime.now().astimezone()


def timestamp_for_filename(ts: Optional[_dt.datetime] = None) -> str:
    ts = ts or now_local()
    return ts.strftime("%Y-%m-%d_%H-%M-%S")


def file_size_bytes(path: Path) -> int:
    try:
        return path.stat().st_size
    except FileNotFoundError:
        return 0


def list_spool_files() -> List[Path]:
    if not SPOOL_DIR.exists():
        return []
    return sorted(SPOOL_DIR.glob("*.age"), key=lambda p: (p.stat().st_mtime, p.name))


def rotate_spool(config: Mapping[str, str], logger: logging.Logger) -> None:
    max_mb = get_int(config, "LOCAL_SPOOL_MAX_MB")
    if max_mb <= 0:
        return
    max_bytes = max_mb * 1024 * 1024
    encrypted_files = list_spool_files()
    total = sum(file_size_bytes(p) for p in encrypted_files)
    deleted = 0
    for path in encrypted_files:
        if total <= max_bytes:
            break
        size = file_size_bytes(path)
        try:
            path.unlink()
            total -= size
            deleted += 1
            logger.warning("Spool limit exceeded; deleted oldest encrypted file: %s", path.name)
        except OSError as exc:
            logger.error("Failed to delete old spool file %s: %s", path.name, exc)
            break
    if deleted:
        logger.warning("Spool rotation completed; deleted=%s remaining_mb=%.2f", deleted, total / 1024 / 1024)


def parse_loginctl_properties(text: str) -> Dict[str, str]:
    props: Dict[str, str] = {}
    for raw in text.splitlines():
        if "=" in raw:
            key, value = raw.split("=", 1)
            props[key] = value
    return props


def read_proc_environ(pid: int | str) -> Dict[str, str]:
    env: Dict[str, str] = {}
    try:
        raw = Path(f"/proc/{pid}/environ").read_bytes()
    except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
        return env
    for chunk in raw.split(b"\0"):
        if not chunk or b"=" not in chunk:
            continue
        key, value = chunk.split(b"=", 1)
        try:
            env[key.decode()] = value.decode(errors="replace")
        except UnicodeDecodeError:
            continue
    return env


def list_loginctl_sessions(logger: logging.Logger) -> List[Tuple[str, Dict[str, str]]]:
    if shutil.which("loginctl") is None:
        logger.warning("loginctl not found; will try /proc X11 discovery fallback")
        return []
    result = run_cmd(["loginctl", "list-sessions", "--no-legend"], logger=logger, check=False, timeout=10)
    sessions: List[Tuple[str, Dict[str, str]]] = []
    for raw in result.stdout.splitlines():
        parts = raw.split()
        if not parts:
            continue
        sid = parts[0]
        show = run_cmd(
            ["loginctl", "show-session", sid,
             "-p", "Id", "-p", "Name", "-p", "User", "-p", "Display",
             "-p", "Type", "-p", "Class", "-p", "State", "-p", "Active",
             "-p", "Remote", "-p", "Leader"],
            logger=logger, check=False, timeout=10,
        )
        sessions.append((sid, parse_loginctl_properties(show.stdout)))
    return sessions


def find_xauthority(username: str, uid: int, leader_pid: Optional[int], env: Mapping[str, str]) -> Optional[Path]:
    candidates: List[Path] = []
    if env.get("XAUTHORITY"):
        candidates.append(Path(env["XAUTHORITY"]))
    try:
        home = Path(pwd.getpwnam(username).pw_dir)
        candidates.extend([home / ".Xauthority", home / ".xauth" / "Xauthority"])
    except KeyError:
        pass
    candidates.extend([
        Path(f"/var/run/lightdm/{username}/xauthority"),
        Path(f"/run/lightdm/{username}/xauthority"),
        Path(f"/run/user/{uid}/gdm/Xauthority"),
        Path(f"/run/user/{uid}/*/Xauthority"),
        Path(f"/run/user/{uid}/.Xauthority"),
        Path(f"/run/user/{uid}/Xauthority"),
    ])
    expanded: List[Path] = []
    for candidate in candidates:
        if "*" in str(candidate):
            try:
                expanded.extend(sorted(candidate.parent.glob(candidate.name)))
            except OSError:
                continue
        else:
            expanded.append(candidate)
    for candidate in expanded:
        try:
            if candidate.exists():
                return candidate
        except OSError:
            continue
    return None


def make_gui_session(session_id: str, username: str, uid: int, display: str, xauthority: Path, proc_env: Mapping[str, str]) -> GuiSession:
    try:
        home = pwd.getpwnam(username).pw_dir
    except KeyError:
        home = f"/home/{username}"
    env = os.environ.copy()
    env.update({
        "DISPLAY": display,
        "XAUTHORITY": str(xauthority),
        "XDG_SESSION_TYPE": "x11",
        "USER": username,
        "LOGNAME": username,
        "HOME": home,
    })
    if proc_env.get("DBUS_SESSION_BUS_ADDRESS"):
        env["DBUS_SESSION_BUS_ADDRESS"] = proc_env["DBUS_SESSION_BUS_ADDRESS"]
    elif Path(f"/run/user/{uid}/bus").exists():
        env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{uid}/bus"
    return GuiSession(session_id, username, uid, display, xauthority, env)


def find_active_x11_session_loginctl(config: Mapping[str, str], logger: logging.Logger) -> Optional[GuiSession]:
    preferred_user = preferred_gui_user(config)
    sessions = list_loginctl_sessions(logger)
    candidates: List[Tuple[str, Dict[str, str]]] = []
    for sid, props in sessions:
        if props.get("Type") != "x11":
            continue
        if props.get("Class") not in {"user", "greeter", ""}:
            continue
        if props.get("Remote") == "yes":
            continue
        if props.get("State") not in {"active", "online"} and props.get("Active") != "yes":
            continue
        if preferred_user and props.get("Name") != preferred_user:
            continue
        candidates.append((sid, props))
    if not candidates:
        for sid, props in sessions:
            if props.get("Type") == "x11" and props.get("Remote") != "yes":
                if preferred_user and props.get("Name") != preferred_user:
                    continue
                candidates.append((sid, props))
    for sid, props in candidates:
        username = props.get("Name") or preferred_user
        if not username:
            continue
        try:
            uid = int(props.get("User", str(pwd.getpwnam(username).pw_uid)))
        except (ValueError, KeyError):
            logger.debug("Skipping session %s: cannot resolve uid/user", sid)
            continue
        try:
            leader_pid = int(props.get("Leader", "0")) or None
        except ValueError:
            leader_pid = None
        proc_env = read_proc_environ(leader_pid) if leader_pid else {}
        display = props.get("Display") or proc_env.get("DISPLAY") or ":0"
        xauthority = find_xauthority(username, uid, leader_pid, proc_env)
        if not xauthority:
            logger.info("X11 session found for %s on %s, but XAUTHORITY is unavailable", username, display)
            continue
        return make_gui_session(sid, username, uid, display, xauthority, proc_env)
    return None


def iter_proc_x11_candidates(config: Mapping[str, str]) -> Iterator[GuiSession]:
    preferred_user = preferred_gui_user(config)
    for proc_dir in Path("/proc").iterdir():
        if not proc_dir.name.isdigit():
            continue
        try:
            uid = proc_dir.stat().st_uid
            username = pwd.getpwuid(uid).pw_name
        except (OSError, KeyError):
            continue
        if preferred_user and username != preferred_user:
            continue
        env = read_proc_environ(proc_dir.name)
        if env.get("XDG_SESSION_TYPE") != "x11":
            continue
        display = env.get("DISPLAY")
        if not display:
            continue
        xauthority = find_xauthority(username, uid, int(proc_dir.name), env)
        if not xauthority:
            continue
        yield make_gui_session(f"proc:{proc_dir.name}", username, uid, display, xauthority, env)


def find_active_x11_session(config: Mapping[str, str], logger: logging.Logger) -> Optional[GuiSession]:
    session = find_active_x11_session_loginctl(config, logger)
    if session:
        return session
    for session in iter_proc_x11_candidates(config):
        logger.info("Using /proc X11 discovery fallback: user=%s display=%s pid=%s", session.username, session.display, session.session_id)
        return session
    return None


def atomic_rename(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    os.replace(src, dst)
