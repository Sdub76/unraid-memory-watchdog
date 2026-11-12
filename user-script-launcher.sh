#!/bin/bash
# Paste into Unraid User Scripts; schedule At Startup of Array.
# This short launcher starts the longer watchdog and then returns control to the
# plugin. It does not perform memory checks itself or wait for an incident.

# Stop the launcher if a preparation step fails, rather than launch a broken copy.
set -e
# Newly created files should be readable/writable only by the owner where supported.
umask 077
# /run lives in RAM. Keep the running copy and its small status log off the flash.
r=/run/unraid-memory-watchdog
mkdir -p "$r"
# Probe the watchdog's lock. If an instance already owns it, leave it alone.
# The watchdog itself also takes this lock, guarding against overlapping launches.
if ! flock -n "$r/lock" true; then exit 0; fi
# Prepare a fresh RAM copy without changing the persistent source on the boot drive.
cp /boot/config/custom/unraid-memory-watchdog.sh "$r/watchdog.new"
# Settings are copied separately so updating the main script preserves preferences.
# Remove an old RAM copy first: if the persistent settings file was removed, the
# next start must use built-in defaults rather than silently reuse stale settings.
rm -f "$r/unraid-memory-watchdog.conf"
if [[ -f /boot/config/custom/unraid-memory-watchdog.conf ]]; then
    cp /boot/config/custom/unraid-memory-watchdog.conf "$r/unraid-memory-watchdog.conf"
fi
# "bash -n" checks shell syntax without running the script or taking any action.
bash -n "$r/watchdog.new"
# Give the checked copy its final name only after the syntax check passes.
mv "$r/watchdog.new" "$r/watchdog.sh"
# nohup lets the watchdog survive the launcher's exit. Bash is invoked explicitly
# because executable permissions/mount options can differ on the boot flash.
# ">" starts a fresh RAM service log; "2>&1" includes errors in that same log.
# Input comes from /dev/null, so the child never waits for this plugin's terminal.
# The final "&" starts it in the background, allowing this User Script to finish.
nohup /bin/bash "$r/watchdog.sh" > "$r/service.log" 2>&1 < /dev/null &
