# Unraid memory watchdog

A host memory watchdog you can deploy to each Unraid server through User Scripts. **Default: capture diagnostics and send an Unraid Alert. No automatic restarts.** Monitoring covers pressure from any Docker container, host process, VM, or kernel allocation. Optional recovery is limited to Docker containers.

Requirements: Unraid, Bash 4+, MemAvailable, GNU coreutils including file sync, and util-linux flock/findmnt. Docker is optional for diagnostics. Hosts with memory PSI can enable the additional pressure signal; other hosts use MemAvailable.

## What happens

| Trigger | Default response |
| --- | --- |
| MemAvailable <=15% for 60 seconds (three samples) | Save warning report; send **Alert** |
| MemAvailable <=5%, first observed sample | Immediately begin critical report; send **Alert** |
| Critical persists for 60 seconds | Diagnostics only; optional Docker recovery if enabled |
| Flash unavailable/full or capture budget blocks report | Send **Alert**, limited to once per severity per boot |
| Available >=20% for 120 seconds | Rearm for a new pressure episode |

The 30-second poll interval means critical detection normally takes up to 30 seconds plus scheduling delay. Capture starts immediately when detected; it does not wait for the critical duration used by optional recovery. Invalid metrics or gaps >90 seconds reset pressure streaks. A warning can escalate to critical. Each episode produces at most one report per severity; it does not keep writing during an ongoing incident.

Reports include hostname, pressure measurements, memory counters, kernel log, syslog, VM counters, uptime/load, process RSS and command names, and Docker memory stats. Process arguments, Docker environment variables, full Unraid diagnostics ZIPs and compression are excluded. Missing Docker/PSI does not disable host memory monitoring.

Evidence streams directly into the incident file, with meminfo, recent kernel messages and syslog first. A best-effort file flush runs after those essential sections and after completion. If later collection fails, partial evidence can remain in the reserved file. A `CAPTURE COMPLETE` footer indicates collection finished; individual sections can still contain errors or truncated output. The initial `CAPTURE RESERVED / INCOMPLETE` line is retained; use the footer to distinguish a completed report.

## Flash protection and limits

- No routine poll writes to flash. The script runs from RAM; locks, PID, notification suppression and recovery markers live in `/run/unraid-memory-watchdog`.
- Reports go to `/boot/logs/unraid-memory-watchdog`. Each of eight sections is capped at 64 KiB and three seconds plus a one-second kill grace. Total report size is <530,000 bytes.
- Warning cooldown six hours; critical cooldown one hour; shared maximum **four reports per rolling 24 hours**. Retain 12 reports, about 6.1 MiB maximum payload. Retention deletes oldest reports only after a new capture.
- Filenames, including incomplete files, preserve the write budget across restarts/reboots. Do not delete them casually: deletion also removes rate-limit history. Future timestamps suppress captures until the wall clock catches up.
- Requires the actual `/boot` mount and >=64 MiB free. A missing mount never redirects evidence into an accidental RAM-root `/boot` directory. A failed or suppressed capture waits for recovery and a new episode before another attempt.
- Flushes happen only during incidents, against the incident file, never as a global flush on each poll. Notifications use Unraid's own subsystem; any additional writes by your configured notification agents are outside this script's report budget.
- A fully stalled kernel, abrupt OOM, power loss, or uninterruptible flash I/O can still defeat collection or timeout. A userspace watchdog cannot guarantee recovery or durable evidence. Remote syslog is a useful companion.

## Install on each server

1. Put `unraid-memory-watchdog.sh` at:

   ```text
   /boot/config/custom/unraid-memory-watchdog.sh
   ```

   Example from PowerShell in the folder containing the downloaded files; replace `YOUR-SERVER`:

   ```powershell
   ssh root@YOUR-SERVER 'mkdir -p /boot/config/custom'
   scp ./unraid-memory-watchdog.sh root@YOUR-SERVER:/boot/config/custom/
   ```

2. In the Unraid terminal, normalize line endings and validate syntax:

   ```bash
   sed -i 's/\r$//' /boot/config/custom/unraid-memory-watchdog.sh
   bash -n /boot/config/custom/unraid-memory-watchdog.sh
   ```

3. In **Settings > Notification Settings**, enable notifications and configure your preferred email or agent destinations for **Alerts**. Use Unraid's own test controls to confirm delivery. The watchdog invokes Unraid's native `notify` command with `-i alert`, its highest severity, for saved/incomplete reports, capture failures, and optional restart attempts. Remote delivery depends on your configured channels; calling notify successfully does not prove a message reached your phone/email. No credentials are embedded in the watchdog.

4. In the **User Scripts** plugin, add `Unraid memory watchdog`. Paste the contents of `user-script-launcher.sh`:

   ```bash
   #!/bin/bash
   set -e
   umask 077
   r=/run/unraid-memory-watchdog
   mkdir -p "$r"
   if ! flock -n "$r/lock" true; then exit 0; fi
   cp /boot/config/custom/unraid-memory-watchdog.sh "$r/watchdog.new"
   bash -n "$r/watchdog.new"
   mv "$r/watchdog.new" "$r/watchdog.sh"
   nohup /bin/bash "$r/watchdog.sh" > "$r/service.log" 2>&1 < /dev/null &
   ```

   Set **At Startup of Array**, apply, and run it once now. The launcher returns promptly; a background child continues. The internal lock blocks duplicate instances. It continues monitoring through later array stops. For monitoring before the first array start, invoke this launcher through Bash from `/boot/config/go` after its existing lines instead. Use one startup method. Always invoke flash scripts through Bash because flash can be mounted noexec.

