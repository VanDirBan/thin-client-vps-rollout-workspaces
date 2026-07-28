#!/usr/bin/env python3
"""WorkMon worker capture agent (Debian 13 + Xfce/X11). Capture + encrypt only."""
from __future__ import annotations

import logging
import os
import time
from pathlib import Path
from typing import Optional, Tuple

from common import (
    CommandError,
    SPOOL_DIR,
    TMP_DIR,
    VERSION,
    WorkMonError,
    atomic_rename,
    describe_missing,
    ensure_base_dirs,
    file_size_bytes,
    find_active_x11_session,
    get_asset_id,
    get_bool,
    get_hostname,
    get_int,
    load_config,
    require_programs,
    require_root,
    rotate_spool,
    run_cmd,
    setup_logging,
    sha256_file,
    timestamp_for_filename,
)

SUPPORTED_CAPTURE_BACKENDS = {"scrot", "import"}


def validate_runtime(config: dict[str, str]) -> Tuple[bool, str]:
    missing = []
    backend = config.get("CAPTURE_BACKEND", "scrot").lower()
    encryption = config.get("ENCRYPTION_BACKEND", "age").lower()
    if backend == "scrot":
        missing.extend(require_programs(["scrot"]))
    elif backend == "import":
        missing.extend(require_programs(["import"]))
    else:
        return (False, f"Unsupported CAPTURE_BACKEND={backend}. Supported: {', '.join(sorted(SUPPORTED_CAPTURE_BACKENDS))}")

    if encryption == "age":
        missing.extend(require_programs(["age"]))
    else:
        return (False, f"Unsupported ENCRYPTION_BACKEND={encryption}. This release implements age only.")

    if missing:
        return (False, f"Missing required program(s): {describe_missing(missing)}")

    public_key = Path(config.get("PUBLIC_KEY_FILE", "/etc/workmon/public.key"))
    if not public_key.exists() or public_key.stat().st_size == 0:
        return (False, f"Public key is missing or empty: {public_key}")
    return (True, "")


def capture_screenshot(config: dict[str, str], logger: logging.Logger, output_partial: Path, env: dict[str, str]) -> None:
    backend = config.get("CAPTURE_BACKEND", "scrot").lower()
    timeout = get_int(config, "COMMAND_TIMEOUT_SECONDS")
    fmt = config.get("SCREENSHOT_FORMAT", "png").lower()
    if fmt != "png":
        raise WorkMonError("Only SCREENSHOT_FORMAT=png is implemented in this release")
    if backend == "scrot":
        cmd = ["scrot", "-z", "-o", str(output_partial)]
    elif backend == "import":
        cmd = ["import", "-window", "root", str(output_partial)]
    else:
        raise WorkMonError(f"Unsupported capture backend: {backend}")
    run_cmd(cmd, logger=logger, env=env, timeout=timeout)
    if not output_partial.exists() or output_partial.stat().st_size == 0:
        raise WorkMonError("Screenshot command completed but output file is missing or empty")


def encrypt_file_age(config: dict[str, str], logger: logging.Logger, plain_png: Path, encrypted_partial: Path) -> None:
    public_key = Path(config.get("PUBLIC_KEY_FILE", "/etc/workmon/public.key"))
    timeout = get_int(config, "COMMAND_TIMEOUT_SECONDS")
    cmd = ["age", "--recipients-file", str(public_key), "--output", str(encrypted_partial), str(plain_png)]
    run_cmd(cmd, logger=logger, timeout=timeout)
    if not encrypted_partial.exists() or encrypted_partial.stat().st_size == 0:
        raise WorkMonError("age completed but encrypted output is missing or empty")


def cleanup_paths(*paths: Path) -> None:
    for path in paths:
        try:
            if path.exists():
                path.unlink()
        except OSError:
            pass


def capture_once(config: dict[str, str], logger: logging.Logger, last_hash: Optional[str]) -> Optional[str]:
    session = find_active_x11_session(config, logger)
    if session is None:
        logger.info("No active local X11 session yet; will retry")
        return last_hash

    asset_id = get_asset_id(config)
    hostname = get_hostname()
    ts = timestamp_for_filename()
    username = session.username.replace(os.sep, "_")
    base = f"{asset_id}_{ts}_{hostname}_{username}.png"

    plain_partial = TMP_DIR / f"{base}.partial.png"
    plain_final = TMP_DIR / base
    encrypted_partial = TMP_DIR / f"{base}.age.partial"
    encrypted_final = SPOOL_DIR / f"{base}.age"

    skip_identical = get_bool(config, "SKIP_IDENTICAL_FRAMES")

    cleanup_paths(plain_partial, plain_final, encrypted_partial)
    try:
        logger.debug("Capturing X11 screenshot: user=%s display=%s backend=%s", session.username, session.display, config.get("CAPTURE_BACKEND", "scrot"))
        capture_screenshot(config, logger, plain_partial, session.env)
        atomic_rename(plain_partial, plain_final)

        frame_hash = sha256_file(plain_final)
        if skip_identical and last_hash is not None and frame_hash == last_hash:
            logger.debug("Frame identical to previous; skipping encrypt/spool")
            return frame_hash

        encrypt_file_age(config, logger, plain_final, encrypted_partial)
        atomic_rename(encrypted_partial, encrypted_final)
        logger.info("Encrypted screenshot created: %s size=%s", encrypted_final.name, file_size_bytes(encrypted_final))
        return frame_hash
    except (CommandError, WorkMonError, OSError) as exc:
        logger.warning("Capture cycle failed: %s", exc)
        return last_hash
    finally:
        cleanup_paths(plain_partial, plain_final, encrypted_partial)


def main() -> int:
    require_root()
    config = load_config()
    logger = setup_logging(config, "workmon.capture")
    ensure_base_dirs()

    logger.info("WorkMon worker capture agent starting (v%s)", VERSION)
    interval = max(1, get_int(config, "SCREENSHOT_INTERVAL_SECONDS"))
    invalid_backoff = min(max(interval, 30), 60)

    last_hash: Optional[str] = None
    prev_ok: Optional[bool] = None

    while True:
        try:
            ok, reason = validate_runtime(config)
            if ok != prev_ok:
                if ok:
                    logger.info("Runtime validation OK; capture active")
                else:
                    logger.warning("Capture paused: %s", reason)
                prev_ok = ok
            if ok:
                last_hash = capture_once(config, logger, last_hash)
                rotate_spool(config, logger)
                time.sleep(interval)
            else:
                time.sleep(invalid_backoff)
        except Exception as exc:
            logger.exception("Unexpected capture loop error: %s", exc)
            time.sleep(interval)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
    except Exception as exc:
        logging.basicConfig(level=logging.ERROR)
        logging.getLogger("workmon.capture").error("Fatal error: %s", exc)
        raise SystemExit(1)
