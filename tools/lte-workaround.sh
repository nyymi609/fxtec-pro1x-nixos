#!/usr/bin/env bash
TARGET=198.51.100.1

mobile_if() { ip -o -4 addr show 2>/dev/null | awk '$2 ~ /^qmapmux/ { print $2; exit }'; }

pid=""
stop() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  pid=""
}
trap 'stop; exit' EXIT INT TERM

running=""
while :; do
  ifname=$(mobile_if)
  if [ "$ifname" != "$running" ]; then
    stop
    running=$ifname
    if [ -n "$ifname" ]; then
      echo "keeping $ifname busy"
      ping -q -n -i 0.02 -s 16 -I "$ifname" "$TARGET" >/dev/null 2>&1 &
      pid=$!
    else
      echo "waiting for mobile data"
    fi
  fi
  sleep 5
done
