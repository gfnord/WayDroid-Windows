#!/bin/bash
# Starts a nested Weston compositor (works around a Waydroid/WSLg direct-
# render bug that leaves the app window stuck committing a 1x1 buffer),
# then starts the Waydroid session and shows the full UI once Android
# actually reports ready (not a fixed guess -- boot time varies).
set -u

# Everything below is backgrounded with setsid/nohup, so a missing weston
# produces no visible error and the script still exits 0 -- the window just
# never appears. Check up front instead.
if ! command -v weston >/dev/null 2>&1; then
  echo "ERROR: weston is not installed." >&2
  echo "Android runs inside a nested Weston compositor; without it the session" >&2
  echo "cannot start. Install it with:  sudo apt-get install -y weston" >&2
  exit 1
fi

session_running() {
  waydroid status 2>/dev/null | grep -qE '^Session:[[:space:]]*RUNNING'
}
weston_running() {
  pgrep -f 'weston --backend=wayland-backend' >/dev/null 2>&1
}

# Clicking Start while Waydroid is already up used to pkill weston out from
# under the running session. The session itself survives, but its compositor
# connection is gone and `waydroid session start` then refuses with "Session
# is already running", so nothing ever reattaches: you get an empty Weston
# window, no Android UI, and no way out but a full stop. Handle both states
# explicitly instead.
if session_running && weston_running; then
  echo "Waydroid is already running; re-showing the UI."
  export WAYLAND_DISPLAY=wayland-1
  setsid nohup waydroid show-full-ui > /tmp/waydroid-ui.log 2>&1 < /dev/null &
  disown
  exit 0
fi

# A session whose compositor died cannot be reattached, so tear it down before
# starting a fresh one.
if session_running; then
  echo "Stopping a session left without a compositor before restarting."
  waydroid session stop >/dev/null 2>&1 || true
  sleep 2
fi

# Size of the nested compositor window, and therefore of Android's display.
# Portrait, phone-shaped by default. Android picks phone vs tablet layouts from
# the width in dp (px / density * 160), so waydroid-post-boot.sh sets the
# density to keep this near a phone's ~360dp -- change WIDTH/HEIGHT here and
# the layout follows automatically.
#
# Resizing the window afterwards makes Waydroid restart the session, so the
# size is fixed at launch rather than adjusted live.
WIDTH=720
HEIGHT=1280

export WAYLAND_DISPLAY=wayland-0
pkill -f 'weston --backend=wayland-backend' 2>/dev/null
sleep 1
setsid nohup weston --backend=wayland-backend.so --width="$WIDTH" --height="$HEIGHT" > /tmp/nested-weston.log 2>&1 < /dev/null &
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
