#!/usr/bin/env bash
# Interactive wrapper for copy_key.sh for less experienced admins.
# Keep this file next to copy_key.sh and the .desktop launcher.

set +e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COPY_SCRIPT="${SCRIPT_DIR}/copy_key.sh"

pause_before_exit() {
    printf '\n'
    read -r -p "Press Enter to close this window..."
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

valid_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1:4}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

clear
printf '%s\n' "=================================================="
printf '%s\n' "       WORKMON — SEND PUBLIC.KEY"
printf '%s\n' "=================================================="
printf '\n'
printf '%s\n' "Before you start, make sure that:"
printf '%s\n' "  1. The worker laptop is powered on."
printf '%s\n' "  2. It is connected to the work network or VPN."
printf '%s\n' "  3. You know its IP address."
printf '\n'
printf '%s\n' "Next you will need to:"
printf '%s\n' "  • enter the worker laptop IP address;"
printf '%s\n' "  • enter this admin laptop's sudo password if prompted."
printf '\n'

if [[ ! -f "$COPY_SCRIPT" ]]; then
    printf '%s\n' "ERROR: copy_key.sh was not found next to this launcher."
    printf 'Expected path: %s\n' "$COPY_SCRIPT"
    pause_before_exit
    exit 1
fi

if ! command -v scp >/dev/null 2>&1; then
    printf '%s\n' "ERROR: scp is not installed."
    printf '%s\n' "Install the openssh-client package:"
    printf '%s\n' "  sudo apt install openssh-client"
    pause_before_exit
    exit 1
fi

# Ask for IP until the input is valid. Empty input cancels the operation, so
# the terminal window always has a clear exit path.
IP=""
while :; do
    read -r -p "Enter worker laptop IP address (Enter cancels): " IP
    IP="$(trim "$IP")"

    if [[ -z "$IP" ]]; then
        printf '\n%s\n' "Operation cancelled: no IP address entered."
        pause_before_exit
        exit 1
    fi

    if valid_ipv4 "$IP"; then
        break
    fi

    printf "'%s' does not look like an IP address (expected four numbers 0-255 separated by dots, for example 10.8.0.15).\n" "$IP"
    printf '%s\n' "Try again."
    printf '\n'
done

printf '\nChecking and sending the key to %s...\n' "$IP"
printf '%s\n\n' "A sudo password prompt may appear now."

sudo bash "$COPY_SCRIPT" "$IP"
STATUS=$?

printf '\n'
if [[ $STATUS -eq 0 ]]; then
    printf '%s\n' "=================================================="
    printf 'DONE: public.key was delivered to %s.\n' "$IP"
    printf '%s\n' "=================================================="
else
    printf '%s\n' "=================================================="
    printf 'ERROR: copy failed, exit code: %s\n' "$STATUS"
    printf '%s\n' "=================================================="
    printf '\n%s\n' "Check:"
    printf '%s\n' "  • whether the IP was entered correctly;"
    printf '%s\n' "  • whether the worker laptop is connected to the network/VPN;"
    printf '%s\n' "  • whether SSH is reachable on the worker;"
    printf '%s\n' "  • whether /etc/workmon/ exists on the worker."
fi

pause_before_exit
exit "$STATUS"
