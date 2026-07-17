#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Interactive thin-client rollout wrapper. Keep this file in the same directory as
# local-provision.sh, xfce-win10.sh, and workmon-agent-*/.
#
# Optional local secrets/config are loaded from .env.local-provision next to this file
# or from ../.env.local-provision in the repository layout.
# That file is ignored by git; do not commit real keys, passwords, or endpoints.

WG_NET_PREFIX="${WG_NET_PREFIX:-10.8.0}"
WG_NET_MASK="${WG_NET_MASK:-24}"
WG_HOST_MIN="${WG_HOST_MIN:-6}"
WG_HOST_MAX="${WG_HOST_MAX:-99}"
WG_VPS_MIN="${WG_VPS_MIN:-101}"
WG_VPS_MAX="${WG_VPS_MAX:-200}"
WG_GATEWAY="${WG_GATEWAY:-${WG_NET_PREFIX}.1}"

STEP_LIST="hostname ssh_hostkeys collect_key users grub apt_sources upgrade \
desktop audio wireguard watchdog nomachine x11vnc win10_script nm_shortcut \
power workmon summary"

log()  { printf '\033[1;32m[launcher]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[launcher] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[launcher] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

from_desktop=0
if [[ "${1-}" == "--from-desktop" ]]; then
    from_desktop=1
    if [[ -n "${2-}" && -e "$2" ]]; then
        cd -- "$(dirname -- "$2")" || die "Failed to switch to the desktop shortcut directory"
    fi
fi

[[ -t 0 ]] || die "This launcher is interactive; run it from a terminal, not through a pipe"

if [[ ${EUID} -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Run as root: sudo bash $0"
    log "Root privileges required; re-running through sudo..."
    exec sudo bash "$(readlink -f "$0")" "$@"
fi

if ((from_desktop)); then
    shift "$#"
    hold_open() {
        printf '\n'
        read -r -p "Press Enter to close this window..." _ || true
    }
    trap hold_open EXIT
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

env_file=""
for candidate in .env.local-provision ../.env.local-provision; do
    if [[ -f "$candidate" ]]; then
        env_file="$candidate"
        break
    fi
done

if [[ -n "$env_file" ]]; then
    log "Loading local settings from $env_file"
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
else
    warn ".env.local-provision not found next to the launcher or in the repository root; sanitized defaults/placeholders will be used"
fi

self_name="$(basename -- "${BASH_SOURCE[0]}")"
provision=""
shopt -s nullglob
for f in local-provision*.sh; do
    [[ "$f" == "$self_name" ]] && continue
    [[ "$f" == *launcher* ]] && continue
    provision="$f"
done
shopt -u nullglob
[[ -n "$provision" ]] || die "No local-provision*.sh found next to this launcher"
bash -n "$provision" || die "$provision failed shell syntax validation"
log "Provisioner: $provision"

missing=""
[[ -f "xfce-win10.sh" ]] || missing+=" xfce-win10.sh(Windows-like XFCE helper)"
compgen -G "workmon-agent-*/install.sh" >/dev/null || missing+=" workmon-agent-*/(WorkMon worker agent)"
if [[ -n "$missing" ]]; then
    warn "Missing next to the launcher:${missing}"
    warn "The matching steps will be skipped. Usually this is not what you want."
    read -r -p "Continue anyway? [y/N]: " reply
    [[ "$reply" =~ ^[Yy] ]] || die "Stopped. Add the missing files and run the launcher again"
fi

printf '\n'
log "=== Thin-client rollout: answer the required values, then the script runs ==="
printf '\n'

echo "1) Tunnel host number for this laptop (from your hostname/address inventory)."
echo "   Laptop numbers: ${WG_HOST_MIN}-${WG_HOST_MAX} -> ${WG_NET_PREFIX}.<number>/${WG_NET_MASK}."
wg_addr=""
while [[ -z "$wg_addr" ]]; do
    read -r -p "   Number, or full CIDR address: " reply
    if [[ "$reply" =~ ^[0-9]+$ ]]; then
        if ((reply >= WG_HOST_MIN && reply <= WG_HOST_MAX)); then
            wg_addr="${WG_NET_PREFIX}.${reply}/${WG_NET_MASK}"
        elif ((reply >= WG_VPS_MIN && reply <= WG_VPS_MAX)); then
            warn "${WG_NET_PREFIX}.${reply} is in the VPS range, not the laptop range"
        else
            warn "Number outside the configured laptop range ${WG_HOST_MIN}-${WG_HOST_MAX}"
        fi
    elif [[ "$reply" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
        ok=1
        for o in "${BASH_REMATCH[@]:1:4}"; do ((o <= 255)) || ok=0; done
        ((BASH_REMATCH[5] >= 1 && BASH_REMATCH[5] <= 32)) || ok=0
        if ((ok)); then
            wg_addr="$reply"
            [[ "$reply" == "${WG_NET_PREFIX}."* ]] || warn "Address is outside ${WG_NET_PREFIX}.0/${WG_NET_MASK}; continuing as explicitly requested"
        else
            warn "Invalid CIDR address"
        fi
    else
        warn "Enter a number such as 7, or a CIDR address such as ${WG_NET_PREFIX}.7/${WG_NET_MASK}"
    fi
done
wg_host_octet="${wg_addr##*.}"; wg_host_octet="${wg_host_octet%%/*}"

printf '\n'
def_hostname="$(printf 'tc-%02d' "$wg_host_octet")"
echo "2) Hostname: lowercase letters, digits, and hyphens. Enter accepts the default."
new_hostname=""
while [[ -z "$new_hostname" ]]; do
    read -r -p "   Hostname [${def_hostname}]: " reply
    reply="${reply:-$def_hostname}"
    if [[ "$reply" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        new_hostname="$reply"
    else
        warn "Use lowercase letters, digits, and hyphens; do not start/end with a hyphen"
    fi
done

printf '\n'
echo "3) x11vnc password for this machine."
echo "   Enter = use X11VNC_PASSWORD from .env.local-provision or the provisioner default; change it after rollout."
vnc_pass=""
while true; do
    read -r -s -p "   Password (hidden) [Enter = default/env]: " reply; printf '\n'
    [[ -z "$reply" ]] && break
    if [[ ${#reply} -ne 8 ]]; then
        warn "Classic VNC uses exactly 8 characters; entered: ${#reply}"
        continue
    fi
    read -r -s -p "   Repeat password: " reply2; printf '\n'
    [[ "$reply" == "$reply2" ]] || { warn "Passwords do not match"; continue; }
    vnc_pass="$reply"
    break
done

printf '\n'
only=""
read -r -p "Full run with all steps? [Y/n]: " reply
if [[ "$reply" =~ ^[Nn] ]]; then
    echo "Available steps: $STEP_LIST" | tr -s ' '
    while [[ -z "$only" ]]; do
        read -r -p "Comma-separated steps, e.g. wireguard,watchdog: " reply
        ok=1
        IFS=',' read -r -a chosen <<< "$reply"
        for s in "${chosen[@]}"; do
            [[ " $STEP_LIST " == *" ${s} "* ]] || { warn "Unknown step: $s"; ok=0; }
        done
        ((ok)) && [[ ${#chosen[@]} -gt 0 ]] && only="$reply"
    done
fi

runs_step() {
    local step="$1"
    [[ -z "$only" ]] && return 0
    [[ ",$only," == *",$step,"* ]]
}

if runs_step wireguard; then
    if [[ -z "${WG_SERVER_PUBKEY:-}" || "${WG_SERVER_PUBKEY:-}" == REPLACE_WITH_* ]]; then
        warn "WG_SERVER_PUBKEY is not set to a real value"
    fi
    if [[ -z "${WG_ENDPOINT:-}" || "${WG_ENDPOINT:-}" == *example.com* || "${WG_ENDPOINT:-}" == REPLACE_WITH_* ]]; then
        warn "WG_ENDPOINT is not set to a real value"
    fi
    if [[ -z "${COLLECT_PUBKEY:-}" || "${COLLECT_PUBKEY:-}" == *REPLACE_WITH* ]]; then
        warn "COLLECT_PUBKEY is not set; the collect_key step will skip SSH key installation"
    fi
fi

printf '\n'
log "=== Review before starting ==="
echo "  Script:        $provision"
echo "  Hostname:      $new_hostname"
echo "  WG address:    $wg_addr"
echo "  WG gateway:    $WG_GATEWAY"
echo "  VNC password:  $([ -n "$vnc_pass" ] && echo 'custom value supplied' || echo 'default/env value')"
echo "  Steps:         ${only:-all}"
echo
echo "  This may take a while (full-upgrade, firmware, NoMachine). Log: /var/log/local-provision.log"
read -r -p "Start? [y/N]: " reply
[[ "$reply" =~ ^[Yy] ]] || die "Cancelled; no changes made"

env_args=( "NEW_HOSTNAME=${new_hostname}" "WG_CLIENT_ADDR=${wg_addr}" )
for var in \
    ADMIN_USER SVC_USER SVC_USER_PASSWORD TARGET_USER ADMIN_GROUP COLLECT_PUBKEY WORKMON_AGENT_DIRNAME \
    WG_IFACE WG_SERVER_PUBKEY WG_ENDPOINT WG_ALLOWED WG_KEEPALIVE WG_GATEWAY WG_AUTOSTART WG_WATCHDOG_MAX_AGE \
    NOMACHINE_BRANCH NOMACHINE_VERSION NOMACHINE_BUILD NOMACHINE_MD5 \
    X11VNC_ENABLE X11VNC_PASSWORD X11VNC_PORT X11VNC_DISPLAY X11VNC_PASS_FILE \
    WIN10_THEME_COMMIT WIN10_ICONS_COMMIT; do
    [[ -v "$var" ]] && env_args+=( "${var}=${!var}" )
done
[[ -n "$vnc_pass" ]] && env_args+=( "X11VNC_PASSWORD=${vnc_pass}" )
[[ -n "$only" ]] && env_args+=( "ONLY=${only}" )

printf '\n'
log "Starting ${provision} (hostname=${new_hostname}, wg=${wg_addr})"
printf '\n'
rc=0
env "${env_args[@]}" bash "$provision" || rc=$?

printf '\n'
if ((rc == 0)); then
    log "=== Done. Next steps, in order ==="
    echo "  1. Add this laptop's public WG key as a peer on the WG server/firewall."
    echo "     Server-side AllowedIPs = ${wg_addr%%/*}/32."
    echo "  2. On this laptop: sudo wg-quick up wg0"
    echo "  3. Verify: ping ${WG_GATEWAY} and curl ifconfig.me"
    echo "  4. Change default passwords where used: service user and x11vnc."
    echo "  5. Log in as the service user, launch NoMachine, and apply the XFCE look script."
    echo "  Full runbook: docs/local-provision-admin-guide.md"
else
    warn "Provisioner exited with code $rc"
    warn "Check the tail of the log: tail -50 /var/log/local-provision.log"
    warn "Fix the cause and rerun the launcher; the provisioner is intended to be idempotent"
fi
exit "$rc"
