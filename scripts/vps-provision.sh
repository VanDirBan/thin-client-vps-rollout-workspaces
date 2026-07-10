#!/usr/bin/env bash
#==============================================================================
# vps-provision.sh — initial rollout of the working VPS (Debian 13 / Ubuntu)
#   XFCE + NoMachine + Firefox + Multilogin X + Telegram + WireGuard
#   Users: adams (admin), smm (worker)
#
# Usage:   sudo bash vps-provision.sh      (better as root or adams, NOT as smm —
#           smm deliberately loses sudo at the end; adams stays the admin)
# The script is idempotent: re-running it doesn't break what's already been done.
#
# Non-critical packages are installed best-effort (apt_try): a missing package
# on a particular distro doesn't take down the whole rollout.
#==============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# CONFIG — defaults can be overridden through environment variables. Do not commit
# real passwords; pass ADMIN_PASS/WORK_PASS from a local env file or shell.
#------------------------------------------------------------------------------
ADMIN_USER="${ADMIN_USER:-adams}"
ADMIN_PASS="${ADMIN_PASS:-CHANGE_ME_ADMIN_PASS}"
WORK_USER="${WORK_USER:-smm}"
WORK_PASS="${WORK_PASS:-CHANGE_ME_WORK_PASS}"

# Timezone. Empty ("") = do NOT touch it, leave the VPS default (usually UTC).
TIMEZONE="${TIMEZONE:-Europe/Berlin}"

# Locales to generate (UTF-8 is needed for correct Cyrillic and sorting).
# The first one in the list becomes the system locale (LANG).
LOCALES=("en_US.UTF-8" "ru_RU.UTF-8")

# NoMachine: pinned version. Check the current DEB amd64 build at
#   https://downloads.nomachine.com/download/?id=1   (or the /download/linux page).
# URL format: download/<BRANCH=major.minor>/Linux/nomachine_<VERSION>_<BUILD>_amd64.deb
# IMPORTANT: for a nonexistent version the server returns an HTML page with code 200 (not 404!),
# so below there's a check "is this actually a .deb?" (fetch_deb) — without it apt would fail
# with a cryptic "Invalid archive signature".
NOMACHINE_BRANCH="${NOMACHINE_BRANCH:-9.7}"
NOMACHINE_VERSION="${NOMACHINE_VERSION:-9.7.3}"
NOMACHINE_BUILD="${NOMACHINE_BUILD:-1}"
NOMACHINE_URL="https://download.nomachine.com/download/${NOMACHINE_BRANCH}/Linux/nomachine_${NOMACHINE_VERSION}_${NOMACHINE_BUILD}_amd64.deb"

