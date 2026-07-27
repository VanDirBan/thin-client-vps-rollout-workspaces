#!/usr/bin/env bash
#
# xfce-win10.sh — Windows-10-style LOOK AND BEHAVIOR for Xfce, on the fly.
# Goal: move a user from Windows to Linux with minimal discomfort.
#
# The script installs and downloads NOTHING and does NOT require sudo. All packages and the
# Windows-10 theme are put into the image by the FIRST script (provisioning, as root). Here — only
# application via the user's D-Bus:
#   • Super = "Start", Windows hotkeys (Win+E/D/L/R/I), Aero Snap via keyboard
#   • double click in the file manager (not single)
#   • one workspace (not 4 — so windows don't get "lost")
#   • Computer/Trash/Home icons on the desktop
#   • window tiling when dragged to the edge (Aero Snap with the mouse)
#   • dark bottom taskbar panel, light windows via the Windows-10 theme
#   • volume widget in the tray (left of the clock) + multimedia keys
#     (requires xfce4-pulseaudio-plugin, installed by local-provision.sh)
#
# Run it AS YOUR OWN user in an active graphical XFCE session (can be over SSH):
#     bash xfce-win10.sh
# NOT as root: otherwise it won't pick up the user session's D-Bus.
#
# The theme defaults to Windows-10 and tolerates the directory name: it works with either
# /usr/share/themes/Windows-10 or .../Windows-10-master. If it's missing —
# falls back to Arc/Papirus. The first script puts the theme into the image (gtk2-engines-murrine
# is required, otherwise GTK2 apps will have no theme).
#
# set -e is deliberately NOT enabled: some xfconf-query calls "fail" normally (the property
# doesn't exist yet — we create it). set -u catches typos in variable names.
set -u

# --- 0. Checks ------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || {
  echo "Don't run as root — this needs your session's D-Bus. Run it as your own user." >&2
  exit 1
}
command -v xfconf-query >/dev/null 2>&1 || {
  echo "xfconf-query not found (the xfconf package should be installed by the first script)." >&2
  exit 1
}

U="$USER"
HOME_DIR="$(getent passwd "$U" | cut -d: -f6)"
UID_N="$(id -u "$U")"
CFG="$HOME_DIR/.config/xfce4/xfconf/xfce-perchannel-xml"
PANELRC_DIR="$HOME_DIR/.config/xfce4/panel"

# one backup per file (as .orig) so repeated runs don't spawn extra copies
backup_once() { [ -f "$1" ] && [ ! -f "$1.orig" ] && cp -a "$1" "$1.orig"; return 0; }

# --- 1. DBUS/DISPLAY of the live session -------------------------------------------
SPID="$(pgrep -u "$U" -n xfce4-session || true)"
if [ -z "$SPID" ]; then
  echo "No active xfce4-session found. Log in to Xfce and run this again." >&2
  exit 1
fi
read_env() { tr '\0' '\n' < "/proc/$SPID/environ" 2>/dev/null | sed -n "s/^$1=//p" | head -n1; }
DBUS_SESSION_BUS_ADDRESS="$(read_env DBUS_SESSION_BUS_ADDRESS)"
[ -n "$DBUS_SESSION_BUS_ADDRESS" ] || DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus"
DISPLAY="$(read_env DISPLAY)"
[ -n "$DISPLAY" ] || DISPLAY=":0"
export DBUS_SESSION_BUS_ADDRESS DISPLAY

# --- 2. Generic xfconf helper (create-or-set, idempotent) -------------
# setp <channel> <prop> <type> <val...>  — doesn't kill the script if something's missing.
setp() {
  local ch="$1" p="$2" ty="$3"; shift 3
  local args=(); local v
  for v in "$@"; do args+=(-t "$ty" -s "$v"); done
  xfconf-query -c "$ch" -p "$p" "${args[@]}" 2>/dev/null \
    || xfconf-query -c "$ch" -p "$p" -n "${args[@]}" 2>/dev/null || true
}

