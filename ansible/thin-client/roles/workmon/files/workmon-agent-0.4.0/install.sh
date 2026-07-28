#!/usr/bin/env bash
set -euo pipefail

# WorkMon worker agent 0.4.0 installer (Debian 13 + Xfce/X11).
# Capture + encrypt only. Collection/decryption happen off-box (workmon-collect).

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

if [[ ${EUID} -ne 0 ]]; then
  echo "install.sh must be run as root" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

write_file() {
  local target="$1" mode="$2" owner="$3" group="$4" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] create ${target} mode=${mode} owner=${owner}:${group}"; rm -f "$tmp"
  else
    install -o "$owner" -g "$group" -m "$mode" "$tmp" "$target"; rm -f "$tmp"
  fi
}

if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get not found. This installer targets Debian 13." >&2
  exit 1
fi

[[ "${DRY_RUN}" == "true" ]] && echo "Dry-run mode: no changes will be made."

echo "Installing worker agent dependencies..."
run apt-get update
# scrot+age for capture/encryption; openssh-server+rsync — so the admin laptop can pull the spool over SSH.
# For CAPTURE_BACKEND=import, install imagemagick manually.
run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 \
  scrot \
  age \
  procps \
  util-linux \
  openssh-server \
  rsync

echo "Creating directories..."
run install -d -o root -g root -m 0755 /opt/workmon
run install -d -o root -g root -m 0700 /etc/workmon
run install -d -o root -g root -m 0700 /var/lib/workmon/tmp
run install -d -o root -g root -m 0700 /var/lib/workmon/spool

echo "Installing project files..."
run install -o root -g root -m 0644 "${SRC_DIR}/common.py" /opt/workmon/common.py
run install -o root -g root -m 0755 "${SRC_DIR}/capture.py" /opt/workmon/capture.py
run install -o root -g root -m 0644 "${SRC_DIR}/README.md" /opt/workmon/README.md
[[ -f "${SRC_DIR}/ARCHITECTURE.md" ]] && run install -o root -g root -m 0644 "${SRC_DIR}/ARCHITECTURE.md" /opt/workmon/ARCHITECTURE.md
run install -o root -g root -m 0755 "${SRC_DIR}/install.sh" /opt/workmon/install.sh
run install -o root -g root -m 0755 "${SRC_DIR}/uninstall.sh" /opt/workmon/uninstall.sh
run install -o root -g root -m 0644 "${SRC_DIR}/systemd/workmon-capture.service" /etc/systemd/system/workmon-capture.service

if [[ ! -f /etc/workmon/workmon.conf ]]; then
  echo "Creating default /etc/workmon/workmon.conf"
  write_file /etc/workmon/workmon.conf 0600 root root <<'CONF'
# WorkMon worker agent 0.4.0 configuration (capture-only).

SCREENSHOT_INTERVAL_SECONDS=30
LOCAL_SPOOL_MAX_MB=50000
ASSET_ID_FILE=/etc/workmon/asset_id
PUBLIC_KEY_FILE=/etc/workmon/public.key

SCREENSHOT_FORMAT=png
CAPTURE_BACKEND=scrot
ENCRYPTION_BACKEND=age

# Skip byte-identical frames (idle/lock screen).
SKIP_IDENTICAL_FRAMES=true

# Optional: fix the expected GUI user. If empty, the active X11 session is auto-discovered.
GUI_USER=
PRIMARY_USER=

COMMAND_TIMEOUT_SECONDS=60
LOG_LEVEL=INFO
CONF
fi

if [[ ! -f /etc/workmon/asset_id ]]; then
  echo "Creating /etc/workmon/asset_id from current hostname"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] hostname --short > /etc/workmon/asset_id"
  else
    hostname --short > /etc/workmon/asset_id
    chown root:root /etc/workmon/asset_id; chmod 0644 /etc/workmon/asset_id
  fi
fi

if [[ ! -s /etc/workmon/public.key ]]; then
  echo "WARNING: /etc/workmon/public.key is missing or empty." >&2
  echo "Install the SAME shared age public recipient on every worker." >&2
  echo "Generate the identity once on the admin laptop (age-keygen -o private.key)," >&2
  echo "derive the recipient (age-keygen -y private.key), and deploy it here." >&2
fi

if [[ "${DRY_RUN}" != "true" ]]; then
  chown -R root:root /opt/workmon /etc/workmon /var/lib/workmon
  chmod 0755 /opt/workmon
  find /opt/workmon -type f -exec chmod 0644 {} \;
  chmod 0755 /opt/workmon/capture.py /opt/workmon/install.sh /opt/workmon/uninstall.sh
  chmod 0700 /etc/workmon /var/lib/workmon /var/lib/workmon/tmp /var/lib/workmon/spool
  chmod 0600 /etc/workmon/workmon.conf
  [[ -f /etc/workmon/public.key ]] && chmod 0600 /etc/workmon/public.key || true
  chmod 0644 /etc/workmon/asset_id
fi

echo "Reloading systemd and enabling capture service..."
run systemctl daemon-reload
if [[ -s /etc/workmon/public.key ]]; then
  run systemctl enable --now workmon-capture.service
else
  run systemctl enable workmon-capture.service
  echo "Capture enabled but not started because /etc/workmon/public.key is missing."
  echo "After installing the public key: sudo systemctl start workmon-capture.service"
fi

cat <<'NOTE'

Worker agent installed. Next, grant the admin laptop pull access over SSH:
  - add the admin SSH public key to this host if not yet (e.g. root's authorized_keys),
  - the collector reads /var/lib/workmon/spool (root-only), so it connects as root
    or as a sudo-capable user (REMOTE_SUDO=true in the collector config).

From admin machine do - scp -i /etc/workmon-collect/id_collect public.key root@local-machine-ip:/etc/workmon/

Check status:
  systemctl status workmon-capture.service
  journalctl -u workmon-capture.service -n 100 --no-pager
NOTE
