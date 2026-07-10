#!/usr/bin/env bash
#==============================================================================
# vps-provision.sh v2.0 — initial rollout of the working VPS (Debian 13 / Ubuntu)
#   XFCE + NoMachine + Firefox + Multilogin X + Telegram + WireGuard (client)
#   Users: adams (admin), smm (worker)
#
# Usage (full run):
#   sudo bash vps-provision.sh
#
# Running selective steps (after a failure / to finish off one section):
#   sudo bash vps-provision.sh nomachine display
#   sudo bash vps-provision.sh --list          # show all steps
#
# Steps always run in canonical order (see STEPS below), regardless of the
# order of the arguments. The preflight step always runs.
#
# The script is idempotent: re-running it doesn't break what's already been done.
# The user password is set ONLY on creation — re-running the script doesn't
# roll back passwords that were changed manually after rollout.
#
# Non-critical packages are installed best-effort (apt_try): a missing package
# on a particular distro doesn't take down the whole rollout.
#
# Passwords are accepted via environment variables or an ignored local env file.
# Do not commit real credentials; the defaults below are placeholders only.
#==============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# CONFIG — defaults can be overridden through environment variables.
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

#--- WireGuard (VPS = CLIENT of an existing WG network) ----------------------------
# The VPS keypair is always generated (wireguard step); the public key
# is printed in the summary — add it as a peer on the WG server.
#
# wg0.conf is created and the tunnel is brought up ONLY when both
# WG_SERVER_PUBKEY and WG_SERVER_ENDPOINT are filled in. While empty, the step
# is limited to generating keys and printing a hint. Once filled in → rerun the step:
#   sudo bash vps-provision.sh wireguard
WG_ADDRESS="${WG_ADDRESS:-10.8.0.2/24}"          # this VPS's address inside the tunnel network
WG_SERVER_PUBKEY="${WG_SERVER_PUBKEY:-}"               # the WG server's public key
WG_SERVER_ENDPOINT="${WG_SERVER_ENDPOINT:-}"             # server's host:port, e.g. "203.0.113.10:51820"
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-10.8.0.0/24}"      # split-tunnel: only the tunnel subnet
WG_KEEPALIVE="${WG_KEEPALIVE:-25}"                 # keeps the NAT mapping alive

#--- NoMachine: pinned version ----------------------------------------------------
# Check the current DEB amd64 build at
#   https://downloads.nomachine.com/download/?id=1   (or the /download/linux page).
# URL format: download/<BRANCH=major.minor>/Linux/nomachine_<VERSION>_<BUILD>_amd64.deb
# IMPORTANT: for a nonexistent version the server returns an HTML page with code 200 (not 404!),
# so there's a check "is this actually a .deb?" (fetch_deb) — without it apt would fail
# with a cryptic "Invalid archive signature".
NOMACHINE_BRANCH="${NOMACHINE_BRANCH:-9.7}"
NOMACHINE_VERSION="${NOMACHINE_VERSION:-9.7.3}"
NOMACHINE_BUILD="${NOMACHINE_BUILD:-1}"
NOMACHINE_URL="https://download.nomachine.com/download/${NOMACHINE_BRANCH}/Linux/nomachine_${NOMACHINE_VERSION}_${NOMACHINE_BUILD}_amd64.deb"

#--- Windows-10 theme (B00merang): pinned to a commit SHA ---------------------------
# Same commits as in local-provision.sh on the laptops — the look matches bit-for-bit.
# When the SHA changes, the theme reinstalls itself automatically (via the .provision-commit marker).
WIN10_THEME_COMMIT="${WIN10_THEME_COMMIT:-3a4116603b66a9adcb78f3987d7ea6f01de1cbce}"   # B00merang-Project/Windows-10 (2025-08-22)
WIN10_ICONS_COMMIT="${WIN10_ICONS_COMMIT:-9f199c6b7c6050f36d0d15aaa6e9f4847e8b9066}"   # B00merang-Artwork/Windows-10

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
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

