#!/bin/bash
# Unraid host memory watchdog. Bash 4+, GNU timeout/coreutils, util-linux flock/findmnt.
# Settings below are fallback defaults. Put per-server changes in the accompanying
# unraid-memory-watchdog.conf file. It is parsed as data, never executed as shell code.
#
# Reading this script:
#   1. Settings below describe when to collect evidence and whether to recover.
#   2. Functions read memory, write reports, send Alerts, and optionally restart.
#   3. main() checks the setup and calls tick() repeatedly until stopped.
# A function is a named block of work. Defining one does not run it immediately.
# In Bash, a command returns 0 for success and a nonzero number for failure.
# "&&" means "only if the previous step succeeded"; "||" handles failure.
# Values from /proc are live kernel readings, not files saved on the flash drive.

# How many seconds to wait between checks. Report collection adds its own time.
INTERVAL=30
# Percent of host RAM still available, including memory Linux can reclaim.
# A lower available percentage means more pressure. Cached RAM is not all lost.
WARN_PCT=15
CRIT_PCT=5
# Require more headroom before considering the incident over, to avoid flapping.
RECOVER_PCT=20
# Warning waits this long. Critical REPORTS start on the first critical sample;
# CRIT_SECONDS delays only the optional container recovery attempt.
WARN_SECONDS=60
CRIT_SECONDS=60
# Memory must stay recovered this long before another episode can be reported.
RECOVER_SECONDS=120
# 0 disables the extra stall signal; 1 reads it when the kernel provides it.
# PSI measures time tasks spend waiting for memory, rather than RAM usage.
USE_PSI=0
# These percentages describe the last ten seconds. "some" means at least one
# task was stalled; "full" means all non-idle tasks were stalled together.
PSI_SOME=20                    # avg10 percent; warning only
PSI_FULL=10                    # critical only when available <= WARN_PCT
# Leave recovery off for evidence collection and Alerts without service changes.
RESTART_CONTAINER=0                    # opt in only after diagnostics-only observation
# A blank target allows selection; a supplied name restricts recovery to that one.
TARGET_CONTAINER=""            # empty = largest eligible running container; or exact name
EXCLUDE_CONTAINERS=""           # space-separated exact container names
# Alerts use destinations already configured in Unraid, not credentials here.
NOTIFY=1                      # Unraid configured notification channels
NOTIFY_CMD=/usr/local/emhttp/webGui/scripts/notify
# Optional recovery needs substantial application memory, excluding file cache.
# KiB means 1024 bytes; 2,097,152 KiB is 2 GiB. This is not a host percentage.
CONTAINER_MIN_KIB=2097152           # require >=2 GiB anonymous cgroup memory
# DEST survives a host reboot. RUN is RAM-based and disappears at reboot.
DEST=/boot/logs/unraid-memory-watchdog
RUN=/run/unraid-memory-watchdog
# Cooldowns are seconds: six hours for warnings and one hour for critical reports.
# They are separate, so a recent warning does not block critical escalation.
WARN_COOLDOWN=21600
CRIT_COOLDOWN=3600
# Both severities share the daily allowance. KEEP limits stored report count.
DAILY_MAX=4
KEEP=12
# Maximum bytes from each diagnostic command: 64 KiB, even if it is very noisy.
SECTION_BYTES=65536

