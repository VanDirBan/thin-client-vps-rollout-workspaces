#!/usr/bin/env bash
set -u
IFACE="${WG_IFACE:-wg0}"
MAX_AGE="${WG_MAX_AGE:-180}"
log() { logger -t wg-watchdog "$*"; }

# 1) interface is missing — bring it up (boot race / after shutdown)
if ! wg show "$IFACE" >/dev/null 2>&1; then
    if wg-quick up "$IFACE" 2>/dev/null; then log "interface was down — up"; else log "up failed (server unreachable?)"; fi
    exit 0
fi

# 2) the most recent handshake among peers
last="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)"
[ -z "$last" ] && last=0

# no handshake yet — WG retries on its own via keepalive, don't poke it
[ "$last" -eq 0 ] && exit 0

age=$(( $(date +%s) - last ))
if [ "$age" -gt "$MAX_AGE" ]; then
    log "handshake age ${age}s > ${MAX_AGE}s — reconnect"
    wg-quick down "$IFACE" 2>/dev/null || true
    wg-quick up   "$IFACE" 2>/dev/null || log "reconnect up failed"
fi
exit 0
