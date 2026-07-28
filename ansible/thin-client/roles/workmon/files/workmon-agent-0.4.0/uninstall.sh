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

echo "Stopping WorkMon worker agent..."
systemctl disable --now workmon-capture.service 2>/dev/null || true

echo "Removing systemd unit and application files..."
rm -f /etc/systemd/system/workmon-capture.service
systemctl daemon-reload
rm -rf /opt/workmon

if [[ "${PURGE}" == "true" ]]; then
  echo "Purging configuration and local spool..."
  rm -rf /etc/workmon /var/lib/workmon
else
  echo "Configuration and local spool preserved. Use --purge to remove /etc/workmon and /var/lib/workmon."
fi

echo "WorkMon worker agent uninstalled."
