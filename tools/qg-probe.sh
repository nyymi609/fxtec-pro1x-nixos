#!/usr/bin/env bash
# Looks for the PMI632 fuel gauge block (QG, base 0x4800) and reads what it measures:
# battery voltage, battery CURRENT, the hardware's own OCV readings.

set -u
[ "$(id -u)" = 0 ] || {
  echo "run with sudo"
  exit 1
}
root=${REGROOT:-/sys/kernel/debug/regmap}
base=${QGBASE:-4800} # hex, no 0x
bat=${BAT:-/sys/class/power_supply/battery}

rd=""
for d in "$root"/*; do
  [ -r "$d/registers" ] || continue
  v=$(grep -m1 "^$(printf '%04x' $((0x$base + 4))):" "$d/registers" | cut -d' ' -f2)
  if [ "$v" = "0d" ]; then
    rd=$d
    break
  fi
done
if [ -z "$rd" ]; then
  echo "no regmap has QG (type 0x0d) at 0x$base. regmaps found:"
  ls "$root"
  echo "regs near 0x$base per regmap:"
  grep -H -m6 "^48[0-9a-f][0-9a-f]:" "$root"/*/registers 2>/dev/null | head -20
  exit 1
fi
echo "QG regmap: $rd"

r8() { grep -m1 "^$(printf '%04x' $((0x$base + $1))):" "$rd/registers" | cut -d' ' -f2; }
r16() {
  local lo hi
  lo=$(r8 "$1")
  hi=$(r8 $(($1 + 1)))
  [ -n "$lo" ] && [ -n "$hi" ] && [ "$lo" != XX ] && [ "$hi" != XX ] && echo $((0x$hi$lo)) || echo -1
}
s16() {
  local v=$1
  [ "$v" -ge 32768 ] && v=$((v - 65536))
  echo "$v"
}
uv() { [ "$1" -lt 0 ] && echo "?" || echo $(($1 * 194637 / 1000)); }

sub=$(r8 5)
case "$sub" in 03) isc=152588 ;; *) isc=305176 ;; esac
ua() { [ "$1" -lt 0 ] && echo "?" || echo $(($(s16 "$1") * isc / 1000)); }

echo "subtype=0x$sub (03 = 5A current ADC, else 10A)  status1=0x$(r8 8) status2=0x$(r8 9)"
echo "PON OCV   : $(uv "$(r16 $((0x70)))") uV   (S7, taken at boot)"
echo "S3 good OCV: $(uv "$(r16 $((0x74)))") uV  (sleep OCV; 0 = none yet)"
echo
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
printf '%-9s %-6s %-9s %-9s %-10s %-10s %-9s %s\n' time phase qgV_uV avgV_uV ibat_uA avgI_uA adcV_uV cap%
phase() {
  local name=$1 end=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$end" ]; do
    printf '%-9s %-6s %-9s %-9s %-10s %-10s %-9s %s\n' "$(date +%T)" "$name" \
      "$(uv "$(r16 $((0xC0)))")" "$(uv "$(r16 $((0x80)))")" \
      "$(ua "$(r16 $((0xC6)))")" "$(ua "$(r16 $((0x82)))")" \
      "$(cat $bat/voltage_now 2>/dev/null)" "$(cat $bat/capacity 2>/dev/null)"
    sleep 2
  done
}
phase idle1 20
for _ in $(seq "$(nproc)"); do
  (while :; do :; done) &
  pids+=($!)
done
phase LOAD 30
cleanup
pids=()
phase idle2 20
echo
echo "ibat sign: negative or positive, whichever way it goes, should flip between idle and LOAD by a few hundred mA."
