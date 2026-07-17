#!/usr/bin/env bash
# copy_key.sh — copy public.key to a WorkMon worker
#
# Usage:
#   sudo ./copy_key.sh <IP-address>
#
# Example:
#   sudo ./copy_key.sh 10.8.0.4

set -euo pipefail

KEY="/etc/workmon-collect/id_collect"   # private SSH key used for worker access
PUB="/etc/workmon-collect/public.key"   # age recipient copied to the worker
DEST="/etc/workmon/"                    # destination directory on the worker

usage() {
    cat >&2 <<EOF
Usage: sudo $0 <IP-address>

Example:
    sudo $0 10.8.0.4
EOF
}

# IPv4 validation: four octets, each 0-255.
valid_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1:4}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

# --- permission check ---
# /etc/workmon-collect/id_collect is readable only by root, so the script must
# run with superuser privileges.
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

# Trim accidental whitespace around the address; this is a common copy-paste
# mistake when admins paste worker IPs from notes or spreadsheets.
IP="$1"
IP="${IP#"${IP%%[![:space:]]*}"}"
IP="${IP%"${IP##*[![:space:]]}"}"

if ! valid_ipv4 "$IP"; then
    echo "Error: '$IP' does not look like a valid IPv4 address (four octets, each 0-255)." >&2
    usage
    exit 1
fi

# --- file existence check ---
for f in "$KEY" "$PUB"; do
    [[ -r "$f" ]] || { echo "Error: file not found or inaccessible: $f" >&2; exit 1; }
done

# --- actual copy ---
# IdentitiesOnly=yes forces SSH to use only id_collect. Otherwise ssh-agent may
# offer unrelated keys first and hit MaxAuthTries before trying the correct key.
scp -i "$KEY" \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    "$PUB" "root@${IP}:${DEST}"

echo "OK: public.key delivered to ${IP}:${DEST}"
