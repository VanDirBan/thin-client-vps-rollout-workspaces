#!/usr/bin/env bash
# vps-provision-launcher.sh — interactive "one-click" VPS rollout wrapper.
#
# Intended for an admin laptop. It asks for the new VPS public IP, the VPS
# WireGuard address, and optional timezone, then:
#   1. opens one reusable SSH control connection to the VPS;
#   2. copies the provisioner and the local Multilogin .deb to /root/;
#   3. runs the provisioner on the VPS with the selected values passed through
#      environment variables;
#   4. optionally copies xfce-win10.sh to the worker user's desktop.
#
# Keep this launcher next to its .desktop file. It can run from the repository
# layout (scripts/admin/) or from a flat exported installer directory.
#
# The VPS root password from the hosting provider is entered once by SSH.

set -u  # do not use set -e; errors are handled explicitly so the terminal stays open

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_PROVISION_NAME="vps-provision.sh"
VPS_OCTET_MIN="${VPS_OCTET_MIN:-101}"
VPS_OCTET_MAX="${VPS_OCTET_MAX:-200}"
LAPTOP_OCTET_MIN="${LAPTOP_OCTET_MIN:-6}"
LAPTOP_OCTET_MAX="${LAPTOP_OCTET_MAX:-99}"

CTL_PATH=""
VPS_IP=""

pause_before_exit() {
    printf '\n'
    read -r -p "Press Enter to close this window..."
}

die() {
    printf '\nERROR: %s\n' "$*"
    pause_before_exit
    exit 1
}

