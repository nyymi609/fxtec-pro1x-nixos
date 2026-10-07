#!/usr/bin/env bash
# Feel the vibration motor at different settings.
#   sudo bash tools/haptics-tune.sh            sweep from stock to strongest, one buzz each
#   sudo bash tools/haptics-tune.sh GAIN DRV2  one buzz, e.g.  6 80
# GAIN = output gain code 0-7 (x1 x2 x4 x5 x8 x10 x20 x40; stock 5, default 6)
# DRV2 = sustained drive level 0-127 (stock 59)
# The buzzes are short and spaced out because overdriving warms the motor. When you have
# found a setting you like, make it permanent with
#   boot.kernelParams = [ "aw86224.d2s_gain=6" "aw86224.drv2_lvl=80" ];
set -u
[ "$(id -u)" = 0 ] || {
  echo "run with sudo"
  exit 1
}
par=/sys/module/aw86224/parameters
[ -d "$par" ] || {
  echo "aw86224 module not loaded (modprobe aw86224)"
  exit 1
}
dev=""
for d in /sys/class/input/event*; do
  [ "$(cat "$d/device/name" 2>/dev/null)" = aw86224-haptics ] && dev=/dev/input/$(basename "$d")
done
[ -n "$dev" ] || {
  echo "no aw86224-haptics input device"
  exit 1
}

buzz() {
  python3 - "$dev" <<'PY'
import os, struct, sys, time, fcntl
fd = os.open(sys.argv[1], os.O_RDWR)
buf = bytearray(48)
struct.pack_into("<HhH", buf, 0, 0x50, -1, 0)        
struct.pack_into("<HH", buf, 10, 400, 0)             
struct.pack_into("<HH", buf, 16, 0xffff, 0xffff)     
fcntl.ioctl(fd, 0x40304580, buf)                     
eid = struct.unpack_from("h", buf, 2)[0]
os.write(fd, struct.pack("llHHi", 0, 0, 0x15, eid, 1))
time.sleep(0.6)
PY
}

try() { # gain drv2
  echo "$1" >$par/d2s_gain
  echo "$2" >$par/drv2_lvl
  echo "gain=$1 drv2=$2 ..."
  buzz
  sleep 2
}

old_g=$(cat $par/d2s_gain)
old_d=$(cat $par/drv2_lvl)
if [ $# -ge 2 ]; then
  try "$1" "$2"
else
  for combo in "5 59" "6 59" "6 80" "6 100" "7 59" "7 80" "7 100" "7 127"; do
    try $combo
  done
  echo "restoring gain=$old_g drv2=$old_d"
  echo "$old_g" >$par/d2s_gain
  echo "$old_d" >$par/drv2_lvl
fi