# --- 3. DEFAULT theme: Windows-10, tolerant of the -master suffix ------------
have_theme() { [ -d "/usr/share/themes/$1" ] || [ -d "$HOME_DIR/.themes/$1" ]; }
have_icons() { [ -d "/usr/share/icons/$1"  ] || [ -d "$HOME_DIR/.icons/$1"  ]; }

# find_dir <themes|icons> <base> → prints the REAL directory name (what
# GTK expects): first an exact match, then a prefix match (Windows-10-master, etc.).
find_dir() {
  local root="$1" base="$2" d
  for d in "/usr/share/$root/$base" "$HOME_DIR/.$root/$base"; do
    [ -d "$d" ] && { echo "$base"; return 0; }
  done
  for d in "/usr/share/$root/$base"* "$HOME_DIR/.$root/$base"*; do
    [ -d "$d" ] && { basename "$d"; return 0; }
  done
  return 1
}

GTK_THEME="$(find_dir themes Windows-10)"  || GTK_THEME="$(find_dir themes Arc)"     || GTK_THEME="Arc"
ICON_THEME="$(find_dir icons Windows-10)"  || ICON_THEME="$(find_dir icons Papirus)" || ICON_THEME="Papirus"

case "$GTK_THEME" in
  Windows-10*) : ;;
  *) echo "[!] Windows-10 theme not found → windows will use '$GTK_THEME' instead." >&2
     echo "    The first script is supposed to put it in /usr/share/themes/Windows-10." >&2 ;;
esac
echo "[*] Applying theme: $GTK_THEME, icons: $ICON_THEME"

# --- 4. Appearance: window theme/icons/font/antialiasing ----------------------
setp xsettings /Net/ThemeName     string "$GTK_THEME"
setp xsettings /Net/IconThemeName string "$ICON_THEME"
setp xsettings /Gtk/FontName      string "Noto Sans 10"   # closest match to Segoe UI
have_icons "Bibata-Modern-Classic" && setp xsettings /Gtk/CursorThemeName string "Bibata-Modern-Classic"
setp xsettings /Xft/Antialias int 1
setp xsettings /Xft/Hinting   int 1
setp xsettings /Xft/HintStyle string "hintslight"
setp xsettings /Xft/RGBA      string "rgb"

setp xfwm4 /general/theme            string "$GTK_THEME"
setp xfwm4 /general/use_compositing  bool   true
# Buttons like in Windows: empty on the left, minimize/maximize/close on the right.
setp xfwm4 /general/button_layout    string "|HMC"

# --- 5. BEHAVIOR like Windows ---------------------------------------------
# 5a. One workspace (a Windows user isn't expecting 4 and "loses" windows across them).
setp xfwm4 /general/workspace_count int 1

# 5b. Aero Snap with the mouse: tiling when dragged to the screen edge.
setp xfwm4 /general/tile_on_move    bool true
setp xfwm4 /general/snap_to_border  bool true
setp xfwm4 /general/snap_to_windows bool true

# 5c. Double click in Thunar (single click is the #1 stumbling block for newcomers).
setp thunar /misc-single-click bool false

# 5d. Desktop icons: Computer / Trash / Home / removable media.
setp xfce4-desktop /desktop-icons/style int 2
setp xfce4-desktop /desktop-icons/file-icons/show-home       bool true
setp xfce4-desktop /desktop-icons/file-icons/show-trash      bool true
setp xfce4-desktop /desktop-icons/file-icons/show-filesystem bool true
setp xfce4-desktop /desktop-icons/file-icons/show-removable  bool true

