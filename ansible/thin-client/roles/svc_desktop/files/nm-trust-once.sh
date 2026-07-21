#!/usr/bin/env bash
# Belt and suspenders: ask xdg for the real desktop directory, and if it's
# unavailable fall back to the default ~/Desktop (which we pinned in user-dirs.dirs).
d="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
[ -n "$d" ] || d="$HOME/Desktop"
f="$d/nomachine.desktop"
[ -f "$f" ] || exit 0
chmod +x "$f"
gio set "$f" metadata::xfce-exe-checksum "$(sha256sum "$f" | cut -d' ' -f1)" 2>/dev/null || true
rm -f "$HOME/.config/autostart/nm-trust-once.desktop"
