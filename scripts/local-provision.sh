#!/usr/bin/env bash
#==============================================================================
# local-provision.sh — prepares a LOCAL physical PC (Debian 13 "trixie")
#   as a thin client for a VPS: XFCE + NoMachine (client+server) + WireGuard + audio.
#   Machine: HP 255 G7, AMD Ryzen 5 3500U (Picasso/Vega).
#
# Run:   sudo bash local-provision.sh
# Idempotent: rerunning it should not break already applied changes.
#
# IMPORTANT: put xfce-win10.sh in the same directory as this script. It will be
#            copied to the target user and should be applied LATER, by that user,
#            from an active XFCE session.
#==============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# CONFIG
#------------------------------------------------------------------------------
# --- Users ---
ADMIN_USER="${ADMIN_USER:-adams}"          # existing user that receives sudo access
SVC_USER="${SVC_USER:-smm}"                # service user to create, without sudo
SVC_USER_PASSWORD="${SVC_USER_PASSWORD:-CHANGE_ME_ON_FIRST_RUN}"    # initial SVC_USER password; change it with: passwd "$SVC_USER"
# Target desktop user. Defaults to the user that invoked sudo.
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo adams)}}"

# --- WorkMon agent (third-party installer located next to this script) ---
WORKMON_AGENT_DIRNAME="${WORKMON_AGENT_DIRNAME:-workmon-agent-0.4.0}"   # directory with install.sh, searched under $SELF_DIR

# --- WireGuard (full tunnel through the VPS) ---
WG_IFACE="${WG_IFACE:-wg0}"
WG_CLIENT_ADDR="${WG_CLIENT_ADDR:-10.8.0.2/24}"
WG_SERVER_PUBKEY="${WG_SERVER_PUBKEY:-REPLACE_WITH_WG_SERVER_PUBLIC_KEY}"
WG_ENDPOINT="${WG_ENDPOINT:-REPLACE_WITH_VPS_ENDPOINT:51820}"
WG_ALLOWED="${WG_ALLOWED:-0.0.0.0/0, ::/0}"
WG_KEEPALIVE="${WG_KEEPALIVE:-25}"
# DNS through the tunnel. Uncomment it in wg0.conf below if the VPS has a resolver.

# Tunnel autostart on boot + watchdog retries. "yes" = enable, "no" = only
# prepare the units without enabling them. WARNING for full-tunnel mode: if you
# enable this before adding the peer on the VPS, after reboot the laptop will
# bring the tunnel up "to nowhere" and lose internet connectivity. Recovery must
# be done at the laptop itself (see the summary).
WG_AUTOSTART="${WG_AUTOSTART:-yes}"
WG_WATCHDOG_MAX_AGE="${WG_WATCHDOG_MAX_AGE:-180}"   # seconds without a handshake => watchdog recreates the tunnel

# --- NoMachine: keep the same version as on the VPS. A v9 client can connect to
#     a v8 server, but identical versions are cleaner. Check downloads.nomachine.com (id=1).
#     WARNING: for a non-existing file, the NoMachine server returns 200+HTML,
#     not 404, so after download we verify that the file is a real .deb. ---
NOMACHINE_BRANCH="${NOMACHINE_BRANCH:-9.7}"
NOMACHINE_VERSION="${NOMACHINE_VERSION:-9.7.3}"
NOMACHINE_BUILD="${NOMACHINE_BUILD:-1}"
NOMACHINE_MD5="${NOMACHINE_MD5:-8af5efe7b8ad3872a4681c4acf551b62}"   # empty "" = do not verify MD5
NOMACHINE_URL="https://download.nomachine.com/download/${NOMACHINE_BRANCH}/Linux/nomachine_${NOMACHINE_VERSION}_${NOMACHINE_BUILD}_amd64.deb"

