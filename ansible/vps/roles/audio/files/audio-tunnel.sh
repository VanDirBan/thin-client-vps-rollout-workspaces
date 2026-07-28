#!/usr/bin/env bash
# audio-tunnel: keeps module-tunnel-sink/source pointed at the thin client PipeWire
# and recreates them after a break. Static runner; parameters live in /etc/default.
set -u
CONF="/etc/default/audio-tunnel"
[ -r "$CONF" ] || exit 0
. "$CONF"
[ "${AT_ENABLE:-no}" = "yes" ]      || exit 0
[ "$(id -un)" = "${AT_USER:-smm}" ] || exit 0
[ -n "${AT_HOST:-}" ]               || exit 0

SRV="tcp:${AT_HOST}:${AT_PORT:-4713}"

# Module id of this type bound to our server (empty = not loaded)
mod_id() { pactl list short modules 2>/dev/null \
             | awk -v s="$SRV" -v m="$1" '$2==m && index($0,s){print $1; exit}'; }
unload() { local id; id="$(mod_id "$1")"; [ -n "$id" ] && pactl unload-module "$id" 2>/dev/null; }

# Our tunnel stream reached the LAPTOP but is left unattached
# (Sink: 4294967295 = -1). The stream has node.dont-reconnect=true, so it
# will never attach by itself — recreating the tunnel is the only fix.
remote_orphan() {
    timeout 3 pactl -s "$SRV" list sink-inputs 2>/dev/null \
    | awk '
        /^Sink Input #/ { if (blk != "") check(); blk = $0; next }
                        { blk = blk "\n" $0 }
        END             { if (blk != "") check() }
        function check() {
            if (index(blk, "Tunnel for") && index(blk, "Sink: 4294967295"))
                print "orphan"
        }'
}

fails=0
while :; do
    # Local pipewire-pulse is not up yet — wait.
    pactl info >/dev/null 2>&1 || { sleep 5; continue; }

    # Is the laptop audio server alive (also catches a down WG link)? If not, clean up and wait.
    if ! timeout 3 pactl -s "$SRV" info >/dev/null 2>&1; then
        unload module-tunnel-sink
        unload module-tunnel-source
        sleep 5; continue
    fi

    # Module exists but sink/source disappeared => zombie after a break — reload it.
    [ -n "$(mod_id module-tunnel-sink)"   ] && ! pactl list short sinks   | grep -qw laptop_out \
        && unload module-tunnel-sink
    [ -n "$(mod_id module-tunnel-source)" ] && ! pactl list short sources | grep -qw laptop_mic \
        && unload module-tunnel-source

    # Without sink=/source= the tunnel targets the laptop DEFAULT devices —
    # switching HyperX/built-in devices on the laptop side is transparent.
    just_loaded=0
    [ -n "$(mod_id module-tunnel-sink)" ] \
        || { pactl load-module module-tunnel-sink server="$SRV" sink_name=laptop_out >/dev/null 2>&1
             just_loaded=1; }
    [ -n "$(mod_id module-tunnel-source)" ] \
        || pactl load-module module-tunnel-source server="$SRV" source_name=laptop_mic >/dev/null 2>&1

    # RETRY: the stream reached the laptop but is not attached — recreate tunnel-sink
    # so it comes back while the laptop default sink is alive (HyperX/speakers).
    # Give a freshly loaded module one cycle to link, otherwise this false-triggers.
    if [ "$just_loaded" -eq 0 ] && [ -n "$(remote_orphan)" ]; then
        fails=$((fails + 1))
        logger -t audio-tunnel "laptop stream is unattached (-1) — recreating tunnel-sink (attempt ${fails})"
        unload module-tunnel-sink
        if [ "$fails" -ge 5 ]; then
            logger -t audio-tunnel "5 recreations without success — pausing for 60s"
            sleep 60; fails=0
        fi
        sleep 2; continue
    fi
    fails=0

    # VPS defaults: applications play through the laptop and record from its microphone
    [ "$(pactl get-default-sink   2>/dev/null)" = "laptop_out" ] || pactl set-default-sink   laptop_out 2>/dev/null
    [ "$(pactl get-default-source 2>/dev/null)" = "laptop_mic" ] || pactl set-default-source laptop_mic 2>/dev/null

    sleep 10
done
