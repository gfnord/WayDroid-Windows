#!/bin/bash
# Gives Android a working default route and DNS.
#
# Android's netd never brings the ethernet network up on its own here: its BPF
# and xt_quota setup fails against the WSL kernel (logcat shows "Unable to swap
# active stats map: Address family not supported by protocol" and a missing
# /proc/net/xt_quota/globalAlert), so EthernetService's handler jams with
# queued NetworkOffer callbacks and no NetworkAgent ever connects. DHCP still
# hands out a lease, so Android has an address and a route to its own subnet
# but no gateway -- it looks connected and nothing reaches the internet.
#
# Note this must go through `ndc` (netd) rather than `ip route add`. Android
# uses fwmark policy routing: app traffic is resolved in netd's per-network
# table (`eth0`), not `main`, and netd reconciles `main` and deletes routes it
# does not own -- so a plain `ip route add` both targets the wrong table and
# gets reverted within a minute. Routes added through netd stick, and app DNS
# starts working because the resolver is bound to the same network.
#
# Host-side NAT (waydroid0 bridge + MASQUERADE) is already correct.
set -u

GW=$(ip -4 -br addr show waydroid0 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
SUBNET=$(ip -4 -o route show dev waydroid0 proto kernel 2>/dev/null | awk '{print $1}' | head -1)
if [ -z "$GW" ] || [ -z "$SUBNET" ]; then
  echo "waydroid0 bridge not configured; skipping Android network fix." >&2
  exit 0
fi

for i in $(seq 1 30); do
  if waydroid shell -- ip route show table eth0 2>/dev/null | grep -q '^default'; then
    exit 0                                  # already routed, nothing to do
  fi

  # netd's id for the ethernet network, taken from its own routing rules
  # (fwmark 0x1<netid>/0x1ffff) rather than assuming the usual 100.
  MARK=$(waydroid shell -- ip rule list 2>/dev/null \
           | grep -o 'fwmark 0x[0-9a-f]*/0x1ffff' | head -1 \
           | sed 's|.*fwmark 0x\([0-9a-f]*\)/.*|\1|')
  if [ -n "$MARK" ]; then
    NETID=$(( 0x$MARK & 0xffff ))
    # Connected subnet first: netd rejects the gateway route as "Network is
    # unreachable" until the table can reach the gateway itself.
    waydroid shell -- ndc network route add "$NETID" eth0 "$SUBNET"        >/dev/null 2>&1
    waydroid shell -- ndc network route add "$NETID" eth0 0.0.0.0/0 "$GW"  >/dev/null 2>&1
    waydroid shell -- ndc network default set "$NETID"                     >/dev/null 2>&1
    if waydroid shell -- ip route show table eth0 2>/dev/null | grep -q '^default'; then
      echo "Android network configured: default via $GW on netd network $NETID."
      exit 0
    fi
  fi
  sleep 2                                   # Android may still be coming up
done

echo "Could not configure Android's default route; there will be no internet inside Android." >&2
exit 0