export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/local-provision.log"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
log()  { echo -e "\n\033[1;32m==>\033[0m $*" | tee -a "$LOG"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" | tee -a "$LOG"; }
die()  { echo -e "\033[1;31m[FAIL]\033[0m $*" | tee -a "$LOG"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запусти от root:  sudo bash $0"
id -u "$TARGET_USER" >/dev/null 2>&1 || die "Юзер '$TARGET_USER' не найден. Задай TARGET_USER в конфиге."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

trap 'die "Ошибка на строке $LINENO. Смотри $LOG"' ERR

log "Целевой пользователь рабочего стола: $TARGET_USER ($TARGET_HOME)"

# Best-effort installation: failure becomes a warning, not a hard rollout stop.
apt_try() { apt-get install -y "$@" || warn "Не удалось поставить: $*  (пропускаю)"; }

#==============================================================================
# 0. SSH host keys: on this machine they sometimes get deleted, so restore them
#    first, before apt full-upgrade (see the ordering warning below).
#==============================================================================
log "SSH host keys: ssh-keygen -A (создаёт только ОТСУТСТВУЮЩИЕ, существующие не трогает)"
if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        systemctl restart ssh
        log "ssh.service перезапущен"
    elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
        systemctl restart sshd
        log "sshd.service перезапущен"
    else
        warn "Юнит ssh/sshd не найден (openssh-server не установлен?) — сервис не перезапущен"
    fi
else
    warn "ssh-keygen не найден в PATH — openssh-client/server не установлен, пропускаю"
fi
#==============================================================================
# 0.0.1 SSH: public collector key (workmon-collect) in root's authorized_keys.
#    Required so the admin node can fetch .age files over SSH without a password
#    (BatchMode=yes).
#    Idempotent: rerunning does NOT create duplicates.
#==============================================================================
# Collector public key. The private part must exist ONLY on the admin node.
# Prefer passing this through the environment instead of committing it here.
COLLECT_PUBKEY="${COLLECT_PUBKEY:-}"

key_body=$(awk '{print $2}' <<<"$COLLECT_PUBKEY")
if [[ -z "$key_body" ]]; then
    warn "COLLECT_PUBKEY пуст или не похож на ключ — пропускаю authorized_keys"
else
    auth_keys=/root/.ssh/authorized_keys
    install -d -m 700 -o root -g root /root/.ssh
    touch "$auth_keys"
    chown root:root "$auth_keys"
    chmod 600 "$auth_keys"

    # Compare by the base64 key body (the 2nd field), not by the whole line:
    # a different trailing comment will not create a duplicate. -F means fixed
    # string search: keys contain + and /, which would otherwise be treated as regex.
    if grep -qF "$key_body" "$auth_keys"; then
        log "authorized_keys: ключ сборщика уже установлен, пропускаю"
    else
        # If the file does not end with a newline, add one to avoid joining lines.
        [[ -s "$auth_keys" && -n "$(tail -c1 "$auth_keys")" ]] && printf '\n' >> "$auth_keys"
        printf '%s\n' "$COLLECT_PUBKEY" >> "$auth_keys"
        log "authorized_keys: ключ сборщика добавлен"
    fi
fi
#==============================================================================
# 0.1 Users: sudo for adams, service user smm without sudo
#==============================================================================
log "sudo-пакет + права для $ADMIN_USER"
apt-get install -y sudo
if id -u "$ADMIN_USER" >/dev/null 2>&1; then
    usermod -aG sudo "$ADMIN_USER"
    log "$ADMIN_USER добавлен в группу sudo"
else
    warn "Пользователь $ADMIN_USER не найден — sudo не выдан"
fi

log "Служебный пользователь $SVC_USER (без sudo)"
if ! id -u "$SVC_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$SVC_USER"
    echo "${SVC_USER}:${SVC_USER_PASSWORD}" | chpasswd
    log "$SVC_USER создан, пароль задан из SVC_USER_PASSWORD"
else
    log "$SVC_USER уже существует — пропускаю создание и пароль (чтобы не затирать сменённый пароль при реране)"
fi
warn "Пароль $SVC_USER задан через SVC_USER_PASSWORD — это дефолт до первой смены: passwd $SVC_USER"

#==============================================================================
# 0.2 GRUB: no boot delay and no boot menu
#==============================================================================
log "GRUB: TIMEOUT=0, TIMEOUT_STYLE=hidden, RECORDFAIL_TIMEOUT=0"
GRUB_CFG="/etc/default/grub"
cp -a "$GRUB_CFG" "${GRUB_CFG}.bak.$(date +%s)"
set_grubcfg() {
    local key="$1" val="$2"
    if grep -qE "^#?${key}=" "$GRUB_CFG"; then
        sed -i -E "s|^#?${key}=.*|${key}=${val}|" "$GRUB_CFG"
    else
        echo "${key}=${val}" >> "$GRUB_CFG"
    fi
}
set_grubcfg GRUB_TIMEOUT 0
set_grubcfg GRUB_TIMEOUT_STYLE hidden
set_grubcfg GRUB_RECORDFAIL_TIMEOUT 0
update-grub
log "GRUB обновлён (бэкап рядом с $GRUB_CFG)"

#==============================================================================
# 1. APT components: contrib / non-free / non-free-firmware
#    On physical hardware, microcode and proprietary firmware (Wi-Fi) will not
#    arrive without these components.
#==============================================================================
log "Включаю contrib / non-free / non-free-firmware"
DEB822="/etc/apt/sources.list.d/debian.sources"
if [ -f "$DEB822" ]; then
    # deb822 format (default in trixie): append missing components to each section.
    for comp in contrib non-free non-free-firmware; do
        awk -v c="$comp" '
            /^Components:/ {
                n=split($0,a," "); has=0
                for(i=2;i<=n;i++) if(a[i]==c) has=1
                if(!has) $0=$0" "c
            }
            {print}
        ' "$DEB822" > "$DEB822.tmp" && mv "$DEB822.tmp" "$DEB822"
    done
else
    # Classic sources.list format.
    if ! grep -qE '^deb .*non-free-firmware' /etc/apt/sources.list 2>/dev/null; then
        warn "deb822 не найден — добавляю компоненты в /etc/apt/sources.list вручную, проверь результат"
        sed -i -E 's/^(deb .*trixie[^ ]* main)(.*)$/\1 contrib non-free non-free-firmware\2/' /etc/apt/sources.list || true
    fi
fi

#==============================================================================
# 2. System update + firmware/microcode + kernel headers
#==============================================================================
log "Обновление системы"
apt-get update -y
apt-get full-upgrade -y --allow-downgrades

log "Прошивки, микрокод AMD, заголовки ядра, базовые утилиты"
apt-get install -y \
    amd64-microcode \
    firmware-linux-free firmware-misc-nonfree \
    firmware-amd-graphics firmware-realtek \
    linux-headers-amd64 dkms \
    curl wget gnupg ca-certificates apt-transport-https unzip htop

log "Сеть: NetworkManager (для Wi-Fi на ноуте + апплет в трее)"
apt-get install -y network-manager network-manager-gnome

#==============================================================================
# 3. XFCE + display manager (manual login) + fonts + themes for the Win10 look
#==============================================================================
log "XFCE (ядро десктопа)"
apt-get install -y xfce4 xfconf dbus-x11 dbus-user-session x11-xserver-utils

log "Обязательное для облика Windows-10"
apt-get install -y xfce4-whiskermenu-plugin      # Start button
apt-get install -y gtk2-engines-murrine          # renders the GTK2 part of the B00merang theme
apt-get install -y gvfs gvfs-daemons             # Trash/removable media on the desktop
apt-get install -y fonts-noto fonts-noto-color-emoji fonts-liberation

log "Обязательные пакеты для облика Windows-10"
apt-get install -y xfce4-whiskermenu-plugin gtk2-engines-murrine \
                   gvfs gvfs-daemons xfconf curl unzip


log "Тема Windows-10 (B00merang) в системные каталоги"
_install_win10_look() {
  local tmp; tmp="$(mktemp -d)"; local ok=1
  # GTK + xfwm4 theme -> /usr/share/themes/Windows-10 (specifically without -master).
  if [ ! -d /usr/share/themes/Windows-10 ]; then
    if curl -fsSL -o "$tmp/theme.zip" \
         https://codeload.github.com/B00merang-Project/Windows-10/zip/refs/heads/master \
       && unzip -q "$tmp/theme.zip" -d "$tmp/t"; then
      rm -rf /usr/share/themes/Windows-10
      mv "$tmp/t/Windows-10-master" /usr/share/themes/Windows-10
    else ok=0; fi
  fi
  # Icons -> /usr/share/icons/Windows-10.
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
  [ "$ok" -eq 1 ] || log "[!] Тему Windows-10 не скачал — клиенты откатятся на Arc/Papirus"
}
_install_win10_look

log "Фолбэк-темы"
apt_try arc-theme papirus-icon-theme

log "Десктоп-экстры (best-effort)"
apt_try xfce4-goodies
apt_try pipewire pipewire-pulse wireplumber
apt_try xfce4-screensaver                        # only needed if Win+L must really lock the session


# Force lightdm as the default DM without an interactive dialog.
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
systemctl enable lightdm >/dev/null 2>&1 || true
# The Bibata cursor is optional in xfce-win10.sh: if it is not installed, it simply
# will not be applied. Alternatively, comment out CursorThemeName in xfce-win10.sh.

#==============================================================================
# 4. Audio: PipeWire + pulse shim + client utilities required by the .md procedure
#==============================================================================
log "PipeWire + pipewire-pulse + утилиты pactl/paplay/parecord + pavucontrol"
apt-get install -y \
    pipewire pipewire-pulse pipewire-audio wireplumber \
    pulseaudio-utils pavucontrol
usermod -aG audio,video "$TARGET_USER"
# Load the tunnel modules manually according to your .md AFTER WG is up.

#==============================================================================
# 5. WireGuard: install + client key pair + wg0.conf (do NOT bring it up here)
#==============================================================================
log "WireGuard: установка и генерация клиентского ключа"
apt-get install -y wireguard wireguard-tools
( umask 077
  mkdir -p /etc/wireguard
  if [ ! -f /etc/wireguard/client_private.key ]; then
      wg genkey | tee /etc/wireguard/client_private.key | wg pubkey > /etc/wireguard/client_public.key
      log "Клиентская пара ключей сгенерирована"
  else
      log "Клиентский ключ уже есть — переиспользую"
  fi
)
CLIENT_PRIV="$(cat /etc/wireguard/client_private.key)"
CLIENT_PUB="$(cat /etc/wireguard/client_public.key)"

# Rebuild the config on every run (idempotent).
cat > "/etc/wireguard/${WG_IFACE}.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG_CLIENT_ADDR}
# DNS = 10.8.0.1   # uncomment if the VPS has DNS and you want resolution through the tunnel
                   # (full tunnel => otherwise DNS may leak outside the VPS; requires openresolv/systemd-resolved)

[Peer]
PublicKey = ${WG_SERVER_PUBKEY}
Endpoint = ${WG_ENDPOINT}
AllowedIPs = ${WG_ALLOWED}
PersistentKeepalive = ${WG_KEEPALIVE}
EOF
chmod 600 "/etc/wireguard/${WG_IFACE}.conf"
log "Записан /etc/wireguard/${WG_IFACE}.conf (туннель НЕ поднимаю в этом прогоне)"

#--- 5.1 Watchdog + autostart --------------------------------------------------
# WireGuard retries handshakes by itself (PersistentKeepalive is set), but that
# does not cover:
#   - boot race: network is not ready, wg-quick@ fails and does not retry;
#   - resume from suspend: tunnel is "stuck" with an old handshake;
#   - server temporarily unavailable during boot.
# Every 30s the watchdog checks the AGE of the last handshake and recreates the
# tunnel if it is stale. In full-tunnel mode this is more reliable than ping
# because ping will not pass through a dead tunnel anyway.
log "Watchdog WireGuard (скрипт + systemd timer)"
cat > /usr/local/sbin/wg-watchdog.sh <<EOF
#!/usr/bin/env bash
set -u
IFACE="${WG_IFACE}"
MAX_AGE=${WG_WATCHDOG_MAX_AGE}
EOF
cat >> /usr/local/sbin/wg-watchdog.sh <<'EOF'
log() { logger -t wg-watchdog "$*"; }

# 1) Interface is missing: bring it up (boot race / after manual shutdown).
if ! wg show "$IFACE" >/dev/null 2>&1; then
    if wg-quick up "$IFACE" 2>/dev/null; then log "interface was down — up"; else log "up failed (сервер недоступен?)"; fi
    exit 0
fi

# 2) Newest handshake among peers.
last="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)"
[ -z "$last" ] && last=0

# No handshake yet: WG will keep retrying via keepalive, do not flap the tunnel.
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
ExecStart=/usr/local/sbin/wg-watchdog.sh
EOF

cat > /etc/systemd/system/wg-watchdog.timer <<EOF
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
    systemctl enable "wg-quick@${WG_IFACE}.service" >/dev/null 2>&1 || warn "не удалось enable wg-quick@${WG_IFACE}"
    systemctl enable wg-watchdog.timer            >/dev/null 2>&1 || warn "не удалось enable wg-watchdog.timer"
    log "Автозапуск ВКЛЮЧЁН: wg-quick@${WG_IFACE} (boot) + wg-watchdog.timer (ретраи каждые 30с)"
    warn "Туннель сработает после ребута. Сначала добавь peer на VPS (иначе full-tunnel в никуда)."
else
    log "Автозапуск НЕ включён (WG_AUTOSTART=no). Юниты установлены, но disabled."
fi
# Do not touch the current session: bring the tunnel up manually when ready (see summary).

#==============================================================================
# 6. NoMachine — full package (client + server: this machine can be connected to)
#==============================================================================
log "NoMachine ${NOMACHINE_VERSION} (полный: клиент + сервер)"
if ! dpkg -s nomachine >/dev/null 2>&1; then
    TMP_DEB="$(mktemp --suffix=.deb)"
    curl -L -f -A "Mozilla/5.0" -o "$TMP_DEB" "$NOMACHINE_URL" \
        || die "curl не смог скачать NoMachine: $NOMACHINE_URL"
    # For a missing file, NoMachine returns 200+HTML; catch that here.
    if ! dpkg-deb --info "$TMP_DEB" >/dev/null 2>&1; then
        warn "Скачанный файл — НЕ валидный .deb. Первые байты:"
        head -c 80 "$TMP_DEB" | tr -d '\0' | tee -a "$LOG" || true
        rm -f "$TMP_DEB"
        die "Похоже, версии ${NOMACHINE_VERSION}_${NOMACHINE_BUILD} нет на сервере. Сверь на downloads.nomachine.com (id=1) и поправь NOMACHINE_* в конфиге."
    fi
    if [ -n "$NOMACHINE_MD5" ]; then
        got="$(md5sum "$TMP_DEB" | awk '{print $1}')"
        [ "$got" = "$NOMACHINE_MD5" ] || warn "MD5 не совпал (ждал $NOMACHINE_MD5, получил $got). Возможно, вышел новый билд — продолжаю."
    fi
    apt-get install -y "$TMP_DEB"
    rm -f "$TMP_DEB"
else
    log "NoMachine уже установлен — пропускаю"
fi
# --- node.cfg setup: XFCE session + quiet client mode --------------------------
# NoMachine stores defaults COMMENTED OUT (#Key 1). The helper uncomment/sets an
# existing key or appends it if missing. One backup and one restart for all edits.
NODE_CFG="/usr/NX/etc/node.cfg"
set_nodecfg() {
    local key="$1" val="$2"
    if grep -qE "^#?${key}[[:space:]]" "$NODE_CFG"; then
        sed -i -E "s|^#?${key}[[:space:]].*|${key} ${val}|" "$NODE_CFG"
    else
        echo "${key} ${val}" >> "$NODE_CFG"
    fi
}
if [ -f "$NODE_CFG" ]; then
    cp -a "$NODE_CFG" "${NODE_CFG}.bak.$(date +%s)"
    # Use XFCE as the session; otherwise incoming connections to this machine get a gray screen.
    set_nodecfg DefaultDesktopCommand '"/usr/bin/startxfce4"'
    # Quiet client: remove the on-screen "desktop is being viewed" banner...
    set_nodecfg ShowDesktopViewed 0
    # ...and the sound alert on connection.
    set_nodecfg EnableSoundAlert 0
    /usr/NX/bin/nxserver --restart >/dev/null 2>&1 || warn "Не удалось перезапустить nxserver"
    log "node.cfg: DefaultDesktopCommand=startxfce4, ShowDesktopViewed=0, EnableSoundAlert=0 (бэкап рядом)"
else
    warn "node.cfg не найден — NoMachine не установлен? Пропускаю настройку."
fi

#==============================================================================
# 7. xfce-win10.sh — copy it to the user (apply LATER, as the user, in XFCE)
#==============================================================================
WIN10_SRC="$SELF_DIR/xfce-win10.sh"
if [ -f "$WIN10_SRC" ]; then
    cp -f "$WIN10_SRC" "$TARGET_HOME/xfce-win10.sh"
    chmod +x "$TARGET_HOME/xfce-win10.sh"
    chown "${TARGET_USER}:${TARGET_USER}" "$TARGET_HOME/xfce-win10.sh"
    log "xfce-win10.sh скопирован в $TARGET_HOME (запусти от юзера в активной XFCE-сессии)"
else
    warn "xfce-win10.sh не найден рядом со скриптом — пропускаю. Положи его в $SELF_DIR и перезапусти, либо примени вручную."
fi

#==============================================================================
# 8. NoMachine desktop launcher (client for connecting to the VPS)
#    IMPORTANT: do NOT copy system .desktop files from /usr/share/applications:
#    they contain a web-session MIME handler (NoDisplay=true, Exec ... --session),
#    not a launcher. Generate our own clean launcher for plain nxplayer instead
#    (stable path: /usr/NX/bin).
#==============================================================================
if id -u "$SVC_USER" >/dev/null 2>&1; then
    SVC_HOME="$(getent passwd "$SVC_USER" | cut -d: -f6)"
    log "Ярлык NoMachine на рабочем столе ($SVC_USER)"
    DESKTOP_DIR="${SVC_HOME}/Desktop"
    mkdir -p "$DESKTOP_DIR"

    NM_DST="${DESKTOP_DIR}/nomachine.desktop"
    NM_ICON="$(find /usr/NX /usr/share/icons -type f \
        \( -iname 'nxplayer*.png' -o -iname 'nxplayer*.svg' \
           -o -iname 'nomachine*.png' -o -iname 'nomachine*.svg' \) 2>/dev/null | head -n1)"
    [ -z "$NM_ICON" ] && NM_ICON="nxplayer"
    cat > "$NM_DST" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=NoMachine
Comment=Подключение к удалённому рабочему столу
Exec=/usr/NX/bin/nxplayer
Icon=${NM_ICON}
Terminal=false
Categories=Network;RemoteAccess;
EOF
    chmod +x "$NM_DST"
    chown "${SVC_USER}:${SVC_USER}" "$NM_DST"

    # Marking a launcher as "trusted" in XFCE requires a LIVE session (gvfs). There
    # is no live session during provisioning, so install a one-shot autostart job:
    # on first login it writes the sha256-checksum metadata and removes itself.
    # After that, the icon starts without the "Allow launch?" prompt.
    log "Одноразовый автозапуск для пометки ярлыка доверенным (сработает при первом входе $SVC_USER)"
    BIN_DIR="${SVC_HOME}/.local/bin"
    AUTOSTART_DIR="${SVC_HOME}/.config/autostart"
    mkdir -p "$BIN_DIR" "$AUTOSTART_DIR"
    cat > "${BIN_DIR}/nm-trust-once.sh" <<'EOF'
#!/usr/bin/env bash
f="$HOME/Desktop/nomachine.desktop"
[ -f "$f" ] || exit 0
chmod +x "$f"
gio set "$f" metadata::xfce-exe-checksum "$(sha256sum "$f" | cut -d' ' -f1)" 2>/dev/null || true
rm -f "$HOME/.config/autostart/nm-trust-once.desktop"
EOF
    chmod +x "${BIN_DIR}/nm-trust-once.sh"
    cat > "${AUTOSTART_DIR}/nm-trust-once.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=NoMachine trust once
Exec=${BIN_DIR}/nm-trust-once.sh
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    chown -R "${SVC_USER}:${SVC_USER}" \
        "$DESKTOP_DIR" "${SVC_HOME}/.config" "${SVC_HOME}/.local"
else
    warn "Пользователь $SVC_USER не найден — ярлык NoMachine не создан"
fi

#==============================================================================
# 9. WorkMon agent — installation from a neighboring directory
#==============================================================================
WORKMON_DIR="$SELF_DIR/$WORKMON_AGENT_DIRNAME"
WORKMON_INSTALLER="$WORKMON_DIR/install.sh"
if [ -f "$WORKMON_INSTALLER" ]; then
    log "Запускаю установщик WorkMon agent: $WORKMON_INSTALLER"
    chmod +x "$WORKMON_INSTALLER"
    ( cd "$WORKMON_DIR" && bash "$WORKMON_INSTALLER" ) || die "Установка WorkMon agent завершилась ошибкой"
    log "WorkMon agent установлен"
else
    warn "Не найден $WORKMON_INSTALLER — пропускаю установку WorkMon agent. Положи $WORKMON_AGENT_DIRNAME рядом со скриптом и перезапусти."
fi



# --- Final permission safety net: the whole smm $HOME belongs to smm. ---
if id -u "$SVC_USER" >/dev/null 2>&1; then
    SVC_HOME_FINAL="$(getent passwd "$SVC_USER" | cut -d: -f6)"
    chown -R "${SVC_USER}:${SVC_USER}" "$SVC_HOME_FINAL"
fi
#==============================================================================
# SUMMARY
#==============================================================================
log "ГОТОВО. Сводка:"
echo "  Рабочий стол: XFCE, вход через lightdm (ручной)."
echo "  ПО:           NoMachine (клиент+сервер), WireGuard, PipeWire+утилиты, NetworkManager."
echo
echo "  >>> ПУБЛИЧНЫЙ КЛЮЧ ЭТОГО КЛИЕНТА (добавь как [Peer] на VPS):"
echo "      $CLIENT_PUB"
echo "      (на VPS: AllowedIPs = 10.8.0.2/32 для этого peer)"
echo
warn "ДАЛЬШЕ — по порядку (full-tunnel: если ошибёшься в WG, потеряешь интернет, поэтому делай ЗА ноутом):"
echo "   1) Добавь ключ выше в /etc/wireguard/wg0.conf на VPS, на VPS:  wg-quick up wg0 (или systemctl restart)."
echo "   2) Здесь подними туннель:        sudo wg-quick up ${WG_IFACE}"
echo "      Проверь:                      ping 10.8.0.1   и   curl ifconfig.me  (должен показать IP VPS)."
echo "   3) Автозапуск + ретраи: WG_AUTOSTART=${WG_AUTOSTART}."
if [ "$WG_AUTOSTART" = "yes" ]; then
echo "      УЖЕ включены: wg-quick@${WG_IFACE} (boot) + wg-watchdog.timer (каждые 30с переподнимает мёртвый туннель)."
echo "      Туннель поднимется сам после ребута — но только если peer на VPS уже добавлен (п.1)!"
echo "      ЕСЛИ ПРОПАЛ ИНТЕРНЕТ (peer ещё не настроен):"
echo "        sudo systemctl disable --now wg-quick@${WG_IFACE} wg-watchdog.timer && sudo wg-quick down ${WG_IFACE}"
else
echo "      Юниты установлены, но disabled. Включить:  sudo systemctl enable --now wg-quick@${WG_IFACE} wg-watchdog.timer"
fi
echo "   4) Аудио-туннель — по твоей .md (module-native-protocol-tcp на 10.8.0.2:4713),"
echo "      ПОСЛЕ поднятия WG. Учти: устройство 44100Hz, в .md rate=48000 (PipeWire ресемплит)."
echo "   5) Запусти NoMachine (ярлык на рабочем столе) и добавь подключение к VPS: host 10.8.0.1, протокол NX."
echo "   6) Залогинься в XFCE и примени облик:   bash ~/xfce-win10.sh   (НЕ от root)."
echo
echo "   Диагностика watchdog:  journalctl -t wg-watchdog -n 30   |   systemctl list-timers wg-watchdog.timer"
echo
warn "Безопасность: NoMachine-сервер слушает порт 4000 — не пробрасывай его в интернет с роутера."
echo "   Ходи к этой машине только по LAN или через wg0 (10.8.0.2)."
echo "Измените хост нейм ноутбука командой - hostnamectl set-hostname your-new-hostname"
log "Рекомендуется перезагрузка, чтобы подхватились прошивки/микрокод и стартовал lightdm:  sudo reboot"
