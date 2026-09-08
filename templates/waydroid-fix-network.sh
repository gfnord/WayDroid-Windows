#!/bin/bash
# Adds Android's default route.
#
# Android's netd never installs one in this environment: its BPF and xt_quota
# setup fails against the WSL kernel (visible in logcat as "Unable to swap
# active stats map: Address family not supported by protocol" and a missing
# /proc/net/xt_quota/globalAlert), so ConnectivityService never finishes
# bringing the link up. DHCP still hands out an address, which makes this look
# like working networking -- Android has an IP and a route to its own subnet,
# but no gateway, so nothing reaches the internet.
#
# Host-side NAT is already correct (waydroid0 bridge + MASQUERADE), so adding
# the route is all that is needed. Must run as root: "waydroid shell" refuses
# to run otherwise.
set -u

# Take the gateway from the bridge rather than hardcoding it -- waydroid picks
# the subnet at init time and it is not always 192.168.240.0/24.
GW=$(ip -4 -br addr show waydroid0 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
if [ -z "$GW" ]; then
  echo "waydroid0 bridge has no address; skipping default-route fix." >&2
  exit 0
fi

for i in $(seq 1 30); do
  if waydroid shell -- ip route show default 2>/dev/null | grep -q '^default'; then
    exit 0                      # already has one, nothing to do
  fi
  if waydroid shell -- ip route add default via "$GW" dev eth0 2>/dev/null; then
    echo "Added Android default route via $GW."
    exit 0
  fi
  sleep 2                       # Android may still be coming up
done

echo "Could not add Android's default route via $GW; there will be no internet inside Android." >&2
exit 0
