#!/usr/bin/env bash
#==============================================================================
# local-provision.sh — provisioning the LOCAL PC (Debian 13 "trixie", physical machine)
#   as a thin client to the VPS: XFCE + NoMachine (client+server) + WireGuard + audio
#   + x11vnc fallback access to the physical screen over wg0 only.
#
# Machine class: physical thin-client laptop (original source targeted HP 255 G7 / Ryzen 5 3500U).
#
# USAGE (both parameters are REQUIRED — unique for each machine in the fleet):
#   sudo NEW_HOSTNAME=tc-05 WG_CLIENT_ADDR=10.8.0.5/24 bash local-provision.sh
#
# Debugging individual steps (comma-separated list, see the STEPS array below):
#   sudo ONLY=wireguard,watchdog WG_CLIENT_ADDR=10.8.0.5/24 bash local-provision.sh
#
# Idempotent: re-running does not break what's already been done.
#
# IMPORTANT: put xfce-win10.sh in the same folder as this script — it will be copied
#        to the service user's desktop (apply it LATER, as that user, in an active XFCE session).
#==============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# CONFIG
#------------------------------------------------------------------------------
# --- Required per-machine parameters (passed via environment) ---
NEW_HOSTNAME="${NEW_HOSTNAME:-}"        # unique machine name, e.g. tc-05
WG_CLIENT_ADDR="${WG_CLIENT_ADDR:-}"    # unique address in the tunnel, e.g. 10.8.0.5/24
                                        # WARNING: 10.8.0.2 hardcoded across the whole fleet =
                                        # address collision, the second laptop will kick out the first.

# --- Users ---
ADMIN_USER="${ADMIN_USER:-adams}"          # existing user to grant sudo to
SVC_USER="${SVC_USER:-smm}"              # service user to create, no sudo
SVC_USER_PASSWORD="${SVC_USER_PASSWORD:-CHANGE_ME_ON_FIRST_RUN}"    # SVC_USER password on creation (weak by default — change it: passwd "$SVC_USER")
# Target desktop user. Defaults to whoever invoked sudo.
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo adams)}}"

# Group for "semi-secret" files (log, WG configs/keys): not strictly root,
# but readable by members of sudo. We do NOT touch root's authorized_keys — sshd StrictModes
# doesn't like extra permissions on ~/.ssh.
ADMIN_GROUP="${ADMIN_GROUP:-sudo}"

# --- SSH: collector's public key (workmon-collect) for root's authorized_keys.
#     The private part — ONLY on the admin node.
#     Pass COLLECT_PUBKEY via the environment; do not commit real keys. ---
COLLECT_PUBKEY="${COLLECT_PUBKEY:-}"

# --- WorkMon agent (third-party installer, sits next to the script) ---
WORKMON_AGENT_DIRNAME="${WORKMON_AGENT_DIRNAME:-workmon-agent-0.4.0}"   # directory with install.sh, looked up in $SELF_DIR

# --- WireGuard (full-tunnel through the VPS) ---
WG_IFACE="${WG_IFACE:-wg0}"
WG_SERVER_PUBKEY="${WG_SERVER_PUBKEY:-REPLACE_WITH_WG_SERVER_PUBLIC_KEY}"
WG_ENDPOINT="${WG_ENDPOINT:-REPLACE_WITH_VPS_ENDPOINT:51820}"
WG_ALLOWED="${WG_ALLOWED:-0.0.0.0/0, ::/0}"
WG_KEEPALIVE="${WG_KEEPALIVE:-25}"
WG_GATEWAY="${WG_GATEWAY:-10.8.0.1}"       # used only in operator-facing checks/messages

# --- Audio tunnel (PipeWire) --------------------------------------------------
# The laptop is the TCP audio server (module-native-protocol-tcp). The paired VPS
# plays to its default sink and records from its default source. The module lives
# in the service user's pipewire-pulse config, so it survives reboots and service restarts.
AUDIO_TCP_PORT="${AUDIO_TCP_PORT:-4713}"
AUDIO_ALLOWED_IPS="${AUDIO_ALLOWED_IPS:-127.0.0.1;10.8.0.0/24}"   # auth-ip-acl: localhost + the WG subnet

# DNS through the tunnel (uncomment in wg0.conf below if the VPS has a resolver).

# Auto-start the tunnel on boot + watchdog (retries). "yes" = enable, "no" = only
# prepare the units without enabling them. WARNING for full-tunnel: if you enable "yes" BEFORE
# this peer has been added on the VPS, after a reboot the laptop will bring the tunnel up into "nowhere"
# and be left without internet. Recovery requires physical access to the laptop (see summary).
WG_AUTOSTART="${WG_AUTOSTART:-yes}"
WG_WATCHDOG_MAX_AGE="${WG_WATCHDOG_MAX_AGE:-180}"   # seconds without a handshake => watchdog recreates the tunnel

# --- NoMachine: keep the same version as on the VPS (client v9 can talk to
#     server v8, but matching versions are cleaner). Check here: downloads.nomachine.com (id=1).
#     WARNING: for a nonexistent file, the NoMachine server returns 200+HTML instead of 404,
#     so after downloading we verify it's an actual .deb. ---
NOMACHINE_BRANCH="${NOMACHINE_BRANCH:-9.7}"
NOMACHINE_VERSION="${NOMACHINE_VERSION:-9.7.3}"
NOMACHINE_BUILD="${NOMACHINE_BUILD:-1}"
NOMACHINE_MD5="${NOMACHINE_MD5:-8af5efe7b8ad3872a4681c4acf551b62}"   # empty "" = skip MD5 check.
# MD5 mismatch = STOP (die): an integrity check that just "warns and moves on"
# doesn't protect against anything. New build released — update NOMACHINE_* and MD5 deliberately.
NOMACHINE_URL="https://download.nomachine.com/download/${NOMACHINE_BRANCH}/Linux/nomachine_${NOMACHINE_VERSION}_${NOMACHINE_BUILD}_amd64.deb"

# --- Pre-configured NoMachine connection to the paired VPS desktop ------------
# yes + NX_VPS_HOST => the desktop shortcut opens a fullscreen session to that VPS
# using a generated .nxs file. Otherwise the shortcut launches bare nxplayer.
NX_CONNECT_ENABLE="${NX_CONNECT_ENABLE:-yes}"
NX_VPS_HOST="${NX_VPS_HOST:-}"                 # paired VPS WG address, e.g. 10.8.0.101
NX_VPS_PORT="${NX_VPS_PORT:-4000}"

# --- x11vnc: fallback access to the PHYSICAL laptop screen, bypassing NoMachine.
#     It listens only on the IPv4 address assigned to ${WG_IFACE}; there is no LAN/public fallback.
#     Classic VNC uses exactly 8 password characters, so keep the default/prompted value at 8 chars.
X11VNC_ENABLE="${X11VNC_ENABLE:-yes}"                    # "no" = skip the whole step
X11VNC_PASSWORD="${X11VNC_PASSWORD:-CHANGEME}"            # weak rollout default; change after provisioning
X11VNC_PORT="${X11VNC_PORT:-5900}"
X11VNC_DISPLAY="${X11VNC_DISPLAY:-:0}"                    # physical X display managed by LightDM
X11VNC_PASS_FILE="${X11VNC_PASS_FILE:-/etc/x11vnc.pass}"