# 5e. Windows-style hotkeys.
KBD=xfce4-keyboard-shortcuts
# Super alone = "Start" (opens Whisker).
setp "$KBD" /commands/custom/Super_L        string "xfce4-popup-whiskermenu"
setp "$KBD" "/commands/custom/<Super>e"     string "thunar"                      # Win+E — file explorer
setp "$KBD" "/commands/custom/<Super>r"     string "xfce4-appfinder --collapsed" # Win+R — run
setp "$KBD" "/commands/custom/<Super>i"     string "xfce4-settings-manager"      # Win+I — settings
setp "$KBD" "/commands/custom/<Super>l"     string "xflock4"                     # Win+L — lock
# Show desktop (Win+D) and keyboard Aero Snap (Win+arrows) — xfwm4 actions.
setp "$KBD" "/xfwm4/custom/<Super>d"        string "show_desktop_key"
setp "$KBD" "/xfwm4/custom/<Super>Up"       string "maximize_window_key"
setp "$KBD" "/xfwm4/custom/<Super>Down"     string "hide_window_key"
setp "$KBD" "/xfwm4/custom/<Super>Left"     string "tile_left_key"
setp "$KBD" "/xfwm4/custom/<Super>Right"    string "tile_right_key"

# 5f. Desktop background. If there's no wallpaper — solid Windows-style blue.
WALL="${WIN10_WALLPAPER:-}"   # you can set a path to your own image via this variable
mapfile -t IMG_PROPS < <(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E '/last-image$' || true)
for p in "${IMG_PROPS[@]:-}"; do
  [ -z "$p" ] && continue
  base="${p%/last-image}"
  if [ -n "$WALL" ] && [ -f "$WALL" ]; then
    setp xfce4-desktop "$base/last-image"  string "$WALL"
    setp xfce4-desktop "$base/image-style" int    5     # zoomed
    setp xfce4-desktop "$base/color-style" int    0
  else
    setp xfce4-desktop "$base/image-style" int 0        # no image — solid color
    setp xfce4-desktop "$base/color-style" int 0
    setp xfce4-desktop "$base/rgba1"       double 0.0 0.298 0.474 1.0
  fi
done

sleep 2   # let xfconfd flush ALL the changes above to disk before we overwrite the panel

# --- 6. Whisker as "Start" (icon on the left, no label) ----------------------
mkdir -p "$PANELRC_DIR"
backup_once "$PANELRC_DIR/whiskermenu-1.rc"
cat > "$PANELRC_DIR/whiskermenu-1.rc" <<'WHISKER'
button-title=
button-icon=start-here
button-single-row=false
show-button-title=false
show-button-icon=true
launcher-show-name=true
launcher-show-description=false
category-show-name=true
view-as-icons=false
default-category=0
recent-items-max=10
favorites-in-recent=true
position-search-alternate=true
position-commands-alternate=false
position-categories-alternate=false
stay-on-focus-out=false
confirm-session-command=true
menu-width=450
menu-height=550
WHISKER

# --- 7. Panel: backup + new layout at the bottom ----------------------------------
mkdir -p "$CFG"
backup_once "$CFG/xfce4-panel.xml"

xfce4-panel --quit 2>/dev/null || true
pkill -u "$U" xfconfd 2>/dev/null || true
sleep 1

# dark-mode — a direct child of <channel>, NOT inside <panels>.
# position p=10 (south-center) = a full-width bottom panel, like the Windows taskbar.
cat > "$CFG/xfce4-panel.xml" <<'PANEL_XML'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="dark-mode" type="bool" value="true"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="mode" type="uint" value="0"/>
      <property name="position" type="string" value="p=10;x=0;y=0"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="40"/>
      <property name="icon-size" type="uint" value="22"/>
      <property name="length" type="uint" value="100"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="7"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
      </property>
      <property name="background-style" type="uint" value="1"/>
      <property name="background-rgba" type="array">
        <value type="double" value="0.137255"/>
        <value type="double" value="0.149020"/>
        <value type="double" value="0.176471"/>
        <value type="double" value="0.960784"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu"/>
    <property name="plugin-2" type="string" value="tasklist">
      <property name="grouping" type="uint" value="1"/>
      <property name="show-labels" type="bool" value="false"/>
      <property name="flat-buttons" type="bool" value="true"/>
      <property name="show-handle" type="bool" value="false"/>
    </property>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-4" type="string" value="systray">
      <property name="square-icons" type="bool" value="true"/>
    </property>
    <!-- Volume widget left of the clock, Windows-like. enable-keyboard-shortcuts
         lets the plugin handle laptop XF86Audio* keys. -->
    <property name="plugin-7" type="string" value="pulseaudio">
      <property name="enable-keyboard-shortcuts" type="bool" value="true"/>
      <property name="show-notifications" type="bool" value="true"/>
      <property name="mixer-command" type="string" value="pavucontrol"/>
    </property>
    <property name="plugin-5" type="string" value="clock"/>
    <property name="plugin-6" type="string" value="showdesktop"/>
  </property>
