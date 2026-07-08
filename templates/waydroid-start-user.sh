#!/bin/bash
# Starts a nested Weston compositor (works around a Waydroid/WSLg direct-
# render bug that leaves the app window stuck committing a 1x1 buffer),
# then starts the Waydroid session and shows the full UI once Android
# actually reports ready (not a fixed guess -- boot time varies).
set -u

export WAYLAND_DISPLAY=wayland-0
pkill -f 'weston --backend=wayland-backend' 2>/dev/null
sleep 1
setsid nohup weston --backend=wayland-backend.so --width=1280 --height=800 > /tmp/nested-weston.log 2>&1 < /dev/null &
disown
sleep 3

export WAYLAND_DISPLAY=wayland-1
export PYTHONUNBUFFERED=1
rm -f /tmp/waydroid-session.log
setsid nohup waydroid session start > /tmp/waydroid-session.log 2>&1 < /dev/null &
disown

# Wait up to 90s for Android to actually report ready before showing the UI
for i in $(seq 1 45); do
  if grep -q 'is ready' /tmp/waydroid-session.log 2>/dev/null; then
    break
  fi
  sleep 2
done

setsid nohup waydroid show-full-ui > /tmp/waydroid-ui.log 2>&1 < /dev/null &
disown
sleep 2
