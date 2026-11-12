#!/bin/bash
# Paste into Unraid User Scripts; schedule At Startup of Array.
set -e
umask 077
r=/run/unraid-memory-watchdog
mkdir -p "$r"
if ! flock -n "$r/lock" true; then exit 0; fi
cp /boot/config/custom/unraid-memory-watchdog.sh "$r/watchdog.new"
bash -n "$r/watchdog.new"
mv "$r/watchdog.new" "$r/watchdog.sh"
nohup /bin/bash "$r/watchdog.sh" > "$r/service.log" 2>&1 < /dev/null &
