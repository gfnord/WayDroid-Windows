#!/bin/bash
# Loads networking kernel modules (must be loaded individually -- modprobe
# treats extra args as module parameters, not additional module names) and
# starts the Waydroid container service.
set -u
for m in bridge iptable_filter iptable_nat iptable_mangle ip_tables xt_MASQUERADE xt_CHECKSUM; do
  modprobe "$m" 2>/dev/null
done
waydroid container start || true