export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/vps-provision.log"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
log()  { echo -e "\n\033[1;32m==>\033[0m $*"  | tee -a "$LOG"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"    | tee -a "$LOG"; }
die()  { echo -e "\033[1;31m[FAIL]\033[0m $*" | tee -a "$LOG" >&2; exit 1; }

# best-effort install: failure = warning, not a full rollout stop
apt_try() { apt-get install -y "$@" || warn "Failed to install: $*  (skipping)"; }

# Download the .deb and make sure it's ACTUALLY a package, not an HTML page.
# Some servers (download.nomachine.com) return HTML with code 200 for a
# nonexistent version — curl -f doesn't catch that, and apt later fails with
# "Invalid archive signature". Return codes: 0 — ok, 1 — download failed, 2 — downloaded, but not a .deb.
fetch_deb() {
    local url="$1" dest="$2"
    curl -L -f -o "$dest" "$url" || return 1
    dpkg-deb --info "$dest" >/dev/null 2>&1 || return 2
    return 0
}

[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo bash $0"
touch "$LOG" 2>/dev/null || true

trap 'die "Error (code $?) at line $LINENO. Check $LOG"' ERR

# 0. Make repeated runs safe
# Preflight: kill a stuck NoMachine install left over from a previous run.
# Symptom: nxserver.bin --subscription spins at 100% CPU and holds open
# postinst → dpkg → apt-get, which then won't release /var/lib/dpkg/lock-frontend.
# We ONLY kill the nx chain (we don't touch someone else's apt/unattended-upgrades —
# for that, DPkg::Lock::Timeout=600 handles it). Once the leaf process dies, apt-get
# unwinds on its own.
preflight_nx_cleanup() {
    if pgrep -f 'nxserver\.bin --subscription' >/dev/null 2>&1 \
       || pgrep -f 'nxserver.*--install' >/dev/null 2>&1; then
        warn "Stuck NoMachine install from a previous run — clearing it"
        pkill -9 -f 'nxserver\.bin --subscription' 2>/dev/null || true
        pkill -9 -f 'nxserver.*--install'          2>/dev/null || true
        sleep 3            # let apt/dpkg release the lock
    fi
}
preflight_nx_cleanup

#==============================================================================
# 1. System update + base packages + locales
#    The VPS has no physical drivers (it's a virtual machine). Here "drivers" means
#    a full package upgrade + the hypervisor's guest agent (KVM/QEMU).
#==============================================================================
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
log "Distro: ${PRETTY_NAME:-unknown}"

log "Updating packages and the system"
export NEEDRESTART_MODE=a

# finish off any half-configured state left from a previous run
dpkg --configure -a || true

# pre-answer grub-pc, otherwise full-upgrade trips on debconf
if dpkg -s grub-pc >/dev/null 2>&1; then
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    disk=""
    if [ -n "$root_src" ]; then
        pk="$(lsblk -no pkname "$root_src" 2>/dev/null || true)"
        pk="${pk%%$'\n'*}"
        [ -n "$pk" ] && disk="/dev/$pk"
    fi
    if [ -n "$disk" ] && [ -b "$disk" ]; then
        echo "grub-pc grub-pc/install_devices multiselect $disk" | debconf-set-selections
    else
        warn "grub-pc is installed, but the disk couldn't be determined — skipping preseed"
    fi
fi

apt-get update
apt-get -y \
  -o DPkg::Lock::Timeout=600 \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  full-upgrade

log "Base utilities"
# We do NOT install software-properties-common and apt-transport-https:
#   • we don't use add-apt-repository (the Mozilla repo is added manually);
#   • HTTPS transport is built into apt (Debian 10+/Ubuntu 18.04+).
# On Debian 13 the first package simply doesn't exist — that's what was causing the failure.
apt-get install -y curl wget gnupg ca-certificates unzip locales sudo libglib2.0-bin binutils
apt_try qemu-guest-agent   # only useful on KVM/QEMU; not critical on other hypervisors

log "Locales (UTF-8 for correct Cyrillic)"
for loc in "${LOCALES[@]}"; do
    if grep -qE "^#?[[:space:]]*${loc}[[:space:]]" /etc/locale.gen; then
        sed -i -E "s/^#?[[:space:]]*(${loc}[[:space:]])/\1/" /etc/locale.gen
    else
        echo "${loc} ${loc##*.}" >> /etc/locale.gen
    fi
done
/usr/sbin/locale-gen
/usr/sbin/update-locale LANG="${LOCALES[0]}"

log "Time and synchronization (important for NoMachine TLS)"
if [ -n "$TIMEZONE" ]; then
    timedatectl set-timezone "$TIMEZONE" || warn "Failed to set the timezone"
else
    log "  TIMEZONE is empty — not changing the timezone"
fi
timedatectl set-ntp true || true

#==============================================================================
# 2. XFCE + session environment + audio + fonts + themes
#    The desktop core is installed unconditionally; goodies/audio/fonts/themes are
#    best-effort, so a missing package on a given distro doesn't break the rollout.
#    pipewire — so NoMachine has something to capture for audio forwarding.
#    arc-theme + papirus — so xfce-win10.sh can actually apply a look later.
#==============================================================================
log "XFCE (desktop core)"
apt-get install -y xfce4 xfconf dbus-x11 dbus-user-session x11-xserver-utils

log "Required for the Windows-10 look"
apt-get install -y xfce4-whiskermenu-plugin      # the "Start" button
apt-get install -y gtk2-engines-murrine          # renders the GTK2 part of the B00merang theme
apt-get install -y gvfs gvfs-daemons             # Trash/removable media on the desktop
apt-get install -y fonts-noto fonts-noto-color-emoji fonts-liberation

log "Required packages for the Windows-10 look"
apt-get install -y xfce4-whiskermenu-plugin gtk2-engines-murrine \
                   gvfs gvfs-daemons xfconf curl unzip
apt_try arc-theme papirus-icon-theme          # fallback in case the theme doesn't download

log "Windows-10 theme (B00merang) into system directories"
_install_win10_look() {
  local tmp; tmp="$(mktemp -d)"; local ok=1
  # GTK + xfwm4 theme → /usr/share/themes/Windows-10 (WITHOUT -master, exactly)
  if [ ! -d /usr/share/themes/Windows-10 ]; then
    if curl -fsSL -o "$tmp/theme.zip" \
         https://codeload.github.com/B00merang-Project/Windows-10/zip/refs/heads/master \
       && unzip -q "$tmp/theme.zip" -d "$tmp/t"; then
      rm -rf /usr/share/themes/Windows-10
      mv "$tmp/t/Windows-10-master" /usr/share/themes/Windows-10
    else ok=0; fi
  fi
  # Icons → /usr/share/icons/Windows-10
  if [ ! -d /usr/share/icons/Windows-10 ]; then
    if curl -fsSL -o "$tmp/icons.zip" \
         https://codeload.github.com/B00merang-Artwork/Windows-10/zip/refs/heads/master \
       && unzip -q "$tmp/icons.zip" -d "$tmp/i"; then
      rm -rf /usr/share/icons/Windows-10
      mv "$tmp/i/Windows-10-master" /usr/share/icons/Windows-10
      gtk-update-icon-cache -f /usr/share/icons/Windows-10 2>/dev/null || true
    else ok=0; fi
  fi
  rm -rf "$tmp"
  [ "$ok" -eq 1 ] || log "[!] Failed to download the Windows-10 theme — clients will fall back to Arc/Papirus"
}
_install_win10_look

log "Fallback themes"
apt_try arc-theme papirus-icon-theme

log "Desktop extras (best-effort)"
apt_try xfce4-goodies
apt_try pipewire pipewire-pulse wireplumber
apt_try xfce4-screensaver                        # only if Win+L actually needs to lock the screen

#==============================================================================
# 3. Users: adams (sudo) and smm (no privileges)
#    create_user <name> <password> <in_sudo: yes|no>
#    Order matters: adams gets sudo BEFORE smm loses it —
#    this rules out ending up with no administrator at all.
#==============================================================================
create_user() {
    local u="$1" p="$2" admin="$3"
    if id -u "$u" >/dev/null 2>&1; then
        log "User $u already exists — updating the password"
    else
        log "Creating user $u"
        useradd -m -s /bin/bash "$u"
    fi
    echo "${u}:${p}" | chpasswd
    usermod -s /bin/bash "$u" 2>/dev/null || true
    [ -d "/home/$u" ] && { chown -R "$u:$u" "/home/$u"; chmod 750 "/home/$u"; }
    # groups for GUI/audio
    usermod -aG audio,video "$u" 2>/dev/null || warn "  audio/video groups not applied for $u"
    if [ "$admin" = "yes" ]; then
        usermod -aG sudo "$u"
    else
        # guarantee removal from sudo in case it somehow got granted
        gpasswd -d "$u" sudo 2>/dev/null || true
    fi
}

create_user "$ADMIN_USER" "$ADMIN_PASS" yes
create_user "$WORK_USER"  "$WORK_PASS"  no

#==============================================================================
# 4. Software
#==============================================================================

#--- 4.1 Firefox from the Mozilla repository -----------------------------------------
# We want the "real" Firefox, not snap (Ubuntu) and not firefox-esr (Debian):
# under NoMachine/a virtual display, snap is finicky, and esr lags behind on versions.
# The Mozilla repo is distro-agnostic and works on both Debian and Ubuntu.
# If it fails to install for whatever reason — fall back to Debian's firefox-esr.
log "Firefox (Mozilla repository)"
if command -v snap >/dev/null 2>&1; then
    snap remove firefox 2>/dev/null || true
fi
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
    -o /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
    > /etc/apt/sources.list.d/mozilla.list
cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
apt-get update -y
if apt-get install -y firefox firefox-l10n-ru; then
    :
elif apt-get install -y firefox; then
    :
else
    warn "Firefox from the Mozilla repo failed to install — installing firefox-esr from Debian"
    apt-get install -y firefox-esr firefox-esr-l10n-ru \
        || apt-get install -y firefox-esr \
        || warn "firefox-esr also failed to install — install a browser manually"
fi

#--- 4.2 Telegram Desktop -------------------------------------------------------
log "Telegram Desktop"
if apt-get install -y telegram-desktop; then
    log "  telegram-desktop from the distro repository"
else
    warn "telegram-desktop not in the repos — installing via Flatpak (Flathub)"
    if apt-get install -y flatpak; then
        flatpak remote-add --if-not-exists flathub \
            https://flathub.org/repo/flathub.flatpakrepo || true
        if flatpak install -y --noninteractive flathub org.telegram.desktop; then
            log "  Telegram installed as Flatpak (org.telegram.desktop)"
        else
            warn "  Flatpak install of Telegram failed — install it manually"
        fi
    else
        warn "  flatpak failed to install — Telegram skipped"
    fi
fi

#--- 4.3 WireGuard (package + server key; the tunnel is configured separately) ----------
log "WireGuard (installation + server key generation)"
apt-get install -y wireguard-tools   # provides wg/wg-quick — required
apt_try wireguard                    # meta-package/module — on modern kernels WG is already built in
mkdir -p /etc/wireguard
chmod 770 /etc/wireguard
#if [ ! -f /etc/wireguard/server_private.key ]; then
    # umask scoped locally in the subshell so it doesn't leak into the rest of the script
#    ( umask 077
#      wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key )
#    log "WireGuard server key generated"
#else
#    log "WireGuard server key already exists — skipping"
#fi
# wg0.conf is NOT created and NOT brought up: it needs the client's (HP) public key.
# We'll do that during network configuration.

#--- 4.4 NoMachine --------------------------------------------------------------
log "NoMachine ${NOMACHINE_VERSION}"

# Clean up any stuck installer/subscription processes left from a previous run, if present:
# nxserver.bin --subscription can loop at 100% CPU and hang --restart.
pkill -9 -f 'nxserver.*--install'           2>/dev/null || true
pkill -9 -f 'nxserver\.bin --subscription'  2>/dev/null || true

if ! dpkg -s nomachine >/dev/null 2>&1; then
    TMP_DEB="$(mktemp --suffix=.deb)"
    if ! fetch_deb "$NOMACHINE_URL" "$TMP_DEB"; then
        rm -f "$TMP_DEB"
        die "NoMachine: failed to get a valid .deb.
  URL:    $NOMACHINE_URL
  Reason: version ${NOMACHINE_VERSION} may be outdated (an HTML page is sitting at that path).
          Get the current one from https://downloads.nomachine.com/download/?id=1"
    fi
    apt-get install -y "$TMP_DEB"
    rm -f "$TMP_DEB"
else
    log "NoMachine already installed — skipping"
fi

# We set the XFCE session BEFORE the single restart (otherwise a gray screen).
NODE_CFG="/usr/NX/etc/node.cfg"
if [ -f "$NODE_CFG" ]; then
    if grep -q '^DefaultDesktopCommand' "$NODE_CFG"; then
        sed -i 's|^DefaultDesktopCommand.*|DefaultDesktopCommand "/usr/bin/startxfce4"|' "$NODE_CFG"
    else
        echo 'DefaultDesktopCommand "/usr/bin/startxfce4"' >> "$NODE_CFG"
    fi
fi

# The ONLY restart — with a timeout, so a stuck process doesn't hang the rollout.
timeout 60 /usr/NX/bin/nxserver --restart >/dev/null 2>&1 \
    || warn "nxserver --restart didn't finish within 60s — check manually: ps -ef | grep nx"



#--- 4.5 Multilogin X Desktop --------------------------------------------------
log "Multilogin X Desktop"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MULTILOGIN_LOCAL_DEB="${SCRIPT_DIR}/desktop-multiloginx-ubuntu-24.04-amd64.deb"

mlx_desktop_installed() {
    dpkg -s mlxapp >/dev/null 2>&1 && return 0
    command -v mlxapp >/dev/null 2>&1 && return 0
    return 1
}

if ! mlx_desktop_installed; then
    if [ ! -f "$MULTILOGIN_LOCAL_DEB" ]; then
        die "Multilogin Desktop .deb not found:
  $MULTILOGIN_LOCAL_DEB

Put desktop-multiloginx-ubuntu-24.04-amd64.deb next to the script."
    fi

    dpkg-deb --info "$MULTILOGIN_LOCAL_DEB" >/dev/null 2>&1 || \
        die "File found, but it's not a valid .deb: $MULTILOGIN_LOCAL_DEB"

    mkdir -p /root/.config

    TMP_MLX="$(mktemp --suffix=.deb)"
    cp -f "$MULTILOGIN_LOCAL_DEB" "$TMP_MLX"
    chmod 0644 "$TMP_MLX"

    apt-get install -y "$TMP_MLX"
    rm -f "$TMP_MLX"
else
    log "Multilogin X Desktop already installed — skipping"
fi

#==============================================================================
# 4.5 Display stack: Xorg + LightDM + XFCE session on :0
#     NoMachine free shares the PHYSICAL screen (a virtual desktop for the client is
#     the paid Workstation edition). So Xorg with XFCE actually needs to be running on
#     :0, otherwise "Failed to start session". A bare DE isn't enough — the DM launches it.
#==============================================================================
log "Display manager (LightDM) + Xorg"
apt-get install -y xorg xinit lightdm lightdm-gtk-greeter \
                   xfce4-session xfce4-terminal

# LightDM defaults to the XFCE session (not GNOME/Wayland)
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-xfce.conf <<'EOF'
[Seat:*]
user-session=xfce
greeter-session=lightdm-gtk-greeter
# autologin for the work user (no password prompt in the greeter on reconnect):
#autologin-user=smm
#autologin-session=xfce
EOF

# .xsession with a MANDATORY dbus bus — otherwise xfce4-session/xfconf/polkit crash
for u in "$WORK_USER" "$ADMIN_USER"; do
    printf '#!/bin/sh\nexec dbus-run-session -- startxfce4\n' > "/home/${u}/.xsession"
    chmod +x "/home/${u}/.xsession"
    chown "${u}:${u}" "/home/${u}/.xsession"
done

chmod 1777 /tmp /var/tmp

# Resolution: headless without a monitor, Xorg falls back to a tiny default (no EDID).
# Forcing 1920x1080 via the dummy driver.
apt-get install -y xserver-xorg-video-dummy
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-dummy.conf <<'EOF'
Section "Device"
    Identifier  "dummy"
    Driver      "dummy"
    VideoRam    256000
EndSection
Section "Monitor"
    Identifier  "dummy-monitor"
    HorizSync   5.0 - 1000.0
    VertRefresh 5.0 - 200.0
    Modeline "1920x1080_60.00" 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync
EndSection
Section "Screen"
    Identifier  "dummy-screen"
    Device      "dummy"
    Monitor     "dummy-monitor"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "1920x1080_60.00"
        Virtual 1920 1080
    EndSubSection
EndSection
EOF

log "Keyboard layouts (us + ru, switch with Alt+Shift)"
apt_try xfce4-xkb-plugin        # layout indicator in the panel (not required for it to work)

install -d -o "$WORK_USER" -g "$WORK_USER" "/home/${WORK_USER}/.config/autostart"
cat > "/home/${WORK_USER}/.config/autostart/keyboard-layout.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Keyboard layout us,ru
Exec=sh -c 'sleep 3; setxkbmap -layout us,ru -option grp:alt_shift_toggle'
X-GNOME-Autostart-enabled=true
EOF
chown "${WORK_USER}:${WORK_USER}" "/home/${WORK_USER}/.config/autostart/keyboard-layout.desktop"

systemctl enable lightdm >/dev/null 2>&1 || true
systemctl restart lightdm || warn "LightDM failed to restart — systemctl status lightdm"
timeout 60 /usr/NX/bin/nxserver --restart >/dev/null 2>&1 || warn "nxserver --restart didn't finish within 60s"

#==============================================================================
# 5. Desktop shortcuts for user smm
#    Placing .desktop files for the apps smm actually launches:
#    Firefox, Multilogin X, Telegram.
#    (NoMachine on the VPS is the server, it doesn't need a shortcut; WireGuard is a service.)
#    We copy the system .desktop into ~/Desktop and make smm the owner — that way
#    XFCE lets us mark the shortcut trusted without complaining.
#
#    NOTE: find is stopped at the first match via -print -quit, NOT
#    via `| head -n1`. With pipefail+an ERR trap, head would close the pipe, find
#    would catch SIGPIPE (code 141), and the script would fail with a false error right at the end.
#==============================================================================
log "Desktop shortcuts ($WORK_USER)"
DESKTOP_DIR="/home/${WORK_USER}/Desktop"
mkdir -p "$DESKTOP_DIR"

link_desktop() {
    local pattern="$1" src dst
    src="$(find /usr/share/applications /var/lib/flatpak/exports/share/applications \
              -maxdepth 1 -iname "*${pattern}*.desktop" -print -quit 2>/dev/null || true)"
    if [ -n "$src" ]; then
        dst="${DESKTOP_DIR}/$(basename "$src")"
        cp -f "$src" "$dst"
        chmod 0755 "$dst"
        chown "${WORK_USER}:${WORK_USER}" "$dst"

        # Mark the .desktop as trusted for this specific XFCE/Thunar user
        sudo -H -u "$WORK_USER" dbus-run-session \
            gio set "$dst" metadata::trusted true 2>/dev/null || \
    warn "  failed to mark as trusted: $(basename "$dst")"
        log "  shortcut: $(basename "$src")"
    else
        warn "  .desktop for '$pattern' not found — skipping (fix it manually)"
    fi
}

link_desktop "firefox"
link_desktop "telegram"
link_desktop "mlxapp"

chown -R "${WORK_USER}:${WORK_USER}" "$DESKTOP_DIR"

#==============================================================================
# SUMMARY
#==============================================================================
log "DONE. Summary:"
echo "  Distro:        ${PRETTY_NAME:-unknown}"
echo "  Users:         ${ADMIN_USER} (sudo), ${WORK_USER} (no privileges)"
echo "  Desktop:       XFCE (Arc/Papirus theme available for xfce-win10.sh)"
echo "  Locales:       ${LOCALES[*]} (LANG=${LOCALES[0]})"
echo "  Software:      Firefox, Telegram, Multilogin X, NoMachine, WireGuard"
echo
echo "  WireGuard server public key:"
echo "    $(cat /etc/wireguard/server_public.key 2>/dev/null || echo '— not found')"
echo
warn "IMPORTANT — what this script has NOT done (planned as the next step):"
echo "   • Firewall. NoMachine is currently listening on port 4000 on the PUBLIC IP."
echo "     Until it's closed off by a firewall, only reach it via an SSH tunnel or WG."
echo "   • WireGuard tunnel (needs the HP client's public key)."
echo "   • Change the initially configured passwords with passwd."

if [ -f /var/run/reboot-required ]; then
    warn "Kernel/packages were updated — a reboot is recommended."
fi