cleanup() {
    if [[ -n "${CTL_PATH:-}" ]]; then
        ssh -o ControlPath="$CTL_PATH" -O exit "root@${VPS_IP:-x}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

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

first_existing() {
    local p
    for p in "$@"; do
        [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
    done
    return 1
}

extract_default() {
    local name="$1" file="$2"
    sed -nE \
        -e "s|^${name}=\"\\\$\{${name}:-([^}]*)\}\".*|\1|p" \
        -e "s|^${name}=\"([^\"]*)\".*|\1|p" \
        "$file" | head -n1
}

load_optional_env() {
    local f
    for f in \
        "$SCRIPT_DIR/.env.vps-provision" \
        "$SCRIPT_DIR/../.env.vps-provision" \
        "$SCRIPT_DIR/../../.env.vps-provision"; do
        if [[ -f "$f" ]]; then
            # shellcheck disable=SC1090
            set -a; . "$f"; set +a
            printf 'Loaded local env file: %s\n' "$f"
            return 0
        fi
    done
    return 0
}

prompt_secret_if_needed() {
    local var="$1" label="$2" current="${!var:-}"
    if [[ -n "$current" && ! "$current" =~ ^CHANGE_ME ]]; then
        return 0
    fi

    local a b
    while :; do
        printf '%s' "$label: "
        IFS= read -r -s a
        printf '\nRepeat %s: ' "$label"
        IFS= read -r -s b
        printf '\n'
        if [[ -z "$a" ]]; then
            printf 'Value cannot be empty. Try again.\n'
            continue
        fi
        if [[ "$a" != "$b" ]]; then
            printf 'Values do not match. Try again.\n'
            continue
        fi
        printf -v "$var" '%s' "$a"
        export "$var"
        return 0
    done
}

shell_quote() {
    printf '%q' "$1"
}

remote_env_command() {
    local cmd="env" name val
    local names=(
        ADMIN_USER ADMIN_PASS WORK_USER WORK_PASS TIMEZONE
        WG_ADDRESS WG_SERVER_PUBKEY WG_SERVER_ENDPOINT WG_ALLOWED_IPS WG_KEEPALIVE
        NOMACHINE_BRANCH NOMACHINE_VERSION NOMACHINE_BUILD
        AUDIO_TUNNEL_ENABLE AUDIO_LAPTOP_IP AUDIO_TCP_PORT
        NODE_EXPORTER_ENABLE NODE_EXPORTER_PORT
        WIN10_THEME_COMMIT WIN10_ICONS_COMMIT
    )
    for name in "${names[@]}"; do
        val="${!name-}"
        [[ -n "$val" ]] || continue
        cmd+=" ${name}=$(shell_quote "$val")"
    done
    cmd+=" bash /root/${REMOTE_PROVISION_NAME}"
    printf '%s' "$cmd"
}

#------------------------------------------------------------------------------
# Greeting and local environment checks
#------------------------------------------------------------------------------
clear
printf '%s\n' "=================================================="
printf '%s\n' "        NEW VPS ROLLOUT (vps-provision)"
printf '%s\n' "=================================================="
printf '\n'
printf '%s\n' "You will need:"
printf '%s\n' "  1. New VPS public IP address (clean Ubuntu 24/Debian 13)."
printf '%s\n' "  2. VPS root password from the hosting provider."
printf '%s\n' "  3. Free VPS address in the WireGuard tunnel range."
printf '%s\n' "  4. Optional paired thin-client laptop number for the audio tunnel."
printf '     Default allowed VPS last-octet range: %s-%s.\n' "$VPS_OCTET_MIN" "$VPS_OCTET_MAX"
printf '\n'
printf '%s\n' "A full rollout usually takes 20-40 minutes. Do not close this window."
printf '\n'

PROVISION="$(first_existing \
    "$SCRIPT_DIR/../vps-provision.sh" \
    "$SCRIPT_DIR/vps-provision.sh" \
    "$SCRIPT_DIR/vps-provision-v2.0.sh" \
    "$SCRIPT_DIR/vps-provision-v2_0.sh" \
    "$SCRIPT_DIR/../vps-provision-v2.0.sh" \
    "$SCRIPT_DIR/../vps-provision-v2_0.sh")" || \
    die "vps-provision.sh was not found. Run the launcher from scripts/admin/ in the repo or from an exported installer directory."

XFCE_SCRIPT="$(first_existing \
    "$SCRIPT_DIR/../xfce-win10.sh" \
    "$SCRIPT_DIR/xfce-win10.sh" \
    "$SCRIPT_DIR/../scripts/xfce-win10.sh")" || true

command -v ssh >/dev/null 2>&1 || die "ssh is not installed (package openssh-client)."
command -v scp >/dev/null 2>&1 || die "scp is not installed (package openssh-client)."

shopt -s nullglob
MLX_CANDIDATES=(
    "$SCRIPT_DIR"/desktop-multiloginx-*.deb
    "$SCRIPT_DIR"/../desktop-multiloginx-*.deb
)
shopt -u nullglob
if (( ${#MLX_CANDIDATES[@]} == 0 )); then
    die "desktop-multiloginx-*.deb was not found next to the launcher or scripts directory. Put the Multilogin installer there before running the launcher."
fi
MLX_DEB="${MLX_CANDIDATES[0]}"
if (( ${#MLX_CANDIDATES[@]} > 1 )); then
    printf '[!] Multiple Multilogin .deb files found; using: %s\n\n' "$(basename "$MLX_DEB")"
fi

if [[ ! -f "$XFCE_SCRIPT" ]]; then
    printf '%s\n\n' "[!] xfce-win10.sh was not found — post-rollout desktop look copy will be skipped."
fi

load_optional_env

# Current defaults from the provisioner. Supports both sanitized env-overridable
# assignments and older hardcoded assignments.
CUR_WG="${WG_ADDRESS:-$(extract_default WG_ADDRESS "$PROVISION")}"
CUR_TZ="${TIMEZONE:-$(extract_default TIMEZONE "$PROVISION")}"
ADMIN_USER="${ADMIN_USER:-$(extract_default ADMIN_USER "$PROVISION")}"; export ADMIN_USER
WORK_USER="${WORK_USER:-$(extract_default WORK_USER "$PROVISION")}"; export WORK_USER
ADMIN_PASS="${ADMIN_PASS:-$(extract_default ADMIN_PASS "$PROVISION")}"; export ADMIN_PASS
WORK_PASS="${WORK_PASS:-$(extract_default WORK_PASS "$PROVISION")}"; export WORK_PASS
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-$(extract_default WG_ALLOWED_IPS "$PROVISION")}"; export WG_ALLOWED_IPS
WG_KEEPALIVE="${WG_KEEPALIVE:-$(extract_default WG_KEEPALIVE "$PROVISION")}"; export WG_KEEPALIVE
AUDIO_TUNNEL_ENABLE="${AUDIO_TUNNEL_ENABLE:-$(extract_default AUDIO_TUNNEL_ENABLE "$PROVISION")}"; export AUDIO_TUNNEL_ENABLE
AUDIO_LAPTOP_IP="${AUDIO_LAPTOP_IP:-$(extract_default AUDIO_LAPTOP_IP "$PROVISION")}"; export AUDIO_LAPTOP_IP
AUDIO_TCP_PORT="${AUDIO_TCP_PORT:-$(extract_default AUDIO_TCP_PORT "$PROVISION")}"; export AUDIO_TCP_PORT
NODE_EXPORTER_ENABLE="${NODE_EXPORTER_ENABLE:-$(extract_default NODE_EXPORTER_ENABLE "$PROVISION")}"; export NODE_EXPORTER_ENABLE
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-$(extract_default NODE_EXPORTER_PORT "$PROVISION")}"; export NODE_EXPORTER_PORT

[[ -n "$CUR_WG" ]] || die "WG_ADDRESS was not found in the provisioner; is this the expected script version?"

#------------------------------------------------------------------------------
# Question 1: VPS public IP
#------------------------------------------------------------------------------
VPS_IP=""
while :; do
    read -r -p "Enter new VPS public IP address (Enter cancels): " VPS_IP
    VPS_IP="$(trim "$VPS_IP")"
    if [[ -z "$VPS_IP" ]]; then
        printf '\n%s\n' "Operation cancelled."
        pause_before_exit
        exit 1
    fi
    valid_ipv4 "$VPS_IP" && break
    printf "'%s' does not look like an IP address (four numbers 0-255 separated by dots). Try again.\n\n" "$VPS_IP"
done

#------------------------------------------------------------------------------
# Question 2: WireGuard address inside the tunnel
#------------------------------------------------------------------------------
WG_PREFIX="${CUR_WG%.*}"
WG_TAIL="${CUR_WG##*.}"
if [[ "$WG_TAIL" == */* ]]; then
    CUR_OCTET="${WG_TAIL%%/*}"
    WG_MASK="/${WG_TAIL#*/}"
else
    CUR_OCTET="$WG_TAIL"
    WG_MASK=""
fi

printf '\nWireGuard address for this VPS.\n'
printf 'Current provisioner default: %s\n' "$CUR_WG"
printf 'Allowed VPS last-octet range: %s.%s-%s\n' "$WG_PREFIX" "$VPS_OCTET_MIN" "$VPS_OCTET_MAX"
printf '%s\n' "WARNING: the selected address must be free and unique."
printf '\n'

WG_OCTET=""
while :; do
    read -r -p "Last octet (${VPS_OCTET_MIN}-${VPS_OCTET_MAX}), Enter keeps ${CUR_OCTET}: " WG_OCTET
    WG_OCTET="$(trim "$WG_OCTET")"

    if [[ -z "$WG_OCTET" ]]; then
        WG_OCTET="$CUR_OCTET"
        printf '[!] Keeping provisioner address: %s. Make sure it is free.\n' "$CUR_WG"
        break
    fi

    if [[ ! "$WG_OCTET" =~ ^[0-9]+$ ]]; then
        printf 'Expected a number. Try again.\n\n'
        continue
    fi

    if (( 10#$WG_OCTET < VPS_OCTET_MIN || 10#$WG_OCTET > VPS_OCTET_MAX )); then
        printf 'Octet %s is outside the configured VPS range (%s-%s).\n' "$WG_OCTET" "$VPS_OCTET_MIN" "$VPS_OCTET_MAX"
        printf '%s\n\n' "Use an address from the VPS range to avoid crossing into another firewall policy group."
        continue
    fi

    WG_OCTET=$(( 10#$WG_OCTET ))
    break
done
WG_ADDRESS="${WG_PREFIX}.${WG_OCTET}${WG_MASK}"
export WG_ADDRESS

#------------------------------------------------------------------------------
# Question 3: timezone
#------------------------------------------------------------------------------
printf '\nVPS timezone. Current provisioner default: %s\n' "${CUR_TZ:-<do not change>}"
read -r -p "Timezone, for example Europe/Berlin (Enter keeps default): " ANSWER
ANSWER="$(trim "$ANSWER")"
if [[ -n "$ANSWER" ]]; then
    if [[ ! -f "/usr/share/zoneinfo/$ANSWER" ]]; then
        printf "Timezone '%s' was not found under /usr/share/zoneinfo. Expected format: Region/City, for example Europe/Kyiv.\n" "$ANSWER"
        read -r -p "Use it anyway? [y/N]: " FORCE
        if [[ ! "$FORCE" =~ ^[Yy] ]]; then
            printf '\n%s\n' "Operation cancelled."
            pause_before_exit
            exit 1
        fi
    fi
    TIMEZONE="$ANSWER"
else
    TIMEZONE="$CUR_TZ"
fi
export TIMEZONE

#------------------------------------------------------------------------------
# Question 4: paired thin client for the audio tunnel
#------------------------------------------------------------------------------
AUDIO_TCP_PORT="${AUDIO_TCP_PORT:-4713}"
NODE_EXPORTER_ENABLE="${NODE_EXPORTER_ENABLE:-yes}"
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
printf '\nPaired thin-client laptop for the audio tunnel.\n'
printf '%s\n' "The VPS will play sound on that laptop and record from its microphone."
printf 'Laptop last-octet range: %s-%s. Enter skips the audio tunnel.\n' "$LAPTOP_OCTET_MIN" "$LAPTOP_OCTET_MAX"
if [[ -n "${AUDIO_LAPTOP_IP:-}" ]]; then
    printf 'Current AUDIO_LAPTOP_IP from local env/provisioner: %s\n' "$AUDIO_LAPTOP_IP"
fi
printf '\n'
AUDIO_OCTET=""
while :; do
    read -r -p "Paired laptop last octet (${LAPTOP_OCTET_MIN}-${LAPTOP_OCTET_MAX}), Enter skips: " AUDIO_OCTET
    AUDIO_OCTET="$(trim "$AUDIO_OCTET")"
    if [[ -z "$AUDIO_OCTET" ]]; then
        if [[ -n "${AUDIO_LAPTOP_IP:-}" && "${AUDIO_TUNNEL_ENABLE:-yes}" = "yes" ]]; then
            printf '[!] Keeping existing AUDIO_LAPTOP_IP: %s\n' "$AUDIO_LAPTOP_IP"
            AUDIO_TUNNEL_ENABLE="yes"
        else
            AUDIO_TUNNEL_ENABLE="no"
            AUDIO_LAPTOP_IP=""
            printf '%s\n' "[!] Audio tunnel will be skipped."
        fi
        break
    fi
    if [[ ! "$AUDIO_OCTET" =~ ^[0-9]+$ ]]; then
        printf 'Expected a number.\n\n'
        continue
    fi
    if (( 10#$AUDIO_OCTET < LAPTOP_OCTET_MIN || 10#$AUDIO_OCTET > LAPTOP_OCTET_MAX )); then
        printf 'Octet %s is outside the laptop range (%s-%s).\n\n' "$AUDIO_OCTET" "$LAPTOP_OCTET_MIN" "$LAPTOP_OCTET_MAX"
        continue
    fi
    AUDIO_OCTET=$(( 10#$AUDIO_OCTET ))
    AUDIO_LAPTOP_IP="${WG_PREFIX}.${AUDIO_OCTET}"
    AUDIO_TUNNEL_ENABLE="yes"
    break
done
export AUDIO_TUNNEL_ENABLE AUDIO_LAPTOP_IP AUDIO_TCP_PORT NODE_EXPORTER_ENABLE NODE_EXPORTER_PORT

#------------------------------------------------------------------------------
# Secrets and optional WireGuard server settings
#------------------------------------------------------------------------------
prompt_secret_if_needed ADMIN_PASS "Initial password for admin user ${ADMIN_USER:-admin}"
prompt_secret_if_needed WORK_PASS "Initial password for worker user ${WORK_USER:-worker}"

WG_SERVER_PUBKEY="${WG_SERVER_PUBKEY:-}"
WG_SERVER_ENDPOINT="${WG_SERVER_ENDPOINT:-}"
export WG_SERVER_PUBKEY WG_SERVER_ENDPOINT
if [[ -z "$WG_SERVER_PUBKEY" || -z "$WG_SERVER_ENDPOINT" ]]; then
    printf '\n%s\n' "[!] WG_SERVER_PUBKEY/WG_SERVER_ENDPOINT are not set locally."
    printf '%s\n' "    The provisioner will still generate the VPS WireGuard keypair, but it will not bring up wg0."
    printf '%s\n' "    After adding the VPS peer on the WG server, set those values and rerun the wireguard step."
fi

#------------------------------------------------------------------------------
# Confirmation
#------------------------------------------------------------------------------
printf '\n%s\n' "=================================================="
printf '%s\n' "CHECK BEFORE STARTING:"
printf '  VPS:              root@%s\n' "$VPS_IP"
printf '  WireGuard address:%s\n' "$WG_ADDRESS"
printf '  Timezone:         %s\n' "${TIMEZONE:-<do not change>}"
printf '  Audio tunnel:     %s\n' "$([ "$AUDIO_TUNNEL_ENABLE" = "yes" ] && echo "to laptop ${AUDIO_LAPTOP_IP}" || echo "disabled")"
printf '  node_exporter:    %s\n' "$([ "$NODE_EXPORTER_ENABLE" = "yes" ] && echo "enabled on WG IP:${NODE_EXPORTER_PORT}" || echo "disabled")"
printf '  Provisioner:      %s\n' "$PROVISION"
printf '  Multilogin .deb:  %s\n' "$(basename "$MLX_DEB")"
printf '%s\n' "=================================================="
read -r -p "Start rollout? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    printf '\n%s\n' "Operation cancelled."
    pause_before_exit
    exit 1
fi

#------------------------------------------------------------------------------
# SSH: one master connection for the whole rollout
#------------------------------------------------------------------------------
CTL_PATH="$(mktemp -u /tmp/vpsprov-ssh.XXXXXX)"
SSH_OPTS=(
    -o ControlMaster=auto
    -o ControlPath="$CTL_PATH"
    -o ControlPersist=600
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=8
)

printf '\nConnecting to root@%s...\n' "$VPS_IP"
printf '%s\n\n' "SSH will now ask for the VPS root password from the hosting provider. Typed characters are not shown; that is normal."

if ! ssh "${SSH_OPTS[@]}" "root@${VPS_IP}" true; then
    die "could not connect to root@${VPS_IP}.
Check:
  • whether IP and password are correct;
  • whether this admin laptop has Internet access;
  • whether the VPS exists and is powered on;
  • whether root password login is allowed by the hosting provider."
fi

printf '\nCopying files to VPS...\n'
scp "${SSH_OPTS[@]}" "$PROVISION" "root@${VPS_IP}:/root/${REMOTE_PROVISION_NAME}" || die "failed to copy the provisioner to the VPS."
scp "${SSH_OPTS[@]}" "$MLX_DEB" "root@${VPS_IP}:/root/" || die "failed to copy the Multilogin .deb to the VPS."

printf '\n%s\n' "=================================================="
printf '%s\n' "STARTING ROLLOUT. This usually takes 20-40 minutes."
printf '%s\n' "Progress will be shown in this window. Do not close it."
printf '%s\n\n' "=================================================="

REMOTE_CMD="$(remote_env_command)"
ssh -t "${SSH_OPTS[@]}" "root@${VPS_IP}" "$REMOTE_CMD"
STATUS=$?

if (( STATUS != 0 )); then
    printf '\n%s\n' "=================================================="
    printf 'ROLLOUT FINISHED WITH AN ERROR (exit code %s).\n' "$STATUS"
    printf '%s\n' "=================================================="
    printf '%s\n' "What to do:"
    printf '%s\n' "  1. Scroll up and find the [FAIL] line; it contains the reason."
    printf '%s\n' "  2. The VPS log is /var/log/vps-provision.log"
    printf '%s\n' "  3. Most failures are safe to retry; the provisioner is designed to be idempotent."
    printf '%s\n' "  4. If retry does not help, keep this window open and escalate to the senior admin."
    pause_before_exit
    exit "$STATUS"
fi

#------------------------------------------------------------------------------
# xfce-win10.sh -> smm desktop
#------------------------------------------------------------------------------
if [[ -f "$XFCE_SCRIPT" ]]; then
    printf '\n'
    read -r -p "Copy xfce-win10.sh to the worker user's desktop? [Y/n]: " SEND_XFCE
    if [[ ! "$SEND_XFCE" =~ ^[Nn] ]]; then
        if scp "${SSH_OPTS[@]}" "$XFCE_SCRIPT" "root@${VPS_IP}:/tmp/xfce-win10.sh" \
           && ssh "${SSH_OPTS[@]}" "root@${VPS_IP}" \
                  "install -D -o ${WORK_USER} -g ${WORK_USER} -m 755 /tmp/xfce-win10.sh /home/${WORK_USER}/Desktop/xfce-win10.sh && rm -f /tmp/xfce-win10.sh"; then
            printf '%s\n' "OK: xfce-win10.sh is on the worker user's desktop."
        else
            printf '%s\n' "[!] Could not copy xfce-win10.sh; copy it manually later if needed."
        fi
    fi
fi

#------------------------------------------------------------------------------
# Final reminder
#------------------------------------------------------------------------------
printf '\n%s\n' "=================================================="
printf '%s\n' "DONE. VPS rollout completed. Manual follow-up:"
printf '%s\n' "=================================================="
printf '\n'
printf '%s\n' "1. Add the VPS to WireGuard if the tunnel was not configured yet:"
printf '%s\n' "   The VPS public key was printed in the provisioner summary"
printf '%s\n' "   and is stored on the VPS as /etc/wireguard/vps_public.key."
printf '   WG peer AllowedIPs should be: %s/32\n' "${WG_ADDRESS%%/*}"
printf '\n'
printf '%s\n' "2. Connect to the VPS with NoMachine as the worker user and run:"
printf '%s\n' "   bash ~/Desktop/xfce-win10.sh"
printf '\n'
printf '%s\n' "3. If the provisioner reported that a reboot is required, reboot the VPS:"
printf '   ssh root@%s reboot\n' "$VPS_IP"
if [[ "$AUDIO_TUNNEL_ENABLE" == "yes" ]]; then
    printf '\n'
    printf '4. Audio tunnel is configured for laptop %s. It starts when:\n' "$AUDIO_LAPTOP_IP"
    printf '%s\n' "   the laptop is provisioned with local-provision, WireGuard is up on both sides,"
    printf '%s\n' "   and the worker user is logged in on both machines. Check on the VPS as worker:"
    printf '%s\n' "     pactl list short sinks | grep laptop_out"
fi
printf '\n'
printf '%s\n' "NETWORK POLICY: verify pfSense restricts NoMachine port 4000 and SSH"
printf '%s\n' "to WireGuard or approved management networks."

pause_before_exit
exit 0