# --- node_exporter: hardware/OS metrics for Prometheus on the admin node.
#     It binds only to this machine's WireGuard address, not to LAN/public interfaces.
#     With a default-drop killswitch, also allow: iifname "wg0" tcp dport 9100 accept.
NODE_EXPORTER_ENABLE="${NODE_EXPORTER_ENABLE:-yes}"
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"

# --- Windows-10 theme (B00merang): PINNED to specific commits, not master.
#     Otherwise fleet machines rolled out on different days would get different theme versions.
#     Update deliberately: git ls-remote https://github.com/<repo>.git master ---
WIN10_THEME_COMMIT="${WIN10_THEME_COMMIT:-3a4116603b66a9adcb78f3987d7ea6f01de1cbce}"   # B00merang-Project/Windows-10 (2025-08-22)
WIN10_ICONS_COMMIT="${WIN10_ICONS_COMMIT:-9f199c6b7c6050f36d0d15aaa6e9f4847e8b9066}"   # B00merang-Artwork/Windows-10

export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/local-provision.log"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
# printf instead of echo -e: echo -e interprets backslash sequences
# in the messages themselves (paths with \t etc. would get mangled).
log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*" | tee -a "$LOG"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n'   "$*" | tee -a "$LOG"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" | tee -a "$LOG"; exit 1; }

# best-effort install: failure = warning, not a full rollout stop
apt_try() { apt-get install -y "$@" || warn "Failed to install: $*  (skipping)"; }

# Backup reference: ONE .orig file with the original state instead of a pile
# of timestamped copies on every re-run.
ensure_backup() { local f="$1"; [ -f "${f}.orig" ] || cp -a "$f" "${f}.orig"; }

# key=value in /etc/default/grub: uncomment/replace, or append
set_grubcfg() {
    local key="$1" val="$2" cfg="/etc/default/grub"
    if grep -qE "^#?${key}=" "$cfg"; then
        sed -i -E "s|^#?${key}=.*|${key}=${val}|" "$cfg"
    else
        echo "${key}=${val}" >> "$cfg"
    fi
}

# NoMachine stores defaults COMMENTED OUT (#Key 1): uncomment/set
# an existing key, or append it if missing.
set_nodecfg() {
    local key="$1" val="$2" cfg="/usr/NX/etc/node.cfg"
    if grep -qE "^#?${key}[[:space:]]" "$cfg"; then
        sed -i -E "s|^#?${key}[[:space:]].*|${key} ${val}|" "$cfg"
    else
        echo "${key} ${val}" >> "$cfg"
    fi
}

# true if the step will run in this pass (respects ONLY)
will_run() { [ -z "${ONLY:-}" ] || [[ ",${ONLY}," == *",$1,"* ]]; }

#------------------------------------------------------------------------------
# Pre-checks
#------------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo bash $0"

# Log: root:sudo 640 — readable by admins via sudo group membership, but not by everyone
# (the log contains the default SVC_USER password and other rollout details).
getent group "$ADMIN_GROUP" >/dev/null || ADMIN_GROUP="root"
touch "$LOG"
chown "root:${ADMIN_GROUP}" "$LOG"
chmod 640 "$LOG"

id -u "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' not found. Set TARGET_USER in the config."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

