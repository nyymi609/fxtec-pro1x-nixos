#!/usr/bin/env bash
[ "$(id -u)" = 0 ] || {
  echo "run with sudo"
  exit 1
}
rd=""
for d in /sys/kernel/debug/regmap/*; do
  v=$(grep -m1 '^1308:' "$d/registers" 2>/dev/null | cut -d' ' -f2)
  [ -n "$v" ] && [ "$v" != "XX" ] && {
    rd=$d
    break
  }
done
echo "regmap: ${rd:-NOT FOUND}"
[ -z "$rd" ] && {
  ls /sys/kernel/debug/regmap/
  exit 1
}
r() { grep -m1 "^$1:" "$rd/registers" | cut -d' ' -f2; }
echo "== charger registers (all 0x1000-0x16ff that read)"
grep -E '^1[0-6][0-9a-f]{2}:' "$rd/registers" | grep -v ' XX$' | tr '\n' ' ' | fold -w 150
echo
echo "== key: 1006=state(low3 bits,7=disabled) 1042=enable 1043=pause 1643=wdog pet 1651=WD cfg 1653=bite cfg"
bat=/sys/class/power_supply/battery
for i in $(seq 1 24); do
  printf '%s up=%s v=%s st=%s | state=%s en=%s pause=%s wd=%s/%s apsd=%s icl=%s aicl=%s\n' \
    "$(date +%T)" "$(cut -d. -f1 /proc/uptime)" "$(cat $bat/voltage_now)" "$(cat $bat/status)" \
    "$(r 1006)" "$(r 1042)" "$(r 1043)" "$(r 1651)" "$(r 1653)" "$(r 1308)" "$(r 1107)" "$(r 1108)"
  sleep 10
done
echo "== dmesg"
dmesg | grep -i -E "pro1x-charger" | tail -30