# Clear a stuck NoMachine install.
# Symptom: nxserver.bin --subscription spins at 100% CPU and holds open
# postinst → dpkg → apt-get, which then won't release /var/lib/dpkg/lock-frontend.
# We ONLY kill the nx chain (we don't touch someone else's apt/unattended-upgrades —
# for that, DPkg::Lock::Timeout=600 handles it). Once the leaf process dies, apt-get
# unwinds on its own.
nx_cleanup() {
    if pgrep -f 'nxserver\.bin --subscription' >/dev/null 2>&1 \
       || pgrep -f 'nxserver.*--install' >/dev/null 2>&1; then
        warn "Stuck NoMachine processes — clearing them"
        pkill -9 -f 'nxserver\.bin --subscription' 2>/dev/null || true
        pkill -9 -f 'nxserver.*--install'          2>/dev/null || true
        sleep 3            # let apt/dpkg release the lock
    fi
}

#==============================================================================
# STEP: preflight — make repeated runs safe (always executed)
#==============================================================================
step_preflight() {
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || true
    log "Distro: ${PRETTY_NAME:-unknown}"

    nx_cleanup

    # finish off any half-configured state left from a previous run
    dpkg --configure -a || true
}

#==============================================================================
# STEP: base — system update + base utilities + locales + time
#     The VPS has no physical drivers (it's a virtual machine). Here "drivers" means
#     a full package upgrade + the hypervisor's guest agent (KVM/QEMU).
#==============================================================================
step_base() {
    log "Updating packages and the system"

    # pre-answer grub-pc, otherwise full-upgrade trips on debconf
    if dpkg -s grub-pc >/dev/null 2>&1; then
        local root_src disk pk
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
    apt-get install -y curl wget gnupg ca-certificates unzip locales sudo \
                       libglib2.0-bin binutils
    apt_try qemu-guest-agent   # only useful on KVM/QEMU; not critical on other hypervisors

    log "Locales (UTF-8 for correct Cyrillic)"
    local loc
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
}

#==============================================================================
# STEP: desktop — XFCE + Windows-10 look + audio + fonts
#     The desktop core is installed unconditionally; goodies/audio are best-effort,
#     so a missing package on a given distro doesn't break the rollout.
#     pipewire — so NoMachine has something to capture for audio forwarding.
#     arc-theme + papirus — a fallback in case the B00merang theme doesn't download.
#==============================================================================

# Download and unpack the pinned B00merang commit into the system directory.
# The .provision-commit marker stores the SHA of the installed version: changing
# the pin in the config → the theme reinstalls, same pin → the step is skipped (idempotent).
#   $1 — repo (Project|Artwork), $2 — commit SHA, $3 — target directory
_fetch_b00merang() {
    local repo="$1" commit="$2" target="$3"
    local marker="${target}/.provision-commit"

    if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null || true)" = "$commit" ]; then
        log "  ${target##*/} (${target%/*}) already at commit ${commit:0:7} — skipping"
        return 0
    fi

    local tmp
    tmp="$(mktemp -d)"
    if curl -fsSL -o "$tmp/src.zip" \
           "https://codeload.github.com/B00merang-${repo}/Windows-10/zip/${commit}" \
       && unzip -q "$tmp/src.zip" -d "$tmp/x"; then
        rm -rf "$target"
        mv "$tmp/x/Windows-10-${commit}" "$target"
        echo "$commit" > "$marker"
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

step_desktop() {
    log "XFCE (desktop core)"
    apt-get install -y xfce4 xfconf dbus-x11 dbus-user-session x11-xserver-utils

    log "Required packages for the Windows-10 look"
    apt-get install -y \
        xfce4-whiskermenu-plugin \
        gtk2-engines-murrine \
        gvfs gvfs-daemons \
        fonts-noto fonts-noto-color-emoji fonts-liberation
    # xfce4-whiskermenu-plugin — the "Start" button
    # gtk2-engines-murrine    — renders the GTK2 part of the B00merang theme
    # gvfs                    — Trash/removable media on the desktop

    log "Windows-10 theme (B00merang, pinned ${WIN10_THEME_COMMIT:0:7}/${WIN10_ICONS_COMMIT:0:7})"
    local theme_ok=1
    _fetch_b00merang "Project" "$WIN10_THEME_COMMIT" /usr/share/themes/Windows-10 \
        || theme_ok=0
    if _fetch_b00merang "Artwork" "$WIN10_ICONS_COMMIT" /usr/share/icons/Windows-10; then
        gtk-update-icon-cache -f /usr/share/icons/Windows-10 2>/dev/null || true
    else
        theme_ok=0
    fi
    [ "$theme_ok" -eq 1 ] \
        || warn "Failed to download the Windows-10 theme — clients will fall back to Arc/Papirus"

    log "Fallback themes (if B00merang is unavailable)"
    apt_try arc-theme papirus-icon-theme

    log "Desktop extras (best-effort)"
    apt_try xfce4-goodies
    apt_try pipewire pipewire-pulse wireplumber
    apt_try xfce4-screensaver        # only if Win+L actually needs to lock the screen
}