# Read a small, optional settings file once at startup. Blank lines and # comments
# are allowed. Values may have matching single/double quotes, but substitutions,
# commands, escape sequences and variable expansion are never evaluated.
# Only this allowlist can be changed; runtime paths and command paths stay fixed.
load_config() {
    local config=$1 line key value lineno=0 size
    [[ -e $config ]] || return 0
    [[ -f $config && -r $config ]] || { echo 'Settings file is not readable.' >&2; return 1; }
    size=$(wc -c < "$config") || return 1
    (( size <= 16384 )) || { echo 'Settings file is larger than 16 KiB.' >&2; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        ((lineno+=1))
        line=${line%$'\r'}
        # Remove inline comments and surrounding whitespace without running a command.
        line=${line%%#*}
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n $line ]] || continue
        [[ $line == *=* ]] || { echo "Settings line $lineno needs NAME=value." >&2; return 1; }
        key=${line%%=*}; value=${line#*=}
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        if [[ $value == \"*\" || $value == \'*\' ]]; then value=${value:1:${#value}-2}; fi
        case "$key" in
            TARGET_CONTAINER)
                [[ -z $value || $value =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || return 1;;
            EXCLUDE_CONTAINERS)
                [[ $value =~ ^[a-zA-Z0-9_.[:space:]-]*$ ]] || return 1;;
            INTERVAL|WARN_PCT|CRIT_PCT|RECOVER_PCT|WARN_SECONDS|CRIT_SECONDS|RECOVER_SECONDS|USE_PSI|PSI_SOME|PSI_FULL|RESTART_CONTAINER|NOTIFY|CONTAINER_MIN_KIB|WARN_COOLDOWN|CRIT_COOLDOWN|DAILY_MAX|KEEP|SECTION_BYTES)
                [[ $value =~ ^(0|[1-9][0-9]{0,8})$ ]] || { echo "Invalid number on settings line $lineno." >&2; return 1; };;
            *) echo "Unknown setting on line $lineno: $key" >&2; return 1;;
        esac
        # printf -v assigns the literal value to an approved variable; unlike source
        # or eval, it cannot turn a value into an executable shell instruction.
        printf -v "$key" '%s' "$value"
    done < "$config"
}

# Use whole seconds since boot for durations. Setting the wall clock cannot make
# a pressure streak suddenly appear longer. "rest" discards the unused field.
mono() { local t rest; read -r t rest < /proc/uptime; printf '%s\n' "${t%%.*}"; }
# Human-readable messages use UTC, so reports from multiple hosts can be compared.
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Missing/invalid metrics reset all streaks; never infer pressure from MemFree.
# Results are shared variables used by classify(), reports, and recovery checks.
metrics() {
    local k v unit
# Start with an impossible available value so a missing field cannot look valid.
    total=0 available=-1 some=0 full=0
    while read -r k v unit; do
        case "$k" in MemTotal:) total=$v;; MemAvailable:) available=$v;; esac
    done < /proc/meminfo
# Reject missing, nonnumeric or impossible readings instead of guessing.
    [[ $total =~ ^[0-9]+$ && $available =~ ^[0-9]+$ ]] || return 1
    (( total > 0 && available <= total )) || return 1
    if (( USE_PSI )) && [[ -r /proc/pressure/memory ]]; then
# awk extracts avg10 and rounds down to whole percent for the integer settings.
# If the kernel has no PSI file, the zero defaults leave MemAvailable in charge.
        read -r some full < <(awk '
          $1=="some" {split($2,a,"="); s=int(a[2])}
          $1=="full" {split($2,a,"="); f=int(a[2])}
          END {print s+0,f+0}' /proc/pressure/memory)
    fi
}

# -1 means "this condition has not started." Zero is a valid time since boot.
reset_streaks() { warn_since=-1; crit_since=-1; recover_since=-1; }
# Turn the latest readings into yes/no flags. This does not save or restart anything.
classify() {
    warning=0 critical=0 recovered=0
    (( available*100 <= total*WARN_PCT )) && warning=1
    (( available*100 <= total*CRIT_PCT )) && critical=1
# Multiply before comparing to avoid losing precision by dividing into whole percent.
    if (( USE_PSI )); then
        (( some >= PSI_SOME )) && warning=1
# Severe stalls alone may warn; PSI-based critical also requires low available RAM.
        (( full >= PSI_FULL && available*100 <= total*WARN_PCT )) && critical=1
    fi
    (( critical )) && warning=1
# Recovery uses a higher memory threshold and, when enabled, quieter PSI readings.
    if (( available*100 >= total*RECOVER_PCT )); then
        if (( ! USE_PSI || (some < PSI_SOME && full < PSI_FULL) )); then recovered=1; fi
    fi
}
# Track when each condition began. An interrupted condition loses its timer.
advance() {
    if (( warning )); then (( warn_since < 0 )) && warn_since=$now; else warn_since=-1; fi
    if (( critical )); then (( crit_since < 0 )) && crit_since=$now; else crit_since=-1; fi
    if (( recovered )); then
        (( recover_since < 0 )) && recover_since=$now
# These flags mean an episode already attempted a warning, critical capture, or
# recovery decision. Reset them only after sustained recovery, not on each poll.
        if (( now-recover_since >= RECOVER_SECONDS )); then warned=0; critted=0; acted=0; fi
    else recover_since=-1; fi
    return 0
}

