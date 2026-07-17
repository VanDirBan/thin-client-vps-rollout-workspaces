#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "uninstall.sh must be run as root" >&2
  exit 1
fi

PURGE=false
if [[ "${1:-}" == "--purge" ]]; then
  PURGE=true
fi

# 0.1.1+ installs manual execution only and no units. If upgrading from a version
# that had units, clean them up best-effort.
echo "Removing any legacy systemd units (older versions)..."
systemctl disable --now workmon-collect.timer 2>/dev/null || true
systemctl stop workmon-collect.service 2>/dev/null || true

if findmnt -rn --target /mnt/workmon-screenshots >/dev/null 2>&1; then
  umount /mnt/workmon-screenshots || true
fi

echo "Removing symlink and application files..."
rm -f /etc/systemd/system/workmon-collect.service /etc/systemd/system/workmon-collect.timer
rm -f /usr/local/bin/workmon-collect
systemctl daemon-reload 2>/dev/null || true
rm -rf /opt/workmon-collect

if [[ "${PURGE}" == "true" ]]; then
  echo "Purging config, staging and mount dir (INCLUDING the private key!)..."
  rm -rf /etc/workmon-collect /var/lib/workmon-collect /mnt/workmon-screenshots /run/workmon-collect
else
  echo "Config (incl. private key) and staging preserved. Use --purge to remove /etc/workmon-collect and /var/lib/workmon-collect."
fi

echo "workmon-collect uninstalled."