#==============================================================================
# STEP: users — adams (sudo) and smm (no privileges)
#     Order matters: adams gets sudo BEFORE smm loses it —
#     this rules out ending up with no administrator at all.
#
#     The password is set ONLY when the user is created. Re-running the script
#     does NOT touch the password — otherwise it would roll back to the (potentially
#     already compromised/changed) password from this file.
#==============================================================================
create_user() {
    local u="$1" p="$2" admin="$3"
    if id -u "$u" >/dev/null 2>&1; then
        log "User $u already exists — not touching the password"
    else
        log "Creating user $u"
        useradd -m -s /bin/bash "$u"
        echo "${u}:${p}" | chpasswd
    fi
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

step_users() {
    create_user "$ADMIN_USER" "$ADMIN_PASS" yes
    create_user "$WORK_USER"  "$WORK_PASS"  no
}

#==============================================================================
# STEP: firefox — from the Mozilla repository
#     We want the "real" Firefox, not snap (Ubuntu) and not firefox-esr (Debian):
#     under NoMachine/a virtual display, snap is finicky, and esr lags behind on
#     versions. The Mozilla repo is distro-agnostic and works on both Debian and Ubuntu.
#     If it fails to install — fall back to Debian's firefox-esr.
#==============================================================================
step_firefox() {
    log "Firefox (Mozilla repository)"
    if command -v snap >/dev/null 2>&1; then
        snap remove firefox 2>/dev/null || true
    fi
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/packages.mozilla.org.asc
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list
    # Pin only firefox*, not the whole origin: if Mozilla puts something else
    # in the repo, it won't override distro packages.
    cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: firefox*
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
    apt-get update
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
}

#==============================================================================
# STEP: telegram — from the distro repo, fallback to Flatpak
#     (on Ubuntu 24.04, telegram-desktop is not in the repos)
#==============================================================================
step_telegram() {
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
}

#==============================================================================
# STEP: wireguard — the VPS as a CLIENT of an existing WG network
#     Always: packages + the VPS's own keypair (the public key is printed
#     in the summary; add it as a peer on the server).
#     If WG_SERVER_PUBKEY and WG_SERVER_ENDPOINT are filled in — write wg0.conf
#     and bring up the tunnel. Otherwise — just the keys and a hint.
#==============================================================================
step_wireguard() {
    log "WireGuard (client)"
    apt-get install -y wireguard-tools   # provides wg/wg-quick — required
    apt_try wireguard                    # meta-package/module — on modern kernels WG is already built in

    # Directory: root:sudo 770 — readable by admins in the sudo group.
    install -d -m 0770 -o root -g sudo /etc/wireguard

    if [ ! -f /etc/wireguard/vps_private.key ]; then
        # umask scoped locally in the subshell so it doesn't leak into the rest of the script
        ( umask 077
          wg genkey | tee /etc/wireguard/vps_private.key \
                    | wg pubkey > /etc/wireguard/vps_public.key )
        log "  VPS keypair generated"
    else
        log "  VPS keypair already exists — skipping"
    fi

    if [ -z "$WG_SERVER_PUBKEY" ] || [ -z "$WG_SERVER_ENDPOINT" ]; then
        warn "WG_SERVER_PUBKEY/WG_SERVER_ENDPOINT are not filled in — not creating wg0.conf.
    1. Add a peer on the WG server with the key: $(cat /etc/wireguard/vps_public.key)
    2. Fill in WG_SERVER_PUBKEY and WG_SERVER_ENDPOINT in the script config.
    3. Rerun the step:  sudo bash $0 wireguard"
        return 0
    fi

    # wg0.conf is derived from the script's config, so we overwrite it on every
    # run: edit the parameters above + rerun the step = an updated tunnel. Manual
    # edits to wg0.conf won't survive a run — edit the config here instead.
    log "  Writing /etc/wireguard/wg0.conf and bringing up the tunnel"
    ( umask 077
      cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address    = ${WG_ADDRESS}
PrivateKey = $(cat /etc/wireguard/vps_private.key)

[Peer]
PublicKey           = ${WG_SERVER_PUBKEY}
Endpoint            = ${WG_SERVER_ENDPOINT}
AllowedIPs          = ${WG_ALLOWED_IPS}
PersistentKeepalive = ${WG_KEEPALIVE}
EOF
    )
    systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
    if systemctl restart wg-quick@wg0; then
        log "  Tunnel wg0 is up (${WG_ADDRESS} → ${WG_SERVER_ENDPOINT})"
    else
        warn "wg-quick@wg0 failed to come up — check: journalctl -u wg-quick@wg0"
    fi
}

#==============================================================================
# STEP: nomachine — installation + node.cfg (NO restart)
#     We set the XFCE session in node.cfg BEFORE the restart (otherwise a gray screen).
#     The single nxserver restart is performed by the display step — by that
#     point Xorg/LightDM are already in place and NoMachine has something to attach to.
#     If you're running ONLY this step — finish it off with the display step:
#         sudo bash vps-provision.sh nomachine display
#==============================================================================
step_nomachine() {
    log "NoMachine ${NOMACHINE_VERSION}"
    nx_cleanup

    if ! dpkg -s nomachine >/dev/null 2>&1; then
        local tmp_deb rc
        tmp_deb="$(mktemp --suffix=.deb)"
        rc=0
        fetch_deb "$NOMACHINE_URL" "$tmp_deb" || rc=$?
        if [ "$rc" -ne 0 ]; then
            rm -f "$tmp_deb"
            local reason="download failed (network/URL)"
            [ "$rc" -eq 2 ] && reason="downloaded, but it's not a .deb (an HTML page is sitting at that path — the version is outdated)"
            die "NoMachine: failed to get a valid .deb.
  URL:     $NOMACHINE_URL
  Reason:  $reason
           Get the current version from https://downloads.nomachine.com/download/?id=1"
        fi
        apt-get install -y "$tmp_deb"
        rm -f "$tmp_deb"
    else
        log "NoMachine already installed — skipping"
    fi

    local node_cfg="/usr/NX/etc/node.cfg"
    if [ -f "$node_cfg" ]; then
        if grep -q '^DefaultDesktopCommand' "$node_cfg"; then
            sed -i 's|^DefaultDesktopCommand.*|DefaultDesktopCommand "/usr/bin/startxfce4"|' "$node_cfg"
        else
            echo 'DefaultDesktopCommand "/usr/bin/startxfce4"' >> "$node_cfg"
        fi
    fi
}

#==============================================================================
# STEP: mlx — Multilogin X Desktop (a local .deb next to the script)
#==============================================================================
step_mlx() {
    log "Multilogin X Desktop"

    local script_dir mlx_deb
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    mlx_deb="${script_dir}/desktop-multiloginx-ubuntu-24.04-amd64.deb"

    if dpkg -s mlxapp >/dev/null 2>&1 || command -v mlxapp >/dev/null 2>&1; then
        log "Multilogin X Desktop already installed — skipping"
        return 0
    fi

    if [ ! -f "$mlx_deb" ]; then
        die "Multilogin Desktop .deb not found:
  $mlx_deb

Put desktop-multiloginx-ubuntu-24.04-amd64.deb next to the script."
    fi

    dpkg-deb --info "$mlx_deb" >/dev/null 2>&1 || \
        die "File found, but it's not a valid .deb: $mlx_deb"

    # mlxapp's postinst writes to the invoking user's (root's) ~/.config and
    # fails if the directory doesn't exist — create it ahead of time
    mkdir -p /root/.config

    # apt can't install from directories with "foreign" permissions — go via a tmp copy
    local tmp_mlx
    tmp_mlx="$(mktemp --suffix=.deb)"
    cp -f "$mlx_deb" "$tmp_mlx"
    chmod 0644 "$tmp_mlx"
    apt-get install -y "$tmp_mlx"
    rm -f "$tmp_mlx"
}

#==============================================================================
# STEP: display — Xorg + LightDM + XFCE session on :0 + nxserver restart
#     NoMachine free shares the PHYSICAL screen (a virtual desktop for the client is
#     the paid Workstation edition). So Xorg with XFCE actually needs to be running on
#     :0, otherwise "Failed to start session". A bare DE isn't enough — the DM launches it.
#==============================================================================
step_display() {
    log "Display manager (LightDM) + Xorg"
    apt-get install -y xorg xinit lightdm lightdm-gtk-greeter \
                       xfce4-session xfce4-terminal

    # LightDM defaults to the XFCE session (not GNOME/Wayland)
    mkdir -p /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/50-xfce.conf <<EOF
[Seat:*]
user-session=xfce
greeter-session=lightdm-gtk-greeter
# autologin for the work user (no password prompt in the greeter on reconnect):
#autologin-user=${WORK_USER}
#autologin-session=xfce
EOF

    # .xsession with a MANDATORY dbus bus — otherwise xfce4-session/xfconf/polkit crash
    local u
    for u in "$WORK_USER" "$ADMIN_USER"; do
        printf '#!/bin/sh\nexec dbus-run-session -- startxfce4\n' > "/home/${u}/.xsession"
        chmod +x "/home/${u}/.xsession"
        chown "${u}:${u}" "/home/${u}/.xsession"
    done

    # A safeguard against old images/runs with a global umask 077 leak:
    # X11 and a lot of other things silently break if /tmp isn't 1777.
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
    apt_try xfce4-xkb-plugin    # layout indicator in the panel (not required for it to work)

    install -d -o "$WORK_USER" -g "$WORK_USER" "/home/${WORK_USER}/.config/autostart"
    cat > "/home/${WORK_USER}/.config/autostart/keyboard-layout.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Keyboard layout us,ru
Exec=sh -c 'sleep 3; setxkbmap -layout us,ru -option grp:alt_shift_toggle'
X-GNOME-Autostart-enabled=true
EOF
    chown "${WORK_USER}:${WORK_USER}" \
        "/home/${WORK_USER}/.config/autostart/keyboard-layout.desktop"

    systemctl enable lightdm >/dev/null 2>&1 || true
    systemctl restart lightdm || warn "LightDM failed to restart — systemctl status lightdm"

    # The ONLY nxserver restart for the whole run — here, once node.cfg
    # (nomachine step) and the display stack are already in place. With a timeout,
    # so a stuck process doesn't hang the rollout.
    if [ -x /usr/NX/bin/nxserver ]; then
        timeout 60 /usr/NX/bin/nxserver --restart >/dev/null 2>&1 \
            || warn "nxserver --restart didn't finish within 60s — check manually: ps -ef | grep nx"
    else
        warn "nxserver not found — has the nomachine step not been run yet?"
    fi
}

#==============================================================================
# STEP: shortcuts — desktop shortcuts for user smm
#     Placing .desktop files for the apps smm actually launches:
#     Firefox, Multilogin X, Telegram.
#     (NoMachine on the VPS is the server, it doesn't need a shortcut; WireGuard is a service.)
#     We copy the system .desktop into ~/Desktop and make smm the owner — that way
#     XFCE lets us mark the shortcut trusted without complaining.
#
#     NOTE: find is stopped at the first match via -print -quit, NOT
#     via `| head -n1`. With pipefail+an ERR trap, head would close the pipe, find
#     would catch SIGPIPE (code 141), and the script would fail with a false error right at the end.
#==============================================================================
link_desktop() {
    local pattern="$1" desktop_dir="/home/${WORK_USER}/Desktop" src dst
    src="$(find /usr/share/applications /var/lib/flatpak/exports/share/applications \
              -maxdepth 1 -iname "*${pattern}*.desktop" -print -quit 2>/dev/null || true)"
    if [ -n "$src" ]; then
        dst="${desktop_dir}/$(basename "$src")"
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

step_shortcuts() {
    log "Desktop shortcuts ($WORK_USER)"
    mkdir -p "/home/${WORK_USER}/Desktop"

    link_desktop "firefox"
    link_desktop "telegram"
    link_desktop "mlxapp"

    chown -R "${WORK_USER}:${WORK_USER}" "/home/${WORK_USER}/Desktop"
}

#==============================================================================
# STEP: summary — final summary
#==============================================================================
step_summary() {
    log "DONE. Summary:"
    echo "  Distro:        ${PRETTY_NAME:-unknown}"
    echo "  Users:         ${ADMIN_USER} (sudo), ${WORK_USER} (no privileges)"
    echo "  Desktop:       XFCE, Windows-10 theme (B00merang ${WIN10_THEME_COMMIT:0:7}), fallback Arc/Papirus"
    echo "  Locales:       ${LOCALES[*]} (LANG=${LOCALES[0]})"
    echo "  Software:      Firefox, Telegram, Multilogin X, NoMachine, WireGuard"
    echo
    echo "  This VPS's WireGuard public key (add it as a peer on the server):"
    echo "    $(cat /etc/wireguard/vps_public.key 2>/dev/null || echo '— not found (has the wireguard step not been run yet?)')"
    if [ -f /etc/wireguard/wg0.conf ]; then
        echo "  Tunnel:        wg0 → ${WG_SERVER_ENDPOINT} (address ${WG_ADDRESS})"
    else
        echo "  Tunnel:        NOT configured — fill in WG_SERVER_PUBKEY/WG_SERVER_ENDPOINT"
        echo "                 and rerun:  sudo bash $0 wireguard"
    fi
    echo
    warn "IMPORTANT — what this script has NOT done (planned as the next step):"
    echo "   • Firewall. NoMachine is currently listening on port 4000 on the PUBLIC IP."
    echo "     Until it's closed off by a firewall, only reach it via an SSH tunnel or WG."

    if [ -f /var/run/reboot-required ]; then
        warn "Kernel/packages were updated — a reboot is recommended."
    fi
}

#==============================================================================
# DISPATCHER
#     Canonical order of steps. Arguments filter the list, but execution order
#     is always canonical (dependencies: users before display, nomachine before
#     display, etc.).
#==============================================================================
STEPS=(base desktop users firefox telegram wireguard nomachine mlx display shortcuts summary)

usage() {
    echo "Usage: sudo bash $0 [step ...]"
    echo "No arguments — full run. The preflight step always runs."
    echo "Steps (canonical order): ${STEPS[*]}"
}

main() {
    case "${1:-}" in
        -h|--help|--list) usage; exit 0 ;;
    esac

    [ "$(id -u)" -eq 0 ] || die "Run as root:  sudo bash $0"
    touch "$LOG" 2>/dev/null || true
    trap 'die "Error (code $?) at line $LINENO. Check $LOG"' ERR

    # Validate arguments before starting: a typo in a step name shouldn't
    # surface after half an hour of rollout.
    local requested=("$@") s r known
    for r in "${requested[@]:-}"; do
        [ -z "$r" ] && continue
        known=0
        for s in "${STEPS[@]}"; do [ "$s" = "$r" ] && known=1; done
        [ "$known" -eq 1 ] || die "Unknown step: '$r'. Available: ${STEPS[*]}"
    done

    step_preflight

    local run_list=()
    if [ "${#requested[@]}" -eq 0 ] || [ -z "${requested[0]:-}" ]; then
        run_list=("${STEPS[@]}")
    else
        for s in "${STEPS[@]}"; do
            for r in "${requested[@]}"; do
                [ "$s" = "$r" ] && { run_list+=("$s"); break; }
            done
        done
        log "Selective run: ${run_list[*]}"
    fi

    for s in "${run_list[@]}"; do
        "step_${s}"
    done
}

main "$@"
