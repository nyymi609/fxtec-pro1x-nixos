#!/usr/bin/env bash
# Haptics diagnostics + one short test buzz (low strength). Run on the phone as your user:
echo "== user / groups"
id
echo
echo "== haptics input device"
dev=""
for d in /sys/class/input/event*; do
  n=$(cat "$d/device/name" 2>/dev/null || true)
  if [ "$n" = "aw86224-haptics" ]; then dev=/dev/input/$(basename "$d"); fi
done
if [ -z "$dev" ]; then
  echo "no aw86224-haptics input device (driver not bound?)"
  dmesg 2>/dev/null | grep -i aw86224 | tail -5
  exit 1
fi
ls -l "$dev"
echo
echo "== udev properties (feedbackd looks at FEEDBACKD_*)"
udevadm info -q property -n "$dev" | grep -i -E "feedbackd|ID_INPUT|NAME|GROUP" || true
echo
echo "== feedbackd"
systemctl --no-pager status feedbackd 2>&1 | head -3 || true
pgrep -a fbd 2>/dev/null || pgrep -a feedbackd 2>/dev/null || echo "feedbackd daemon not running (it is started on demand over D-Bus)"
echo
echo "== feedbackd udev rules"
for f in /etc/udev/rules.d/*feedbackd* /run/current-system/sw/lib/udev/rules.d/*feedbackd*; do [ -e "$f" ] && {
  echo "-- $f"
  grep -v '^#' "$f" | head -40
}; done
echo
echo "== raw rumble test (needs write access to $dev)"
if [ -w "$dev" ]; then
  python3 - "$dev" <<'PY'
import os, struct, sys, time, fcntl
fd = os.open(sys.argv[1], os.O_RDWR)
# struct ff_effect (64 bit): type,id,direction,trigger{button,interval},replay{length,delay},pad,union(32)
FF_RUMBLE = 0x50
buf = bytearray(48)
struct.pack_into("<HhH", buf, 0, FF_RUMBLE, -1, 0)   # type, id (-1 = new), direction
struct.pack_into("<HH", buf, 6, 0, 0)               # trigger button, interval
struct.pack_into("<HH", buf, 10, 400, 0)            # replay length (ms), delay
struct.pack_into("<HH", buf, 16, 0x6000, 0x6000)    # rumble strong / weak magnitude
EVIOCSFF = 0x40304580
fcntl.ioctl(fd, EVIOCSFF, buf)
eid = struct.unpack_from("h", buf, 2)[0]
os.write(fd, struct.pack("llHHi", 0, 0, 0x15, eid, 1))   # EV_FF play
time.sleep(0.6)
print("sent a 400 ms rumble, effect id", eid)
PY
else
  echo "no write access to $dev: add yourself to the group that owns it (see above) or run with sudo"
fi
echo
echo "== feedbackd end-to-end (needs the feedbackd group)"
command -v fbcli >/dev/null && fbcli -t 2 -E button-pressed || echo "fbcli not in PATH"
