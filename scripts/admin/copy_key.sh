#!/usr/bin/env bash
# copy_key.sh — copies public.key to a WorkMon worker
#
# Usage:
#   sudo ./copy_key.sh <IP-address>
#
# Example:
#   sudo ./copy_key.sh 10.8.0.4

set -euo pipefail

KEY="/etc/workmon-collect/id_collect"   # private key for SSH
PUB="/etc/workmon-collect/public.key"   # what we're copying
DEST="/etc/workmon/"                    # where we copy it to on the worker

usage() {
    cat >&2 <<EOF
Usage: sudo $0 <IP-address>

Example:
    sudo $0 10.8.0.4
EOF
}

# --- permission check ---
# The /etc/workmon-collect/id_collect key is readable only by root,
# so the script must be run with superuser privileges.
if [[ $EUID -ne 0 ]]; then
    echo "Error: the script must be run as root." >&2
    echo "Rerun it like this:  sudo $0 $*" >&2
    exit 1
fi

# --- argument check ---
if [[ $# -eq 0 ]]; then
    echo "Error: worker IP address not specified." >&2
    usage
    exit 1
fi

if [[ $# -gt 1 ]]; then
    echo "Error: expected exactly one argument, got $#." >&2
    usage
    exit 1
fi

IP="$1"

# rough IPv4 validation (4 octets)
if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: '$IP' doesn't look like an IPv4 address." >&2
    usage
    exit 1
fi

# --- file existence check ---
for f in "$KEY" "$PUB"; do
    [[ -r "$f" ]] || { echo "Error: file not found or inaccessible: $f" >&2; exit 1; }
done

# --- actual copying ---
scp -i "$KEY" \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    "$PUB" "root@${IP}:${DEST}"

echo "OK: public.key delivered to ${IP}:${DEST}"