</channel>
PANEL_XML

# --- 8. Restarting the panel (brings xfconfd back up) + WM ---------------------------
setsid sh -c 'xfce4-panel' >/dev/null 2>&1 &
sleep 2
xfwm4 --replace >/dev/null 2>&1 &
sleep 1

# --- 9. Clock: digital, time + date like in Windows (after the panel starts) ----
# Different Xfce versions use different keys — set them all best-effort.
CP=/plugins/plugin-5
setp xfce4-panel "$CP/digital-time-format" string "%H:%M"
setp xfce4-panel "$CP/digital-date-format" string "%d.%m.%Y"
setp xfce4-panel "$CP/digital-layout"      uint   3
setp xfce4-panel "$CP/digital-format"      string "%H:%M%n%d.%m.%Y"   # legacy fallback
xfce4-panel --restart >/dev/null 2>&1 || true
sleep 1

# --- 10. Self-diagnostics: what actually got applied ---------------------------
echo
echo "── Checking what was applied ─────────────────────────────"
printf '  GTK theme:    %s\n' "$(xfconf-query -c xsettings -p /Net/ThemeName     2>/dev/null || echo '—')"
printf '  Icons:        %s\n' "$(xfconf-query -c xsettings -p /Net/IconThemeName 2>/dev/null || echo '—')"
printf '  Window theme: %s\n' "$(xfconf-query -c xfwm4     -p /general/theme     2>/dev/null || echo '—')"
printf '  Workspaces:   %s\n' "$(xfconf-query -c xfwm4     -p /general/workspace_count 2>/dev/null || echo '—')"
case "$GTK_THEME" in Windows-10*) : ;; *) echo "  [!] Theme is NOT Windows-10 → it's missing from the image. Fix the first script." ;; esac
ls /usr/lib/*/gtk-2.0/*/engines/libmurrine.so >/dev/null 2>&1 \
  || echo "  [!] gtk2-engines-murrine missing → GTK2 apps will have NO theme (install it in the first script)."
command -v xfce4-popup-whiskermenu >/dev/null 2>&1 \
  || echo "  [!] whiskermenu not installed → NO Start button (install xfce4-whiskermenu-plugin)."
ls /usr/lib/*/xfce4/panel/plugins/libpulseaudio-plugin.so >/dev/null 2>&1 \
  || echo "  [!] xfce4-pulseaudio-plugin not installed → no volume widget and volume keys may not work."
pgrep -u "$U" xfce4-panel >/dev/null 2>&1 || echo "  [!] xfce4-panel isn't running — the panel didn't come up."
pgrep -u "$U" xfdesktop  >/dev/null 2>&1 || echo "  [!] xfdesktop isn't running — there will be no desktop icons."
echo "──────────────────────────────────────────────────────"
echo
echo "Done."
echo "  • Super = Start; Win+E explorer, Win+D show desktop, Win+L lock, Win+R run."
echo "  • Aero Snap: Win+←/→ snap to side, Win+↑ maximize, Win+↓ minimize (also via mouse to the edge)."
echo "  • Double click in files, one workspace, Computer/Trash icons on the desktop."
echo "  • Custom wallpaper:  WIN10_WALLPAPER=/path/to/win10.jpg bash $0"
