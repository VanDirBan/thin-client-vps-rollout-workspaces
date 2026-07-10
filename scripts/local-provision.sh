#!/usr/bin/env bash
#==============================================================================
# local-provision.sh — provisioning the LOCAL PC (Debian 13 "trixie", physical machine)
#   as a thin client to the VPS: XFCE + NoMachine (client+server) + WireGuard + audio.
#
# Machine: HP 255 G7, AMD Ryzen 5 3500U (Picasso/Vega).
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
#        to the target user (apply it LATER, as the user, in an active XFCE session).
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
        gtk2-engines-murrine \
        gvfs gvfs-daemons \
        fonts-noto fonts-noto-color-emoji fonts-liberation \
        curl unzip
        # whiskermenu — the "Start" button; murrine — renders the GTK2 part of the
        # B00merang theme; gvfs — Trash/removable media on the desktop.

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
# STEP audio — PipeWire + pulse-shim + client utilities (needed for the .md procedure)
#==============================================================================
step_audio() {
    log "PipeWire + pipewire-pulse + pactl/paplay/parecord utilities + pavucontrol"
    apt-get install -y \
        pipewire pipewire-pulse pipewire-audio wireplumber \
        pulseaudio-utils pavucontrol
    # Audio is needed specifically by SVC_USER — it runs the XFCE session and drives the audio tunnel.
    if id -u "$SVC_USER" >/dev/null 2>&1; then
        usermod -aG audio,video "$SVC_USER"
        log "$SVC_USER added to the audio,video groups"
    else
        warn "$SVC_USER not found — audio,video groups not granted"
    fi
    # The tunnel modules themselves are loaded manually per your .md, AFTER bringing up WG.
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
# STEP win10_script — copy xfce-win10.sh to the user (apply it LATER, as the user,
#   in an active XFCE session)
#==============================================================================
step_win10_script() {
    local src="$SELF_DIR/xfce-win10.sh"
    if [ -f "$src" ]; then
        cp -f "$src" "$TARGET_HOME/xfce-win10.sh"
        chmod +x "$TARGET_HOME/xfce-win10.sh"
        chown "${TARGET_USER}:${TARGET_USER}" "$TARGET_HOME/xfce-win10.sh"
        log "xfce-win10.sh copied to $TARGET_HOME (run it as the user in an active XFCE session)"
    else
        warn "xfce-win10.sh not found next to the script — skipping. Put it in $SELF_DIR and rerun, or apply it manually."
    fi
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
    cat > "$nm_dst" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=NoMachine
Comment=Connect to the remote desktop
Exec=/usr/NX/bin/nxplayer
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
    echo "  Software:     NoMachine (client+server), WireGuard, PipeWire+utilities, NetworkManager."
    echo
    echo "  >>> THIS CLIENT'S PUBLIC KEY (add as a [Peer] on the VPS):"
    echo "      $client_pub"
    echo "      (on the VPS: AllowedIPs = ${wg_peer_ip}/32 for this peer)"
    echo
    warn "NEXT — in order (full-tunnel: mess up WG and you'll lose internet, so do this AT the laptop):"
    echo "   1) Add the key above to /etc/wireguard/wg0.conf on the VPS, then on the VPS:  wg-quick up wg0 (or systemctl restart)."
    echo "   2) Here, bring up the tunnel:        sudo wg-quick up ${WG_IFACE}"
    echo "      Check:                            ping 10.8.0.1   and   curl ifconfig.me  (should show the VPS IP)."
    echo "   3) Auto-start + retries: WG_AUTOSTART=${WG_AUTOSTART}."
    if [ "$WG_AUTOSTART" = "yes" ]; then
        echo "      ALREADY enabled: wg-quick@${WG_IFACE} (boot) + wg-watchdog.timer (revives a dead tunnel every 30s)."
        echo "      The tunnel will come up on its own after a reboot — but only if the peer has already been added on the VPS (step 1)!"
        echo "      IF INTERNET DROPS (peer not configured yet):"
        echo "        sudo systemctl disable --now wg-quick@${WG_IFACE} wg-watchdog.timer && sudo wg-quick down ${WG_IFACE}"
    else
        echo "      Units installed but disabled. To enable:  sudo systemctl enable --now wg-quick@${WG_IFACE} wg-watchdog.timer"
    fi
    echo "   4) Audio tunnel — per your .md (module-native-protocol-tcp on ${wg_peer_ip}:4713),"
    echo "      AFTER bringing up WG. Note: the device is 44100Hz, the .md uses rate=48000 (PipeWire resamples)."
    echo "   5) Launch NoMachine (desktop shortcut) and add a connection to the VPS: host 10.8.0.1, protocol NX."
    echo "   6) Log in to XFCE and apply the look:   bash ~/xfce-win10.sh   (NOT as root)."
    echo
    echo "   Watchdog diagnostics:  journalctl -t wg-watchdog -n 30   |   systemctl list-timers wg-watchdog.timer"
    echo "   Rollout log:           $LOG  (root:${ADMIN_GROUP}, 640)"
    echo
    warn "Security: the NoMachine server listens on port 4000 — don't forward it to the internet from your router."
    echo "   Only reach this machine over the LAN or via wg0 (${wg_peer_ip})."
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
    wireguard
    watchdog
    nomachine
    win10_script
    nm_shortcut
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
