#!/bin/bash
# Repairs and display tuning applied once Android is up. Run as root from
# Start-Waydroid.bat: "waydroid shell" refuses to run as a normal user.
#
# Everything here is idempotent, so the launcher can run it on every start.
set -u

# Android takes a while to answer; nothing below works until it does.
for _ in $(seq 1 45); do
  waydroid shell -- true >/dev/null 2>&1 && break
  sleep 2
done
if ! waydroid shell -- true >/dev/null 2>&1; then
  echo "Android is not responding; skipping post-boot fixes." >&2
  exit 0
fi

# --- 1. Stop app crashes from killing the framework -------------------------
#
# Adding an app-error dialog window fails in this compositor setup, and the
# exception lands on system_server's android.ui thread, which kills it:
#
#     FATAL EXCEPTION IN SYSTEM PROCESS: android.ui
#     java.lang.RuntimeException: Adding window failed
#       at android.app.Dialog.show(Dialog.java:352)
#       at com.android.server.am.ErrorDialogController...
#
# So any app crash restarts the whole framework and takes the network with it,
# which looks like flaky internet rather than a crash loop.
if [ "$(waydroid shell -- settings get global hide_error_dialogs 2>/dev/null | tr -d '\r')" != "1" ]; then
  waydroid shell -- settings put global hide_error_dialogs 1 >/dev/null 2>&1 \
    && echo "Disabled app-error dialogs (they crash system_server here)."
fi

# --- 2. Default route -------------------------------------------------------
#
# netd's BPF/xt_quota setup fails on the WSL kernel, so EthernetService blocks
# in awaitIpClientStart() and never finishes bringing the link up. DHCP still
# leases an address, so Android looks connected but has no gateway.
#
# This must go through ndc: Android resolves app traffic in netd's per-network
# table, not "main", and netd deletes routes in "main" that it does not own --
# so "ip route add" both targets the wrong table and gets reverted.
if ! waydroid shell -- ip route show table eth0 2>/dev/null | grep -q '^default'; then
  GW=$(ip -4 -br addr show waydroid0 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
  SUBNET=$(ip -4 -o route show dev waydroid0 proto kernel 2>/dev/null | awk '{print $1}' | head -1)
  MARK=$(waydroid shell -- ip rule list 2>/dev/null \
           | grep -o 'fwmark 0x[0-9a-f]*/0x1ffff' | head -1 \
           | sed 's|.*fwmark 0x\([0-9a-f]*\)/.*|\1|')
  if [ -n "$GW" ] && [ -n "$SUBNET" ] && [ -n "$MARK" ]; then
    NETID=$(( 0x$MARK & 0xffff ))
    # Connected subnet first: netd rejects the gateway route as "Network is
    # unreachable" until the table can reach the gateway itself.
    waydroid shell -- ndc network route add "$NETID" eth0 "$SUBNET"       >/dev/null 2>&1
    waydroid shell -- ndc network route add "$NETID" eth0 0.0.0.0/0 "$GW" >/dev/null 2>&1
    waydroid shell -- ndc network default set "$NETID"                    >/dev/null 2>&1
    if waydroid shell -- ip route show table eth0 2>/dev/null | grep -q '^default'; then
      echo "Android network configured: default via $GW on netd network $NETID."
    else
      echo "Could not configure Android's default route; no internet inside Android." >&2
    fi
  fi
fi

# --- 3. Phone-shaped layouts ------------------------------------------------
#
# Android picks phone vs tablet UI from the display width in dp
# (px / density * 160). At the image's stock density a 720px-wide screen
# reports ~640dp, which is tablet territory. Derive a density that lands near
# a phone's 360dp, so changing WIDTH/HEIGHT in waydroid-start-user.sh does not
# also require hand-tuning a density here.
#
# Note "wm density" reports a manual setting as a second "Override density"
# line and leaves "Physical density" at the panel's own value, so the current
# value has to be read from the override when one is present.
PX=$(waydroid shell -- wm size 2>/dev/null | sed -n 's/.*Physical size: \([0-9]*\)x.*/\1/p' | head -1)
if [ -n "$PX" ] && [ "$PX" -gt 0 ] 2>/dev/null; then
  WANT=$(( PX * 160 / 360 ))
  DENS=$(waydroid shell -- wm density 2>/dev/null | tr -d '\r')
  CUR=$(printf '%s\n' "$DENS" | sed -n 's/.*Override density: \([0-9]*\).*/\1/p' | head -1)
  [ -z "$CUR" ] && CUR=$(printf '%s\n' "$DENS" | sed -n 's/.*Physical density: \([0-9]*\).*/\1/p' | head -1)
  if [ "$CUR" != "$WANT" ]; then
    waydroid shell -- wm density "$WANT" >/dev/null 2>&1 \
      && echo "Set display density to $WANT so a ${PX}px screen reports ~360dp (phone layout)."
  fi
fi

exit 0
