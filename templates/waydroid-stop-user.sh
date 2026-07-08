#!/bin/bash
set -u
waydroid session stop 2>/dev/null
pkill -f 'weston --backend=wayland-backend' 2>/dev/null
true