# Required parameters are checked only if the corresponding step will actually run
if will_run hostname; then
    [ -n "$NEW_HOSTNAME" ] || die "NEW_HOSTNAME not set. Example: sudo NEW_HOSTNAME=tc-05 WG_CLIENT_ADDR=10.8.0.5/24 bash $0"
    [[ "$NEW_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "NEW_HOSTNAME '$NEW_HOSTNAME' is invalid (a-z, 0-9, hyphens; no dots/spaces)"
fi
if will_run wireguard; then
    [ -n "$WG_CLIENT_ADDR" ] || die "WG_CLIENT_ADDR not set (must be unique per machine!). Example: sudo NEW_HOSTNAME=tc-05 WG_CLIENT_ADDR=10.8.0.5/24 bash $0"
    [[ "$WG_CLIENT_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || die "WG_CLIENT_ADDR '$WG_CLIENT_ADDR' doesn't look like CIDR (expected something like 10.8.0.5/24)"
fi

trap 'die "Error at line $LINENO. Check $LOG"' ERR

log "Target desktop user: $TARGET_USER ($TARGET_HOME)"

#==============================================================================
# STEP hostname — unique machine name (required parameter)
#==============================================================================
step_hostname() {
    local cur; cur="$(cat /etc/hostname 2>/dev/null || hostname)"
    if [ "$cur" = "$NEW_HOSTNAME" ]; then
        log "hostname is already '$NEW_HOSTNAME' — skipping"
        return 0
    fi
    log "hostname: '$cur' -> '$NEW_HOSTNAME'"
    hostnamectl set-hostname "$NEW_HOSTNAME"
    # /etc/hosts: update/add 127.0.1.1, otherwise sudo/X will complain about resolving
    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sed -i -E "s|^127\.0\.1\.1[[:space:]].*|127.0.1.1\t${NEW_HOSTNAME}|" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> /etc/hosts
    fi
}

#==============================================================================
# STEP ssh_hostkeys — on this machine they somehow get wiped; restore them
#   first thing, before apt full-upgrade.
#==============================================================================
step_ssh_hostkeys() {
    log "SSH host keys: ssh-keygen -A (creates only the MISSING ones, leaves existing untouched)"
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        warn "ssh-keygen not found in PATH — openssh-client/server not installed, skipping"
        return 0
    fi
    ssh-keygen -A
    # list-unit-files exit codes changed between systemd versions — just try both units
    if systemctl restart ssh 2>/dev/null; then
        log "ssh.service restarted"
    elif systemctl restart sshd 2>/dev/null; then
        log "sshd.service restarted"
    else
        warn "ssh/sshd unit not found (openssh-server not installed?) — service not restarted"
    fi
}

#==============================================================================
# STEP collect_key — collector's public key (workmon-collect) into root's authorized_keys.
#   Needed so the admin node can pull .age files over SSH without a password (BatchMode=yes).
#   Idempotent: re-running does NOT create duplicates.
#   /root/.ssh deliberately stays strictly root (700/600): sshd StrictModes
#   rejects keys if the directory has "extra" permissions.
#==============================================================================
step_collect_key() {
    local key_body auth_keys=/root/.ssh/authorized_keys
    key_body=$(awk '{print $2}' <<<"$COLLECT_PUBKEY")
    if [[ -z "$key_body" ]]; then
        warn "COLLECT_PUBKEY is empty or doesn't look like a key — skipping authorized_keys"
        return 0
    fi
    install -d -m 700 -o root -g root /root/.ssh
    touch "$auth_keys"
    chown root:root "$auth_keys"
    chmod 600 "$auth_keys"

    # Compare by the key's base64 body (2nd field), not the whole line: a different
    # trailing comment won't create a duplicate. -F — fixed string (the key contains
    # + and /, without -F these would be treated as regex).
    if grep -qF "$key_body" "$auth_keys"; then
        log "authorized_keys: collector key already installed, skipping"
    else
        # if the file doesn't end with a newline — add one, to avoid gluing lines together
        [[ -s "$auth_keys" && -n "$(tail -c1 "$auth_keys")" ]] && printf '\n' >> "$auth_keys"
        printf '%s\n' "$COLLECT_PUBKEY" >> "$auth_keys"
        log "authorized_keys: collector key added"
    fi
}

#==============================================================================
# STEP users — sudo for adams, service user smm without sudo
#==============================================================================
step_users() {
    log "sudo package + privileges for $ADMIN_USER"
    apt-get install -y sudo
    if id -u "$ADMIN_USER" >/dev/null 2>&1; then
        usermod -aG sudo "$ADMIN_USER"
        log "$ADMIN_USER added to the sudo group"
    else
        warn "User $ADMIN_USER not found — sudo not granted"
    fi

    log "Service user $SVC_USER (no sudo)"
    if ! id -u "$SVC_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$SVC_USER"
        echo "${SVC_USER}:${SVC_USER_PASSWORD}" | chpasswd
        log "$SVC_USER created"
    else
        log "$SVC_USER already exists — skipping creation and password (so a rerun doesn't overwrite a changed password)"
    fi
    # Note for the admin doing the rollout; the log is now 640 root:sudo, not exposed to others.
    warn "$SVC_USER password = '$SVC_USER_PASSWORD' — weak, this is the default until first changed: passwd $SVC_USER"
}

#==============================================================================
# STEP grub — no pause or menu at boot
#==============================================================================
step_grub() {
    log "GRUB: TIMEOUT=0, TIMEOUT_STYLE=hidden, RECORDFAIL_TIMEOUT=0"
    ensure_backup /etc/default/grub
    set_grubcfg GRUB_TIMEOUT 0
    set_grubcfg GRUB_TIMEOUT_STYLE hidden
    set_grubcfg GRUB_RECORDFAIL_TIMEOUT 0
    update-grub
    log "GRUB updated (reference: /etc/default/grub.orig)"
}

#==============================================================================
# STEP apt_sources — contrib / non-free / non-free-firmware
#   Without this, microcode and proprietary firmware (Wi-Fi) won't arrive on physical hardware.
#==============================================================================
step_apt_sources() {
    log "Enabling contrib / non-free / non-free-firmware"
    local DEB822="/etc/apt/sources.list.d/debian.sources"
    if [ -f "$DEB822" ]; then
        # deb822 format (default in trixie): one awk pass appends ALL
        # missing components to every Components: section:
        awk '
            /^Components:/ {
                split("contrib non-free non-free-firmware", w, " ")
                for (j in w) need[w[j]] = 1
                for (i = 2; i <= NF; i++) if ($i in need) delete need[$i]
                for (c in need) { $0 = $0 " " c; delete need[c] }
            }
            { print }
        ' "$DEB822" > "$DEB822.tmp" && mv "$DEB822.tmp" "$DEB822"
    else
        # classic sources.list
        if ! grep -qE '^deb .*non-free-firmware' /etc/apt/sources.list 2>/dev/null; then
            warn "deb822 not found — adding components to /etc/apt/sources.list manually, check the result"
            sed -i -E 's/^(deb .*trixie[^ ]* main)(.*)$/\1 contrib non-free non-free-firmware\2/' /etc/apt/sources.list || true
        fi
    fi
}

#==============================================================================
# STEP upgrade — system update + firmware/microcode + kernel headers + networking
#==============================================================================
step_upgrade() {
    log "System update"
    apt-get update
    apt-get full-upgrade -y --allow-downgrades

    log "Firmware, AMD microcode, kernel headers, base utilities"
    apt-get install -y \
        amd64-microcode \
        firmware-linux-free firmware-misc-nonfree \
        firmware-amd-graphics firmware-realtek \
        linux-headers-amd64 dkms \
        curl wget gnupg ca-certificates apt-transport-https unzip htop

    log "Networking: NetworkManager (for Wi-Fi on the laptop + tray applet)"
    apt-get install -y network-manager network-manager-gnome
}

#==============================================================================
# STEP desktop — XFCE + display manager (manual login) + fonts + win10 look
#==============================================================================
install_win10_look() {
    local tmp ok=1
    tmp="$(mktemp -d)"
    # GTK + xfwm4 theme → /usr/share/themes/Windows-10 (WITHOUT a suffix, exactly).
    # Download the PINNED commit: codeload unpacks it as Windows-10-<sha>.
    if [ ! -d /usr/share/themes/Windows-10 ]; then
        if curl -fsSL -o "$tmp/theme.zip" \
             "https://codeload.github.com/B00merang-Project/Windows-10/zip/${WIN10_THEME_COMMIT}" \
           && unzip -q "$tmp/theme.zip" -d "$tmp/t"; then
            rm -rf /usr/share/themes/Windows-10
            mv "$tmp/t/Windows-10-${WIN10_THEME_COMMIT}" /usr/share/themes/Windows-10
        else ok=0; fi
    fi
    # Icons → /usr/share/icons/Windows-10
    if [ ! -d /usr/share/icons/Windows-10 ]; then
        if curl -fsSL -o "$tmp/icons.zip" \
             "https://codeload.github.com/B00merang-Artwork/Windows-10/zip/${WIN10_ICONS_COMMIT}" \
           && unzip -q "$tmp/icons.zip" -d "$tmp/i"; then
            rm -rf /usr/share/icons/Windows-10
            mv "$tmp/i/Windows-10-${WIN10_ICONS_COMMIT}" /usr/share/icons/Windows-10
            gtk-update-icon-cache -f /usr/share/icons/Windows-10 2>/dev/null || true
        else ok=0; fi
    fi
    rm -rf "$tmp"
    [ "$ok" -eq 1 ] || warn "Failed to download the Windows-10 theme — clients will fall back to Arc/Papirus"
}

step_desktop() {
    log "XFCE (desktop core)"
    apt-get install -y xfce4 xfconf dbus-x11 dbus-user-session x11-xserver-utils

    log "Required packages for the Windows-10 look"
    apt-get install -y \
        xfce4-whiskermenu-plugin \
        xfce4-pulseaudio-plugin \
        gtk2-engines-murrine \
        gvfs gvfs-daemons \
        fonts-noto fonts-noto-color-emoji fonts-liberation \
        curl unzip
        # whiskermenu — the "Start" button; pulseaudio plugin — volume tray widget
        # and multimedia keys; murrine — renders the GTK2 part of the B00merang theme;
        # gvfs — Trash/removable media on the desktop.

    log "Windows-10 theme (B00merang, pinned to a commit) into system directories"
    install_win10_look

    log "Fallback themes"
    apt_try arc-theme papirus-icon-theme

    log "Desktop extras (best-effort)"
    apt_try xfce4-goodies
    apt_try xfce4-screensaver                        # only if Win+L actually needs to lock the screen

    # Force lightdm as the default DM (no interactive dialog)
    echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
    systemctl enable lightdm >/dev/null 2>&1 || true
    # The Bibata cursor in xfce-win10.sh is optional: if not installed, it just won't
    # apply — or comment out the CursorThemeName line in xfce-win10.sh itself.
}

#==============================================================================
# STEP audio — PipeWire + pulse-shim + client utilities + TCP audio tunnel
#==============================================================================
step_audio() {
    log "PipeWire + pipewire-pulse + pactl/paplay/parecord utilities + pavucontrol"
    apt-get install -y \
        pipewire pipewire-pulse pipewire-audio wireplumber \
        pulseaudio-utils pavucontrol

    # Audio is needed specifically by SVC_USER — it runs the XFCE session and owns the audio tunnel.
    if id -u "$SVC_USER" >/dev/null 2>&1; then
        usermod -aG audio,video "$SVC_USER"
        log "$SVC_USER added to the audio,video groups"
    else
        warn "$SVC_USER not found — audio,video groups not granted and the audio tunnel was not configured"
        return 0
    fi

    # PipeWire TCP input lives only in SVC_USER's home. A system-wide fragment in /etc
    # makes every user's pipewire-pulse load it, so adams and smm can race for the same port.
    # We listen on 0.0.0.0 because wg0 may not exist at session start; auth-ip-acl restricts access.
    log "Audio tunnel: pipewire-pulse (${SVC_USER}) listening on :${AUDIO_TCP_PORT} (ACL: ${AUDIO_ALLOWED_IPS})"
    local pw_dir svc_home
    svc_home="$(getent passwd "$SVC_USER" | cut -d: -f6)"
    pw_dir="${svc_home}/.config/pipewire/pipewire-pulse.conf.d"
    install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 "$pw_dir"
    cat > "${pw_dir}/50-wg-audio.conf" <<EOF
# Managed by local-provision.sh
pulse.cmd = [
    { cmd = "load-module"
      args = "module-native-protocol-tcp listen=0.0.0.0 port=${AUDIO_TCP_PORT} auth-ip-acl=${AUDIO_ALLOWED_IPS}" }
]
EOF
    chown "$SVC_USER:$SVC_USER" "${pw_dir}/50-wg-audio.conf"
    chmod 644 "${pw_dir}/50-wg-audio.conf"

    # Legacy cleanup: the system-wide variant caused two user instances to race for the port.
    rm -f /etc/pipewire/pipewire-pulse.conf.d/50-wg-audio.conf

    # If SVC_USER already has a live session, try to pick up the config immediately.
    # On a fresh rollout there is no session yet, so it will load on first XFCE login.
    systemctl --user -M "${SVC_USER}@" restart pipewire-pulse >/dev/null 2>&1 \
        || log "${SVC_USER} session not active — config will take effect on first XFCE login"
}

#==============================================================================
# STEP audioprio — force the built-in audio card to start in duplex mode
#   Fixes the output-only profile where no audio source exists and the microphone
#   (including a 3.5mm headset) is dead. The conf.d rule sets the startup profile;
#   jack detection can still pick the active port afterward.
#==============================================================================
step_audioprio() {
    log "WirePlumber: duplex profile rule for built-in audio card"

    install -d -m 755 /etc/wireplumber/wireplumber.conf.d
    cat > /etc/wireplumber/wireplumber.conf.d/50-analog-duplex.conf <<'EOF'
# Managed by local-provision.sh
# Built-in Realtek: force duplex profile on start so PipeWire does not come up output-only.
# Matching by alsa.mixer_name survives PCI path or hardware model changes.
monitor.alsa.rules = [
  {
    matches = [ { alsa.mixer_name = "~Realtek.*" } ]
    actions = { update-props = { device.profile = "output:analog-stereo+input:analog-stereo" } }
  }
]
EOF

    # If the user session is live, best-effort apply the duplex profile right now.
    # HDMI cards will silently reject this profile; the Realtek card should apply it.
    if pgrep -u "$SVC_USER" wireplumber >/dev/null 2>&1; then
        local card
        for card in $(systemd-run --quiet --pipe --machine="${SVC_USER}@" --user \
                          pactl list short cards 2>/dev/null | awk '{print $2}'); do
            systemd-run --quiet --pipe --machine="${SVC_USER}@" --user \
                pactl set-card-profile "$card" \
                output:analog-stereo+input:analog-stereo 2>/dev/null || true
        done
    fi
}

#==============================================================================
# STEP wireguard — install + client keypair + wg0.conf (do NOT bring it up!)
#==============================================================================
step_wireguard() {
    log "WireGuard: installation and client key generation"
    apt-get install -y wireguard wireguard-tools

    # Directory and files: root:sudo, group-readable — the admin can read without su.
    install -d -m 750 -o root -g "$ADMIN_GROUP" /etc/wireguard
    if [ ! -f /etc/wireguard/client_private.key ]; then
        ( umask 027
          wg genkey | tee /etc/wireguard/client_private.key | wg pubkey > /etc/wireguard/client_public.key )
        chown "root:${ADMIN_GROUP}" /etc/wireguard/client_private.key /etc/wireguard/client_public.key
        log "Client keypair generated"
    else
        log "Client key already exists — reusing"
    fi
    local client_priv
    client_priv="$(cat /etc/wireguard/client_private.key)"

    # Rebuild the config on every run (idempotent). IMPORTANT: set permissions
    # BEFORE writing PrivateKey — install creates an empty file with the right mode,
    # cat > only fills it in. No window where the key sits at 644.
    install -m 640 -o root -g "$ADMIN_GROUP" /dev/null "/etc/wireguard/${WG_IFACE}.conf"
    cat > "/etc/wireguard/${WG_IFACE}.conf" <<EOF
[Interface]
PrivateKey = ${client_priv}
Address = ${WG_CLIENT_ADDR}
# DNS = 10.8.0.1   # uncomment if the VPS has a DNS resolver and you want resolution through the tunnel
                   # (full-tunnel => otherwise DNS may "leak" around the VPS; requires openresolv/systemd-resolved)

[Peer]
PublicKey = ${WG_SERVER_PUBKEY}
Endpoint = ${WG_ENDPOINT}
AllowedIPs = ${WG_ALLOWED}
PersistentKeepalive = ${WG_KEEPALIVE}
EOF

    # Keep NetworkManager/nm-applet away from WireGuard; wg-quick/systemd own it.
    if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
        install -d -m 755 /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/90-unmanaged-wireguard.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${WG_IFACE}
EOF
        log "NetworkManager unmanaged rule installed for ${WG_IFACE}"
    fi

    log "Wrote /etc/wireguard/${WG_IFACE}.conf, Address=${WG_CLIENT_ADDR} (NOT bringing up the tunnel in this run)"
}

#==============================================================================
# STEP watchdog — WG auto-start + recreating a stale tunnel
#   WireGuard retries the handshake itself (there's PersistentKeepalive), but it doesn't cover:
#     - the boot race (network not ready, wg-quick@ failed and didn't retry),
#     - waking from suspend (the tunnel is "stuck" with a stale handshake),
#     - the server being temporarily unreachable at startup.
#   Every 30s the watchdog checks the AGE of the last handshake and recreates the tunnel
#   if it's stale. On full-tunnel this is more reliable than ping (ping doesn't get through
#   a dead tunnel anyway).
#==============================================================================
step_watchdog() {
    log "WireGuard watchdog (script + systemd timer)"
    # The script is entirely static (quoted heredoc, single piece); parameters
    # come in via Environment= from the unit — configuration lives where it belongs.
    cat > /usr/local/sbin/wg-watchdog.sh <<'EOF'
#!/usr/bin/env bash
set -u
IFACE="${WG_IFACE:-wg0}"
MAX_AGE="${WG_MAX_AGE:-180}"
log() { logger -t wg-watchdog "$*"; }

# 1) interface doesn't exist — bring it up (boot race / after shutdown)
if ! wg show "$IFACE" >/dev/null 2>&1; then
    if wg-quick up "$IFACE" 2>/dev/null; then log "interface was down — up"; else log "up failed (server unreachable?)"; fi
    exit 0
fi

# 2) most recent handshake among peers
last="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)"
[ -z "$last" ] && last=0

# no handshake yet at all — WG retries on its own via keepalive, don't touch it
[ "$last" -eq 0 ] && exit 0

age=$(( $(date +%s) - last ))
if [ "$age" -gt "$MAX_AGE" ]; then
    log "handshake age ${age}s > ${MAX_AGE}s — reconnect"
    wg-quick down "$IFACE" 2>/dev/null || true
    wg-quick up   "$IFACE" 2>/dev/null || log "reconnect up failed"
fi
exit 0
EOF
    chmod +x /usr/local/sbin/wg-watchdog.sh

    cat > /etc/systemd/system/wg-watchdog.service <<EOF
[Unit]
Description=WireGuard watchdog (reconnect ${WG_IFACE})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=WG_IFACE=${WG_IFACE} WG_MAX_AGE=${WG_WATCHDOG_MAX_AGE}
ExecStart=/usr/local/sbin/wg-watchdog.sh
EOF

    cat > /etc/systemd/system/wg-watchdog.timer <<'EOF'
[Unit]
Description=Run WireGuard watchdog periodically

[Timer]
OnBootSec=20
OnUnitActiveSec=30
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    if [ "$WG_AUTOSTART" = "yes" ]; then
        systemctl enable "wg-quick@${WG_IFACE}.service" >/dev/null 2>&1 || warn "failed to enable wg-quick@${WG_IFACE}"
        systemctl enable wg-watchdog.timer            >/dev/null 2>&1 || warn "failed to enable wg-watchdog.timer"
        log "Auto-start ENABLED: wg-quick@${WG_IFACE} (boot) + wg-watchdog.timer (retries every 30s)"
        warn "The tunnel will kick in after a reboot. Add the peer on the VPS first (otherwise full-tunnel goes nowhere)."
    else
        log "Auto-start NOT enabled (WG_AUTOSTART=no). Units installed but disabled."
    fi
    # Not touching the current session: bring the tunnel up manually when you're ready (see summary).
}

#==============================================================================
# STEP nomachine — full package (client + server: this machine can also be
#   connected TO) + node.cfg configuration
#==============================================================================
step_nomachine() {
    log "NoMachine ${NOMACHINE_VERSION} (full: client + server)"
    if ! dpkg -s nomachine >/dev/null 2>&1; then
        local tmp_deb got
        tmp_deb="$(mktemp --suffix=.deb)"
        curl -L -f -A "Mozilla/5.0" -o "$tmp_deb" "$NOMACHINE_URL" \
            || die "curl failed to download NoMachine: $NOMACHINE_URL"
        # NoMachine returns 200+HTML for a nonexistent file — catching that here.
        if ! dpkg-deb --info "$tmp_deb" >/dev/null 2>&1; then
            warn "The downloaded file is NOT a valid .deb. First bytes:"
            head -c 80 "$tmp_deb" | tr -d '\0' | tee -a "$LOG" || true
            rm -f "$tmp_deb"
            die "Looks like version ${NOMACHINE_VERSION}_${NOMACHINE_BUILD} isn't available on the server. Check downloads.nomachine.com (id=1) and fix NOMACHINE_* in the config."
        fi
        if [ -n "$NOMACHINE_MD5" ]; then
            got="$(md5sum "$tmp_deb" | awk '{print $1}')"
            if [ "$got" != "$NOMACHINE_MD5" ]; then
                rm -f "$tmp_deb"
                die "MD5 mismatch (expected $NOMACHINE_MD5, got $got). New build released? Check the version and MD5 on downloads.nomachine.com and update NOMACHINE_* in the config."
            fi
        fi
        apt-get install -y "$tmp_deb"
        rm -f "$tmp_deb"
    else
        log "NoMachine already installed — skipping"
    fi

    # --- node.cfg: XFCE session + quiet mode. One backup and one restart for all edits.
    local NODE_CFG="/usr/NX/etc/node.cfg"
    if [ -f "$NODE_CFG" ]; then
        ensure_backup "$NODE_CFG"
        # XFCE as the session — otherwise a gray screen on an INCOMING connection to this machine.
        set_nodecfg DefaultDesktopCommand '"/usr/bin/startxfce4"'
        # Quiet client: remove the on-screen banner "desktop is being viewed"...
        set_nodecfg ShowDesktopViewed 0
        # ...and the sound alert on connect.
        set_nodecfg EnableSoundAlert 0
        /usr/NX/bin/nxserver --restart >/dev/null 2>&1 || warn "Failed to restart nxserver"
        log "node.cfg: DefaultDesktopCommand=startxfce4, ShowDesktopViewed=0, EnableSoundAlert=0 (reference: node.cfg.orig)"
    else
        warn "node.cfg not found — NoMachine not installed? Skipping configuration."
    fi
}

#==============================================================================
# STEP x11vnc — fallback VNC to the physical X display, listening only on wg0.
#   This is an independent rescue path when the laptop-side NoMachine service is
#   broken or misconfigured. The runner discovers the IPv4 address on ${WG_IFACE};
#   no address means no listener, so there is never a 0.0.0.0 fallback.
#==============================================================================
step_x11vnc() {
    if [ "$X11VNC_ENABLE" != "yes" ]; then
        log "x11vnc disabled (X11VNC_ENABLE=no) — skipping"
        return 0
    fi

    log "x11vnc: physical-screen fallback over ${WG_IFACE}"
    apt-get install -y --no-install-recommends x11vnc

    [ ${#X11VNC_PASSWORD} -eq 8 ] \
        || die "X11VNC_PASSWORD must be exactly 8 characters (classic VNC limit), got: ${#X11VNC_PASSWORD}"

    # If the password file already exists, keep it. This avoids overwriting a changed
    # local password on reruns, mirroring the SVC_USER password behavior.
    if [ -f "$X11VNC_PASS_FILE" ]; then
        log "x11vnc: $X11VNC_PASS_FILE already exists — leaving password unchanged"
    else
        # x11vnc -storepasswd does not work reliably from stdin in non-interactive runs;
        # during rollout there should be no hostile local users watching ps output.
        ( umask 077
          x11vnc -storepasswd "$X11VNC_PASSWORD" "$X11VNC_PASS_FILE" >/dev/null )
        chown root:root "$X11VNC_PASS_FILE"
        chmod 600 "$X11VNC_PASS_FILE"
        warn "x11vnc password is the rollout default. Change it: sudo x11vnc -storepasswd $X11VNC_PASS_FILE && sudo systemctl restart x11vnc"
    fi

    install -m 640 -o root -g "$ADMIN_GROUP" /dev/null /etc/default/x11vnc
    cat > /etc/default/x11vnc <<EOF
# Managed by local-provision.sh
INTERFACE="${WG_IFACE}"
PORT="${X11VNC_PORT}"
DISPLAY_NUMBER="${X11VNC_DISPLAY}"
PASS_FILE="${X11VNC_PASS_FILE}"
EOF

    cat > /usr/local/sbin/x11vnc-service <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/default/x11vnc"
[ -r "$CONFIG_FILE" ] || { echo "Missing config: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091
source "$CONFIG_FILE"

bind_ip="$(ip -4 -o addr show dev "$INTERFACE" scope global 2>/dev/null \
    | awk 'NR == 1 { split($4, a, "/"); print a[1] }')"
if [ -z "$bind_ip" ]; then
    echo "No IPv4 address on $INTERFACE yet; retrying via systemd" >&2
    exit 1
fi

# FD_XDM=1 + -auth guess covers both the LightDM greeter and the logged-in user session.
exec /usr/bin/x11vnc \
    -env FD_XDM=1 \
    -auth guess \
    -display "$DISPLAY_NUMBER" \
    -forever \
    -shared \
    -repeat \
    -nolookup \
    -rfbauth "$PASS_FILE" \
    -rfbport "$PORT" \
    -listen "$bind_ip" \
    -no6
EOF
    chmod 755 /usr/local/sbin/x11vnc-service

    cat > /etc/systemd/system/x11vnc.service <<EOF
[Unit]
Description=x11vnc on the physical X display (${WG_IFACE} only)
Documentation=man:x11vnc(1)
Wants=network-online.target
After=network-online.target display-manager.service wg-quick@${WG_IFACE}.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/sbin/x11vnc-service
Restart=always
RestartSec=5s
TimeoutStopSec=10s

[Install]
WantedBy=graphical.target
EOF

    systemctl daemon-reload
    systemctl enable x11vnc.service >/dev/null 2>&1 || warn "failed to enable x11vnc.service"
    # Do not start now: wg0 is usually still down and the service would only spin in retries.
    log "x11vnc.service installed and enabled; it will listen after ${WG_IFACE} has an IPv4 address"
}

#==============================================================================
# STEP node_exporter — Prometheus metrics bound only to the WireGuard address
#   Binding to the concrete wg IP means the port does not exist on LAN/public interfaces.
#   Until the tunnel is up, the bind fails and systemd retries every 5s (same pattern as x11vnc).
#==============================================================================
step_node_exporter() {
    if [ "$NODE_EXPORTER_ENABLE" != "yes" ]; then
        log "node_exporter disabled (NODE_EXPORTER_ENABLE=no) — skipping"
        return 0
    fi

    local wg_ip="${WG_CLIENT_ADDR%%/*}"
    [ -n "$wg_ip" ] || die "node_exporter: WG_CLIENT_ADDR is empty; cannot choose a bind address"

    log "node_exporter: metrics on ${wg_ip}:${NODE_EXPORTER_PORT} (${WG_IFACE} only)"
    # --no-install-recommends avoids extra collector cron packages; add those deliberately if needed.
    apt-get install -y --no-install-recommends prometheus-node-exporter

    ensure_backup /etc/default/prometheus-node-exporter
    cat > /etc/default/prometheus-node-exporter <<EOF
# Managed by local-provision.sh
ARGS="--web.listen-address=${wg_ip}:${NODE_EXPORTER_PORT}"
EOF

    install -d /etc/systemd/system/prometheus-node-exporter.service.d
    cat > /etc/systemd/system/prometheus-node-exporter.service.d/override.conf <<'EOF'
# Managed by local-provision.sh: wg0 may come up after this service on boot
[Unit]
StartLimitIntervalSec=0
[Service]
Restart=always
RestartSec=5
EOF

    systemctl daemon-reload
    systemctl enable prometheus-node-exporter >/dev/null 2>&1 || warn "failed to enable prometheus-node-exporter"
    systemctl restart prometheus-node-exporter \
        || warn "node_exporter did not start (tunnel not up?) — it should start automatically after wg0 is up"
    log "node_exporter: enabled; verify from the admin node: curl http://${wg_ip}:${NODE_EXPORTER_PORT}/metrics"
}

#==============================================================================
# STEP win10_script — copy xfce-win10.sh to the service user's desktop.
#   Apply it LATER as that user, in an active XFCE session.
#==============================================================================
step_win10_script() {
    local src="$SELF_DIR/xfce-win10.sh"

    if ! id -u "$SVC_USER" >/dev/null 2>&1; then
        warn "User $SVC_USER not found — xfce-win10.sh was not copied"
        return 0
    fi

    local svc_home desktop_dir dst
    svc_home="$(getent passwd "$SVC_USER" | cut -d: -f6)"
    desktop_dir="${svc_home}/Desktop"
    dst="${desktop_dir}/xfce-win10.sh"

    if [ ! -f "$src" ]; then
        warn "xfce-win10.sh not found next to the script: $src"
        return 0
    fi

    install -d -m 755 -o "$SVC_USER" -g "$SVC_USER" "$desktop_dir"
    install -m 755 -o "$SVC_USER" -g "$SVC_USER" "$src" "$dst"
    log "xfce-win10.sh copied to $SVC_USER's desktop: $dst"
}

#==============================================================================
# STEP nm_shortcut — NoMachine shortcut on the desktop (client for connecting to the VPS)
#   IMPORTANT: we do NOT copy the system .desktop files from /usr/share/applications — those
#   contain the web-session MIME handler (NoDisplay=true, Exec ... --session), not a launcher.
#   Generating OUR OWN clean launcher pointed at plain nxplayer (stable path: /usr/NX/bin).
#==============================================================================
step_nm_shortcut() {
    if ! id -u "$SVC_USER" >/dev/null 2>&1; then
        warn "User $SVC_USER not found — NoMachine shortcut not created"
        return 0
    fi
    local svc_home desktop_dir nm_dst nm_icon bin_dir autostart_dir
    svc_home="$(getent passwd "$SVC_USER" | cut -d: -f6)"
    log "NoMachine desktop shortcut ($SVC_USER)"

    # --- Pin XDG_DESKTOP_DIR=~/Desktop BEFORE the user's first login. Otherwise, with a
    # Russian locale, xdg-user-dirs-update would create a localized "Desktop" folder on first login,
    # XFCE would show that folder, and our shortcut would sit in the invisible Desktop folder.
    # An existing entry in user-dirs.dirs takes priority — xdg won't overwrite it.
    install -d -o "$SVC_USER" -g "$SVC_USER" "${svc_home}/.config"
    if [ ! -f "${svc_home}/.config/user-dirs.dirs" ]; then
        cat > "${svc_home}/.config/user-dirs.dirs" <<'EOF'
XDG_DESKTOP_DIR="$HOME/Desktop"
EOF
        log "user-dirs.dirs: XDG_DESKTOP_DIR pinned to ~/Desktop (guards against a Russian-locale localized \"Desktop\" folder)"
    fi

    desktop_dir="${svc_home}/Desktop"
    mkdir -p "$desktop_dir"

    nm_dst="${desktop_dir}/nomachine.desktop"
    nm_icon="$(find /usr/NX /usr/share/icons -type f \
        \( -iname 'nxplayer*.png' -o -iname 'nxplayer*.svg' \
           -o -iname 'nomachine*.png' -o -iname 'nomachine*.svg' \) 2>/dev/null | head -n1)"
    [ -z "$nm_icon" ] && nm_icon="nxplayer"

    # Optional pre-configured .nxs session: the shortcut opens the paired VPS fullscreen.
    # The client will ask for credentials/trust on first connect and saves them in this file.
    local nm_exec="/usr/NX/bin/nxplayer"
    if [ "$NX_CONNECT_ENABLE" = "yes" ] && [ -n "$NX_VPS_HOST" ]; then
        local nxs_dir="${svc_home}/.local/share/nomachine"
        install -d -o "$SVC_USER" -g "$SVC_USER" "$nxs_dir"
        cat > "${nxs_dir}/VPS.nxs" <<EOF
<!DOCTYPE NXClientSettings>
<NXClientSettings application="nxclient" version="2.1">
  <group name="General">
    <option key="Server host" value="${NX_VPS_HOST}" />
    <option key="Server port" value="${NX_VPS_PORT}" />
    <option key="Session window state" value="fullscreen" />
  </group>
</NXClientSettings>
EOF
        chown "${SVC_USER}:${SVC_USER}" "${nxs_dir}/VPS.nxs"
        chmod 600 "${nxs_dir}/VPS.nxs"
        nm_exec="/usr/NX/bin/nxplayer --session ${nxs_dir}/VPS.nxs"
        log "Pre-configured NoMachine connection: ${nxs_dir}/VPS.nxs (${NX_VPS_HOST}:${NX_VPS_PORT}, fullscreen)"
    elif [ "$NX_CONNECT_ENABLE" = "yes" ]; then
        warn "NX_CONNECT_ENABLE=yes but NX_VPS_HOST is empty — shortcut will launch bare nxplayer"
    fi

    cat > "$nm_dst" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=NoMachine
Comment=Connect to the remote desktop
Exec=${nm_exec}
Icon=${nm_icon}
Terminal=false
Categories=Network;RemoteAccess;
EOF
    chmod +x "$nm_dst"

    # Marking as "trusted" in XFCE requires a LIVE session (gvfs). At rollout time there
    # isn't one, so we set up a one-shot autostart: on first login it stamps a sha256
    # checksum and removes itself. After that the icon launches without an "Allow execution?" prompt.
    log "One-shot autostart to mark the shortcut trusted (fires on $SVC_USER's first login)"
    bin_dir="${svc_home}/.local/bin"
    autostart_dir="${svc_home}/.config/autostart"
    mkdir -p "$bin_dir" "$autostart_dir"
    cat > "${bin_dir}/nm-trust-once.sh" <<'EOF'
#!/usr/bin/env bash
# Belt and suspenders: ask xdg for the real desktop directory,
# fall back to default ~/Desktop if unavailable (we've pinned it in user-dirs.dirs).
d="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
[ -n "$d" ] || d="$HOME/Desktop"
f="$d/nomachine.desktop"
[ -f "$f" ] || exit 0
chmod +x "$f"
gio set "$f" metadata::xfce-exe-checksum "$(sha256sum "$f" | cut -d' ' -f1)" 2>/dev/null || true
rm -f "$HOME/.config/autostart/nm-trust-once.desktop"
EOF
    chmod +x "${bin_dir}/nm-trust-once.sh"
    cat > "${autostart_dir}/nm-trust-once.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=NoMachine trust once
Exec=${bin_dir}/nm-trust-once.sh
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    # Targeted chown of only what this step created (instead of a final chown -R on the whole home)
    chown -R "${SVC_USER}:${SVC_USER}" \
        "$desktop_dir" "${svc_home}/.config" "${svc_home}/.local"
}

#==============================================================================
# STEP power — keep the screen on and disable locking for the service user.
#   No xfconf-query here: during rollout there is no live ${SVC_USER} session, so
#   we lay down per-channel XML for first login plus a small xset autostart.
#==============================================================================
step_power() {
    if ! id -u "$SVC_USER" >/dev/null 2>&1; then
        warn "User $SVC_USER not found — power/locking settings were not applied"
        return 0
    fi

    local svc_home xml_dir bin_dir autostart_dir
    svc_home="$(getent passwd "$SVC_USER" | cut -d: -f6)"
    log "Power/locking for $SVC_USER: screen always on, local lock disabled"

    if pgrep -u "$SVC_USER" xfconfd >/dev/null 2>&1; then
        warn "$SVC_USER has a live session (xfconfd is running); XML may be overwritten on logout"
        warn "Apply settings inside the session with xfconf-query, or log the user out and rerun ONLY=power"
    fi

    xml_dir="${svc_home}/.config/xfce4/xfconf/xfce-perchannel-xml"
    install -d "$xml_dir"

    cat > "${xml_dir}/xfce4-power-manager.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="presentation-mode" type="bool" value="true"/>
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="blank-on-battery" type="int" value="0"/>
    <property name="dpms-on-ac-sleep" type="uint" value="0"/>
    <property name="dpms-on-ac-off" type="uint" value="0"/>
    <property name="dpms-on-battery-sleep" type="uint" value="0"/>
    <property name="dpms-on-battery-off" type="uint" value="0"/>
    <property name="inactivity-on-ac" type="uint" value="0"/>
    <property name="inactivity-on-battery" type="uint" value="0"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
    <property name="logind-handle-lid-switch" type="bool" value="false"/>
    <property name="lid-action-on-ac" type="uint" value="0"/>
    <property name="lid-action-on-battery" type="uint" value="0"/>
  </property>
</channel>
EOF

    cat > "${xml_dir}/xfce4-screensaver.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty">
    <property name="enabled" type="bool" value="false"/>
    <property name="idle-activation" type="empty">
      <property name="enabled" type="bool" value="false"/>
    </property>
  </property>
  <property name="lock" type="empty">
    <property name="enabled" type="bool" value="false"/>
  </property>
</channel>
EOF

    autostart_dir="${svc_home}/.config/autostart"
    install -d "$autostart_dir"
    cat > "${autostart_dir}/light-locker.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Screen Locker
Hidden=true
EOF

    bin_dir="${svc_home}/.local/bin"
    install -d "$bin_dir"
    cat > "${bin_dir}/noblank.sh" <<'EOF'
#!/usr/bin/env bash
xset s off
xset s noblank
xset -dpms
EOF
    chmod +x "${bin_dir}/noblank.sh"
    cat > "${autostart_dir}/noblank.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=No blank / no DPMS
Exec=${bin_dir}/noblank.sh
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

    chown -R "${SVC_USER}:${SVC_USER}" "${svc_home}/.config" "${svc_home}/.local"

    install -d -m 755 /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/20-noblank.conf <<'EOF'
# Managed by local-provision.sh: keep both the greeter and user session from blanking.
[Seat:*]
xserver-command=X -s 0 -dpms
EOF
    log "power: XFPM/screensaver XML, light-locker disabled for $SVC_USER, xset autostart, lightdm -s 0 -dpms"
}

#==============================================================================
# STEP workmon — install the agent from a directory next to the script
#==============================================================================
step_workmon() {
    local dir="$SELF_DIR/$WORKMON_AGENT_DIRNAME" installer
    installer="$dir/install.sh"
    if [ -f "$installer" ]; then
        log "Running the WorkMon agent installer: $installer"
        chmod +x "$installer"
        ( cd "$dir" && bash "$installer" ) || die "WorkMon agent installation failed"
        log "WorkMon agent installed"
    else
        warn "$installer not found — skipping WorkMon agent installation. Put $WORKMON_AGENT_DIRNAME next to the script and rerun."
    fi
}

#==============================================================================
# STEP summary — final report
#==============================================================================
step_summary() {
    local client_pub wg_peer_ip
    client_pub="$(cat /etc/wireguard/client_public.key 2>/dev/null || echo '<key not generated yet — run the wireguard step>')"
    wg_peer_ip="${WG_CLIENT_ADDR%%/*}"
    [ -n "$wg_peer_ip" ] || wg_peer_ip="<WG_CLIENT_ADDR>"

    log "DONE. Summary:"
    echo "  Hostname:     $(cat /etc/hostname 2>/dev/null || hostname)"
    echo "  Desktop:      XFCE, login via lightdm (manual)."
    echo "  Power:        screen stays on for greeter and ${SVC_USER}; local lock disabled for ${SVC_USER}."
    echo "  Software:     NoMachine (client+server), WireGuard, PipeWire+audio tunnel, NetworkManager, x11vnc, node_exporter."
    echo
    echo "  >>> THIS CLIENT'S PUBLIC KEY (add as a [Peer] on the WG server):"
    echo "      $client_pub"
    echo "      (server-side AllowedIPs = ${wg_peer_ip}/32 for this peer)"
    echo
    warn "NEXT — in order (full-tunnel: a bad WG peer can cut internet, so do this AT the laptop):"
    echo "   1) Add the key above as a peer on the WireGuard server/firewall."
    echo "   2) Here, bring up the tunnel:        sudo wg-quick up ${WG_IFACE}"
    echo "      Check:                            ping ${WG_GATEWAY}   and   curl ifconfig.me"
    echo "   3) Auto-start + retries: WG_AUTOSTART=${WG_AUTOSTART}."
    if [ "$WG_AUTOSTART" = "yes" ]; then
        echo "      ALREADY enabled: wg-quick@${WG_IFACE} (boot) + wg-watchdog.timer (revives a dead tunnel every 30s)."
        echo "      The tunnel will come up after a reboot — but only if the peer exists on the server."
        echo "      IF INTERNET DROPS (peer not configured yet):"
        echo "        sudo systemctl disable --now wg-quick@${WG_IFACE} wg-watchdog.timer && sudo wg-quick down ${WG_IFACE}"
    else
        echo "      Units installed but disabled. To enable:  sudo systemctl enable --now wg-quick@${WG_IFACE} wg-watchdog.timer"
    fi
    echo "   4) Audio tunnel starts automatically with pipewire-pulse in the ${SVC_USER} session."
    echo "      Port: ${AUDIO_TCP_PORT}; ACL: ${AUDIO_ALLOWED_IPS}."
    echo "      Verify after login with WG up:  pactl list short modules | grep native-protocol-tcp"
    echo "      If a killswitch drops inbound traffic, allow: iifname \"${WG_IFACE}\" tcp dport ${AUDIO_TCP_PORT} accept"
    echo "   5) Launch NoMachine from the ${SVC_USER} desktop shortcut."
    if [ "$NX_CONNECT_ENABLE" = "yes" ] && [ -n "$NX_VPS_HOST" ]; then
        echo "      It opens a fullscreen session to ${NX_VPS_HOST}:${NX_VPS_PORT}."
    else
        echo "      Add the matching VPS connection manually: host = VPS WireGuard address, protocol NX."
    fi
    echo "   6) Log in to XFCE as ${SVC_USER} and apply the look:   bash ~/Desktop/xfce-win10.sh   (NOT as root)."
    if [ "$NODE_EXPORTER_ENABLE" = "yes" ]; then
        echo "   7) From the admin node, verify metrics: curl http://${wg_peer_ip}:${NODE_EXPORTER_PORT}/metrics"
        echo "      Add this machine to Prometheus targets after confirming the endpoint."
    fi
    echo
    echo "   Watchdog diagnostics:  journalctl -t wg-watchdog -n 30   |   systemctl list-timers wg-watchdog.timer"
    echo "   Rollout log:           $LOG  (root:${ADMIN_GROUP}, 640)"
    echo
    warn "Security: the NoMachine server listens on port 4000 — do not forward it to the internet."
    echo "   Reach this machine only over LAN or via wg0 (${wg_peer_ip})."
    if [ "$X11VNC_ENABLE" = "yes" ]; then
        echo
        echo "  x11vnc fallback to the PHYSICAL screen, bypassing NoMachine:"
        echo "      Connection: ${wg_peer_ip}:${X11VNC_PORT} — only after ${WG_IFACE} has this address."
        warn "      VNC password uses the rollout default unless you supplied X11VNC_PASSWORD. Change it immediately after rollout."
        echo "      Change: sudo x11vnc -storepasswd ${X11VNC_PASS_FILE} && sudo systemctl restart x11vnc"
        echo "      If a firewall default-drop policy is added, allow: iifname \"${WG_IFACE}\" tcp dport ${X11VNC_PORT} accept"
        echo "      Diagnostics: systemctl status x11vnc --no-pager | ss -ltnp | grep :${X11VNC_PORT}"
    fi
    log "A reboot is recommended so firmware/microcode gets picked up and lightdm starts:  sudo reboot"
}

#==============================================================================
# DISPATCHER
#==============================================================================
# Order matters: hostname/ssh — before full-upgrade; desktop — before nomachine
# (node.cfg references startxfce4); wireguard — before summary (key for the summary).
STEPS=(
    hostname
    ssh_hostkeys
    collect_key
    users
    grub
    apt_sources
    upgrade
    desktop
    audio
    audioprio
    wireguard
    watchdog
    nomachine
    x11vnc
    node_exporter
    win10_script
    nm_shortcut
    power
    workmon
    summary
)

main() {
    local s
    if [ -n "${ONLY:-}" ]; then
        warn "ONLY=${ONLY} mode — running only the listed steps"
    fi
    for s in "${STEPS[@]}"; do
        will_run "$s" || continue
        "step_${s}"
    done
}

main "$@"