5. Verify:

   ```bash
   cat /run/unraid-memory-watchdog/service.log
   p=$(cat /run/unraid-memory-watchdog/pid)
   ps -p "$p" -o pid,args
   flock -n /run/unraid-memory-watchdog/lock true
   echo "lock check exit=$? (1 means watchdog holds it)"
   ```

   Expect `restart_container=0 psi=0` and the watchdog Bash process. Recheck after your next normal reboot. There is no external supervisor: an unexpected exit requires relaunching it.

## Settings

Edit the constants at the top of the persistent script, then stop/relaunch to load them. Defaults adapt host thresholds to the RAM size of each server.

```bash
WARN_PCT=15
CRIT_PCT=5
RECOVER_PCT=20
USE_PSI=0
NOTIFY=1
RESTART_CONTAINER=0
```

`USE_PSI=1` additionally warns on memory `some avg10 >=20%`. Memory `full avg10 >=10%` can signal critical only when MemAvailable is also <=15%. Missing PSI falls back to MemAvailable. These are starting thresholds to tune, not universal recommendations.

## Optional Docker-only recovery

The delivered mode only logs and alerts. To enable a recovery attempt later:

```bash
RESTART_CONTAINER=1
TARGET_CONTAINER=""                # largest eligible running container
EXCLUDE_CONTAINERS=""              # exact names separated by spaces
CONTAINER_MIN_KIB=2097152           # at least 2 GiB anonymous cgroup memory
```

Set `TARGET_CONTAINER="YOUR-CONTAINER"` to restrict action to one exact case-sensitive container name. Empty means select the largest eligible container. Exclusions always apply. The 2 GiB action guard is an absolute setting: review it on smaller or larger hosts. Containers below it are never restarted, even if the host is critically low on memory.

Recovery requires critical pressure observed for 60 seconds and rechecked after diagnostic collection. The scan considers up to 128 running containers and ranks their anonymous cgroup memory, supporting conventional cgroup v1 memory and cgroup v2 layouts. It rechecks the selected container's immutable ID, PID and memory before acting. Unknown/unreadable accounting skips that container; cached files alone do not qualify. The largest consumer is not proof of the actual culprit, especially when a VM or host process caused the pressure.

Only **one restart attempt per host boot**, across all containers, is allowed. It uses the selected immutable container ID with `docker restart --time 10`, an outer 30-second timeout and two-second kill grace. Docker can force-kill the container after ten seconds. A timeout or failed attempt consumes the allowance and generates an Alert; the Docker daemon may still complete a request after the client times out, so inspect actual container state. It never deletes or recreates containers and never kills host processes or VMs. No host reboot, array stop, cache drop, swap change or global process kill is implemented.

The marker `/run/unraid-memory-watchdog/container-restart-attempted` is written before the attempt. Preserve it across watchdog restarts. It clears at host reboot; do not remove it casually to force retries. The capture records the pre-recovery state. Restart outcome is recorded in the RAM service log and sent as an Alert. Recovery is independent of whether flash capture was permitted.

## Validate safely

Copy the project into `/tmp/watchdog-tests`, preserving the `tests` subdirectory, then run as root:

```bash
bash /tmp/watchdog-tests/tests/test-watchdog.sh
```

The tests mock pressure, Docker and notifications, and replace flash paths with temporary directories. They also start/stop their own idle test daemon. They do not allocate pressure-generating RAM, restart real containers, send real notifications or write to `/boot`. They do not simulate a real kernel hang or flash-device failure.

Manual RAM-only diagnostics sample (no flash write, notification or recovery):

```bash
bash -c 'source /run/unraid-memory-watchdog/watchdog.sh; metrics || exit 1; action=manual-ram-only; collect manual > /tmp/unraid-watchdog-preview.txt'
wc -c /tmp/unraid-watchdog-preview.txt
```

Inspect reports before sharing: kernel/syslog output can contain private addresses and paths. Keep flash log shares private.

## Stop and update

Read the PID and verify its command first:

```bash
p=$(cat /run/unraid-memory-watchdog/pid)
ps -p "$p" -o pid,args
```

When it shows the watchdog Bash command, run `kill "$p"` and wait for the PID file to disappear. In-progress bounded collection can delay exit; uninterruptible kernel I/O cannot be guaranteed to stop. Run the launcher again to load the new script. Preserve the runtime directory and markers during updates. To disable permanently, disable the User Scripts schedule or remove only your launcher invocation from go, then stop the verified process.

## References

[Kernel PSI documentation](https://docs.kernel.org/accounting/psi.html), [Docker restart behavior](https://docs.docker.com/reference/cli/docker/container/restart/), [Unraid notifications](https://docs.unraid.net/unraid-os/getting-started/set-up-unraid/customize-unraid-settings/), [Unraid boot startup](https://docs.unraid.net/unraid-os/troubleshooting/common-issues/boot-and-startup-failures/).