# Persistent filenames are also the rate-limit ledger, including incomplete writes.
# Future timestamps block captures until the clock catches up. Never prune first.
budget() {
# level 1 is warning; level 2 is critical. epoch is wall-clock seconds since 1970.
# Wall-clock timestamps in filenames let the allowance survive process/host restarts.
    local level=$1 epoch=$2 f stamp kind n=0 last=0 cooldown=$WARN_COOLDOWN
    (( level == 2 )) && cooldown=$CRIT_COOLDOWN
    shopt -s nullglob
# nullglob makes an empty report directory yield no matches, rather than a fake name.
    for f in "$DEST"/event-*-*.log; do
        stamp=${f##*/event-}; stamp=${stamp%%-*}
        kind=${f##*-}; kind=${kind%.log}
# Pull the timestamp and severity out of event-TIMESTAMP-LEVEL.log; ignore other files.
        [[ $stamp =~ ^[0-9]{10}$ && $kind =~ ^[12]$ ]] || continue
        (( stamp > epoch )) && return 1
# Count all reports from the last 86,400 seconds, including incomplete reservations.
        (( epoch-stamp < 86400 )) && ((n+=1))
        if [[ $kind == "$level" ]] && (( stamp > last )); then last=$stamp; fi
    done
# A report needs both a daily slot and enough time since its own severity's last one.
    (( n < DAILY_MAX && (last == 0 || epoch-last >= cooldown) ))
}

# Check the actual flash mount, not a fallback directory on the RAM rootfs.
flash_ready() {
# Refuse symbolic links at these paths so evidence is not redirected unexpectedly.
    [[ ! -L /boot && ! -L /boot/logs && ! -L $DEST ]] || return 1
    [[ $(findmnt -rn -T /boot -o TARGET) == /boot ]] || return 1
# Only make the destination after confirming that /boot really is mounted.
    mkdir -p "$DEST" || return 1
    [[ $(findmnt -rn -T "$DEST" -o TARGET) == /boot ]] || return 1
    local free
    free=$(df -Pk "$DEST" | awk 'END {print $4}')
# Leave at least 64 MiB free; the watchdog should not fill the boot device.
    [[ $free =~ ^[0-9]+$ ]] && (( free >= 65536 ))
}

# All command output and runtime are bounded. No full Unraid diagnostics ZIP,
# inspect environment, process arguments, stack dumps, compression or cache drop.
section() {
# The first argument is a heading. shift leaves the actual command and its arguments.
    local title=$1; shift
    printf '\n--- %s (max %s bytes, 3 seconds) ---\n' "$title" "$SECTION_BYTES"
    timeout -k 1 3 "$@" 2>&1 | head -c "$SECTION_BYTES"
# timeout asks the command to stop after three seconds, then forces it after one
# more second. head limits bytes. 2>&1 puts errors in the same section as output.
# Kernel operations stuck in uninterruptible I/O can still outlast these timeouts.
    printf '\n'
}
collect() {
# An optional second argument names the incident file to flush. Manual RAM-only
# samples omit it, so they do not perform incident-file flushes or send Alerts.
    local flush_target=${2:-}
    note "host=$(hostname) level=$1 total_kib=$total available_kib=$available psi_some=$some psi_full=$full action=$action"
    section meminfo cat /proc/meminfo
    section dmesg bash -c 'dmesg | tail -c 65536'
    section syslog tail -c "$SECTION_BYTES" /var/log/syslog
# Write the most useful evidence before slower process/Docker checks. A flush here
# gives those early sections a chance to survive if the rest of collection fails.
    if [[ -n $flush_target ]]; then
        timeout -k 1 3 sync "$flush_target" || note 'Early incident flush failed or timed out'
    fi
    section vmstat cat /proc/vmstat
# Additional context: memory activity counters, stalls, load, and biggest processes.
# ps includes command names but deliberately omits potentially private arguments.
    section pressure cat /proc/pressure/memory
    section uptime cat /proc/uptime /proc/loadavg
    section processes ps -eo pid,ppid,stat,rss,comm --sort=-rss
    section docker-stats docker stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.MemPerc}} {{.PIDs}}'
# This footer means collection reached the end, not that every command succeeded.
    note 'CAPTURE COMPLETE (sections may be truncated or timed out)'
}
notify_event() {
# Disabled or missing notification tooling must not break evidence collection.
    (( NOTIFY )) && [[ -x $NOTIFY_CMD ]] || return 0
    # Best effort; never let a broken notification agent hold the watchdog forever.
    timeout -k 1 5 "$NOTIFY_CMD" -e 'Unraid memory watchdog' -s "$(hostname): $1" -d "$2" -i alert > /dev/null 2>&1 || note 'Notification failed or timed out'
}
capture_alert_once() {
# If capture is blocked, still tell the operator. One RAM marker per severity
# prevents repeated failures from generating unlimited Alerts during this boot.
    local level=$1 reason=$2
    [[ ! -e $RUN/capture-alert-$level ]] || return 0
    : > "$RUN/capture-alert-$level" || return 0
# ":" does no work; redirecting it with ">" creates an empty marker file.
    note "Capture unavailable: $reason"
    notify_event 'Memory pressure: capture unavailable' "level=$level available=${available}KiB; $reason. Check host and flash immediately."
}
capture() {
# Capture is the only routine that creates incident reports on the boot device.
# Preflight and budget failures produce bounded Alerts instead of repeated writes.
    local level=$1 epoch file f
    epoch=$(date +%s)
    [[ $epoch =~ ^[0-9]{10}$ ]] || return
    if ! flash_ready; then capture_alert_once "$level" 'Flash mount unavailable or less than 64 MiB free'; return; fi
    if ! budget "$level" "$epoch"; then capture_alert_once "$level" 'Persistent write budget/cooldown blocks a new report'; return; fi
    file="$DEST/event-$epoch-$level.log"
    # Reserve before collection so crashes/failures still consume the write budget.
    if ! (set -o noclobber; printf 'CAPTURE RESERVED / INCOMPLETE\n' > "$file") 2>/dev/null; then
# noclobber refuses to overwrite an existing filename, including a same-second event.
        capture_alert_once "$level" 'Cannot reserve incident file'; return
    fi
    # Stream essential evidence first, directly into the reserved incident file.
    # If the host dies partway through, already-written sections remain useful.
    if collect "$level" "$file" >> "$file"; then
# ">>" appends as commands run. There is no large in-memory report waiting to copy.
# A successful return gets a final file flush and an Alert naming the saved path.
        timeout -k 1 3 sync "$file" || note 'Incident flush failed or timed out'
        notify_event 'Memory pressure report saved' "level=$level available=${available}KiB; $file (best-effort flush)"
    else
        notify_event 'Memory pressure capture incomplete' "Partial evidence may be in $file"
    fi
    local files=("$DEST"/event-??????????-[12].log)
    # Fixed-width epoch filenames sort chronologically in C locale.
    while (( ${#files[@]} > KEEP )); do
# Remove only the oldest matching incident file, then shorten the filename list.
# Pruning happens after collection so a denied capture cannot erase old evidence.
        f=${files[0]}; rm -f -- "$f" || break
        files=("${files[@]:1}")
    done
}

container_anon_kib() {
# A cgroup is Linux's memory-accounting group for a container. Start with its host
# process ID and find that group's memory.stat. Read application memory, not cache.
    local pid=$1 id controllers rel base value
    [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cgroup ]] || return 1
    while IFS=: read -r id controllers rel; do
        [[ $rel == /* && $rel != *..* ]] || continue
# Support the unified cgroup v2 layout and the older separate memory controller.
# Reject suspicious relative paths rather than reading outside the expected tree.
        if [[ $id == 0 && -z $controllers ]]; then
            base=/sys/fs/cgroup$rel
            value=$(awk '$1=="anon" {print int($2/1024)}' "$base/memory.stat" 2>/dev/null)
        elif [[ ,$controllers, == *,memory,* ]]; then
            base=/sys/fs/cgroup/memory$rel
            value=$(awk '$1=="total_rss" {print int($2/1024)}' "$base/memory.stat" 2>/dev/null)
        else continue; fi
        [[ $value =~ ^[0-9]+$ ]] || return 1
# Missing/unknown accounting fails closed: an unreadable container is never chosen.
        printf '%s\n' "$value"; return 0
    done < "/proc/$pid/cgroup"
    return 1
}
select_candidate() {
# Optional recovery scans running containers only, using one bounded batch inspect.
# The chosen ID, name, PID and memory count are shared with maybe_restart().
    local ids rows cid name pid used excluded x best=0
    candidate_id=; candidate_name=; candidate_pid=; candidate_kib=0
    # Docker-derived arguments must be IDs. Bound scan count, output and CLI time.
    ids=$(timeout -k 1 3 docker ps -q --no-trunc | head -c 16384)
    local valid_ids=()
    while read -r cid; do
        [[ $cid =~ ^[a-f0-9]{64}$ ]] && valid_ids+=("$cid")
        (( ${#valid_ids[@]} >= 128 )) && break
    done <<< "$ids"
    (( ${#valid_ids[@]} )) || return 1
    rows=$(timeout -k 1 3 docker inspect --format '{{.Id}} {{.Name}} {{.State.Pid}}' "${valid_ids[@]}" | head -c 32768)
    while read -r cid name pid; do
        name=${name#/}
        [[ $cid =~ ^[a-f0-9]{64}$ && $name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ && $pid =~ ^[1-9][0-9]*$ ]] || continue
        [[ -z $TARGET_CONTAINER || $name == "$TARGET_CONTAINER" ]] || continue
# Apply exact target and exclusion choices before checking each container's memory.
        excluded=0
        for x in $EXCLUDE_CONTAINERS; do [[ $name == "$x" ]] && excluded=1; done
        (( excluded )) && continue
        used=$(container_anon_kib "$pid") || continue
        if (( used >= CONTAINER_MIN_KIB && used > best )); then
# Keep the largest qualifying application-memory consumer, not simply the first one.
            best=$used; candidate_kib=$used; candidate_id=$cid; candidate_name=$name; candidate_pid=$pid
        fi
    done <<< "$rows"
    [[ -n $candidate_id ]]
}
maybe_restart() {
# This path is optional and disabled by default. Even when enabled, it cannot
# terminate a host process, shut down a VM, or reboot the server.
    local current used
    action=disabled
    (( RESTART_CONTAINER )) || return
    action=already-attempted
    [[ ! -e $RUN/container-restart-attempted ]] || return
# This marker survives watchdog relaunches within the boot, unlike episode flags.
    action=no-eligible-container
    select_candidate || return
    # Recheck the same ID/PID and memory before acting, avoiding name reuse.
    current=$(timeout -k 1 3 docker inspect --format '{{.State.Running}} {{.State.Pid}}' "$candidate_id") || return
    [[ $current == "true $candidate_pid" ]] || return
    used=$(container_anon_kib "$candidate_pid") || return
    (( used >= CONTAINER_MIN_KIB )) || return
    # Once per boot, including failure: never loop restart an unhealthy service.
    : > "$RUN/container-restart-attempted" || return
# Reserve the single attempt BEFORE contacting Docker. Failure also uses it up.
    action="restart-failed-or-timed-out:$candidate_name:anon-${used}KiB"
    if timeout -k 2 30 docker restart --time 10 "$candidate_id" > /dev/null 2>&1; then
# Docker allows ten seconds for graceful shutdown, then may force-kill the container.
# The outer timeout limits how long we wait for Docker; a timed-out request may
# still finish in the daemon. Always use the immutable ID, not a reusable name.
        action="restarted:$candidate_name:anon-${used}KiB"
    fi
    note "$action"
    notify_event 'Container memory recovery attempted' "$action; only one attempt allowed per boot. Check container state and host pressure."
}

tick() {
# One monitoring cycle: sample, update timers, capture evidence, then consider recovery.
    now=$(mono)
    # A long scheduling gap is not proof of continuously observed pressure.
    if (( previous >= 0 && now-previous > INTERVAL*3 )); then reset_streaks; fi
    previous=$now
    if ! metrics; then reset_streaks; return; fi
# A missing sample is not proof that low memory continued while we were unable to read.
    classify; advance
    action=none
    if (( critical && ! critted )); then
        # Capture first critical observation immediately, before optional recovery.
        critted=1; warned=1
# Mark the attempt even if flash/budget blocks it. Sustained pressure must not spam
# the flash drive; another episode requires a real recovery period first.
        capture 2
    elif (( warn_since >= 0 && now-warn_since >= WARN_SECONDS && ! warned )); then
        warned=1
        capture 1
    fi
    if (( crit_since >= 0 && now-crit_since >= CRIT_SECONDS && ! acted )); then
        # Recheck live pressure after capture; never act on stale pre-capture metrics.
        if metrics; then
            classify
            if (( critical )); then acted=1; maybe_restart; fi
        fi
    fi
}

main() {
# Stable sorting/parsing, private newly created files, and required host privileges.
# On flash filesystems, effective access also depends on their mount/share settings.
    export LC_ALL=C
    umask 077
    [[ $EUID == 0 ]] || { echo 'Run as root.' >&2; return 1; }
# The normal launcher puts the settings beside this RAM copy. A caller may supply
# a different settings path as the single argument. An explicitly requested file
# must exist; the automatic adjacent file is optional and defaults remain usable.
    local config=${1:-$(dirname -- "${BASH_SOURCE[0]}")/unraid-memory-watchdog.conf}
    (( $# <= 1 )) || { echo 'Usage: bash unraid-memory-watchdog.sh [settings-file]' >&2; return 1; }
    if (( $# == 1 )) && [[ ! -f $config ]]; then echo 'Requested settings file is missing.' >&2; return 1; fi
    load_config "$config" || return 1
    local dep
    for dep in dirname wc hostname timeout flock findmnt awk head date df sync ps tail dmesg; do
# Docker and notify are intentionally absent from this required-tools list:
# monitoring still works when Docker is unavailable or notifications are disabled.
        command -v "$dep" >/dev/null || { echo "Missing: $dep" >&2; return 1; }
    done
    [[ -z $TARGET_CONTAINER || $TARGET_CONTAINER =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { echo 'Invalid TARGET_CONTAINER.' >&2; return 1; }
    local key
# Validate edited settings before starting. ${!key} reads the setting named by key.
# The numeric format rejects negative numbers, leading-zero forms and shell text.
    for key in INTERVAL WARN_PCT CRIT_PCT RECOVER_PCT WARN_SECONDS CRIT_SECONDS RECOVER_SECONDS USE_PSI PSI_SOME PSI_FULL RESTART_CONTAINER CONTAINER_MIN_KIB NOTIFY WARN_COOLDOWN CRIT_COOLDOWN DAILY_MAX KEEP SECTION_BYTES; do
        [[ ${!key} =~ ^(0|[1-9][0-9]{0,8})$ ]] || { echo "Invalid setting: $key" >&2; return 1; }
    done
    (( INTERVAL >= 5 && CRIT_PCT > 0 && CRIT_PCT < WARN_PCT && WARN_PCT < RECOVER_PCT && RECOVER_PCT <= 100 && WARN_SECONDS >= INTERVAL && CRIT_SECONDS >= INTERVAL && RECOVER_SECONDS >= INTERVAL && USE_PSI <= 1 && RESTART_CONTAINER <= 1 && NOTIFY <= 1 && PSI_SOME > 0 && PSI_FULL > 0 && PSI_SOME <= 100 && PSI_FULL <= 100 && CONTAINER_MIN_KIB > 0 && CRIT_COOLDOWN >= 3600 && WARN_COOLDOWN >= 3600 && DAILY_MAX > 0 && DAILY_MAX <= 4 && KEEP >= DAILY_MAX && KEEP <= 12 && SECTION_BYTES > 0 && SECTION_BYTES <= 65536 )) || { echo 'Invalid thresholds or safety limits.' >&2; return 1; }
# The long check enforces sensible threshold order and caps flash use. It refuses
# settings that would allow more than four reports/day or twelve retained reports.
    [[ ! -L $RUN ]] || return 1
    mkdir -p "$RUN" || return 1
    exec 9>"$RUN/lock"
# File handle 9 keeps the lock open for this process's lifetime. A second watchdog
# cannot acquire it and exits harmlessly. Creating/opening the file alone is no lock.
    flock -n 9 || { echo 'Watchdog already running.'; return 0; }
    printf '%s\n' "$$" > "$RUN/pid"
# $$ is this process's ID. The stop instructions use it after verifying the command.
    trap 'rm -f "$RUN/pid" "$RUN/capture.tmp"; exit 0' TERM INT
# A normal stop request removes transient files. Keep the lock file and all boot
# markers: deleting them could bypass duplicate-instance or one-attempt protection.
    reset_streaks; warned=0; critted=0; acted=0; previous=-1
    note "Watchdog started; restart_container=$RESTART_CONTAINER psi=$USE_PSI"
    while :; do tick; sleep "$INTERVAL" 9>&- & wait "$!"; done
# Sleep runs in the background so a stop signal can interrupt wait promptly.
# "9>&-" prevents the sleeping child from retaining our lock after the parent exits.
}

# Sourcing defines functions only, allowing deterministic tests with mock metrics.
# Running this file directly starts main(). Loading it with "source" only prepares
# settings and functions, which also supports the documented manual report command.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
