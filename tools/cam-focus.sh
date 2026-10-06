#!/usr/bin/env bash
# Set the rear lens position (0-1023, ~100 = 1 m, higher = closer). The lens only
# keeps the position while something has it open, so run this while Snapshot (or
# `cam -c 1 --capture`) is showing the rear camera. No argument: show the control.
set -eu
dev=""
for d in /dev/v4l-subdev*; do
  if v4l2-ctl -d "$d" --list-ctrls 2>/dev/null | grep -q focus_absolute; then dev=$d; break; fi
done
[ -n "$dev" ] || { echo "no lens subdev found (dmesg | grep -i dw9800)"; exit 1; }
echo "lens: $dev"
if [ $# -ge 1 ]; then v4l2-ctl -d "$dev" --set-ctrl focus_absolute="$1"; fi
v4l2-ctl -d "$dev" --get-ctrl focus_absolute
