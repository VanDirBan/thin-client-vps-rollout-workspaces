#!/usr/bin/env bash
# Manual audio-tunnel restart from the user session (desktop button).
# Restarts the unit, waits until laptop_out appears again, and reports via notification.
set -u
notify() { notify-send -i "$1" "Audio tunnel" "$2" 2>/dev/null || true; }

notify audio-card "Restarting sound…"
systemctl --user restart audio-tunnel.service 2>/dev/null

# The keeper creates tunnel-sink on its next loop pass; give it up to 20s.
for _ in $(seq 1 10); do
    sleep 2
    if pactl list short sinks 2>/dev/null | grep -qw laptop_out; then
        notify audio-volume-high "Sound restarted, everything is OK."
        exit 0
    fi
done
notify dialog-error "Sound did not come up within 20s. Check that the laptop is powered on, or contact the administrator."
exit 1
