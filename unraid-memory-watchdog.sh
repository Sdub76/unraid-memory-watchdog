#!/bin/bash
# Unraid host memory watchdog. Bash 4+, GNU timeout/coreutils, util-linux flock/findmnt.
# No configuration is sourced. Edit these constants in the saved script.
INTERVAL=30
WARN_PCT=15
CRIT_PCT=5
RECOVER_PCT=20
WARN_SECONDS=60
CRIT_SECONDS=60
RECOVER_SECONDS=120
USE_PSI=0
PSI_SOME=20                    # avg10 percent; warning only
PSI_FULL=10                    # critical only when available <= WARN_PCT
RESTART_CONTAINER=0                    # opt in only after diagnostics-only observation
TARGET_CONTAINER=""            # empty = largest eligible running container; or exact name
EXCLUDE_CONTAINERS=""           # space-separated exact container names
NOTIFY=1                      # Unraid configured notification channels
NOTIFY_CMD=/usr/local/emhttp/webGui/scripts/notify
CONTAINER_MIN_KIB=2097152           # require >=2 GiB anonymous cgroup memory
DEST=/boot/logs/unraid-memory-watchdog
RUN=/run/unraid-memory-watchdog
WARN_COOLDOWN=21600
CRIT_COOLDOWN=3600
DAILY_MAX=4
KEEP=12
SECTION_BYTES=65536

mono() { local t rest; read -r t rest < /proc/uptime; printf '%s\n' "${t%%.*}"; }
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Missing/invalid metrics reset all streaks; never infer pressure from MemFree.
metrics() {
    local k v unit
    total=0 available=-1 some=0 full=0
    while read -r k v unit; do
        case "$k" in MemTotal:) total=$v;; MemAvailable:) available=$v;; esac
    done < /proc/meminfo
    [[ $total =~ ^[0-9]+$ && $available =~ ^[0-9]+$ ]] || return 1
    (( total > 0 && available <= total )) || return 1
    if (( USE_PSI )) && [[ -r /proc/pressure/memory ]]; then
        read -r some full < <(awk '
          $1=="some" {split($2,a,"="); s=int(a[2])}
          $1=="full" {split($2,a,"="); f=int(a[2])}
          END {print s+0,f+0}' /proc/pressure/memory)
    fi
}

reset_streaks() { warn_since=-1; crit_since=-1; recover_since=-1; }
classify() {
    warning=0 critical=0 recovered=0
    (( available*100 <= total*WARN_PCT )) && warning=1
    (( available*100 <= total*CRIT_PCT )) && critical=1
    if (( USE_PSI )); then
        (( some >= PSI_SOME )) && warning=1
        (( full >= PSI_FULL && available*100 <= total*WARN_PCT )) && critical=1
    fi
    (( critical )) && warning=1
    if (( available*100 >= total*RECOVER_PCT )); then
        if (( ! USE_PSI || (some < PSI_SOME && full < PSI_FULL) )); then recovered=1; fi
    fi
}
advance() {
    if (( warning )); then (( warn_since < 0 )) && warn_since=$now; else warn_since=-1; fi
    if (( critical )); then (( crit_since < 0 )) && crit_since=$now; else crit_since=-1; fi
    if (( recovered )); then
        (( recover_since < 0 )) && recover_since=$now
        if (( now-recover_since >= RECOVER_SECONDS )); then warned=0; critted=0; acted=0; fi
    else recover_since=-1; fi
    return 0
}

# Persistent filenames are also the rate-limit ledger, including incomplete writes.
# Future timestamps block captures until the clock catches up. Never prune first.
budget() {
    local level=$1 epoch=$2 f stamp kind n=0 last=0 cooldown=$WARN_COOLDOWN
    (( level == 2 )) && cooldown=$CRIT_COOLDOWN
    shopt -s nullglob
    for f in "$DEST"/event-*-*.log; do
        stamp=${f##*/event-}; stamp=${stamp%%-*}
        kind=${f##*-}; kind=${kind%.log}
        [[ $stamp =~ ^[0-9]{10}$ && $kind =~ ^[12]$ ]] || continue
        (( stamp > epoch )) && return 1
        (( epoch-stamp < 86400 )) && ((n+=1))
        if [[ $kind == "$level" ]] && (( stamp > last )); then last=$stamp; fi
    done
    (( n < DAILY_MAX && (last == 0 || epoch-last >= cooldown) ))
}

# Check the actual flash mount, not a fallback directory on the RAM rootfs.
flash_ready() {
    [[ ! -L /boot && ! -L /boot/logs && ! -L $DEST ]] || return 1
    [[ $(findmnt -rn -T /boot -o TARGET) == /boot ]] || return 1
    mkdir -p "$DEST" || return 1
    [[ $(findmnt -rn -T "$DEST" -o TARGET) == /boot ]] || return 1
    local free
    free=$(df -Pk "$DEST" | awk 'END {print $4}')
    [[ $free =~ ^[0-9]+$ ]] && (( free >= 65536 ))
}

# All command output and runtime are bounded. No full Unraid diagnostics ZIP,
# inspect environment, process arguments, stack dumps, compression or cache drop.
section() {
    local title=$1; shift
    printf '\n--- %s (max %s bytes, 3 seconds) ---\n' "$title" "$SECTION_BYTES"
    timeout -k 1 3 "$@" 2>&1 | head -c "$SECTION_BYTES"
    printf '\n'
}
collect() {
    local flush_target=${2:-}
    note "host=$(hostname) level=$1 total_kib=$total available_kib=$available psi_some=$some psi_full=$full action=$action"
    section meminfo cat /proc/meminfo
    section dmesg bash -c 'dmesg | tail -c 65536'
    section syslog tail -c "$SECTION_BYTES" /var/log/syslog
    if [[ -n $flush_target ]]; then
        timeout -k 1 3 sync "$flush_target" || note 'Early incident flush failed or timed out'
    fi
    section vmstat cat /proc/vmstat
    section pressure cat /proc/pressure/memory
    section uptime cat /proc/uptime /proc/loadavg
    section processes ps -eo pid,ppid,stat,rss,comm --sort=-rss
    section docker-stats docker stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.MemPerc}} {{.PIDs}}'
    note 'CAPTURE COMPLETE (sections may be truncated or timed out)'
}
notify_event() {
    (( NOTIFY )) && [[ -x $NOTIFY_CMD ]] || return 0
    # Best effort; never let a broken notification agent hold the watchdog forever.
    timeout -k 1 5 "$NOTIFY_CMD" -e 'Unraid memory watchdog' -s "$(hostname): $1" -d "$2" -i alert > /dev/null 2>&1 || note 'Notification failed or timed out'
}
capture_alert_once() {
    local level=$1 reason=$2
    [[ ! -e $RUN/capture-alert-$level ]] || return 0
    : > "$RUN/capture-alert-$level" || return 0
    note "Capture unavailable: $reason"
    notify_event 'Memory pressure: capture unavailable' "level=$level available=${available}KiB; $reason. Check host and flash immediately."
}
capture() {
    local level=$1 epoch file f
    epoch=$(date +%s)
    [[ $epoch =~ ^[0-9]{10}$ ]] || return
    if ! flash_ready; then capture_alert_once "$level" 'Flash mount unavailable or less than 64 MiB free'; return; fi
    if ! budget "$level" "$epoch"; then capture_alert_once "$level" 'Persistent write budget/cooldown blocks a new report'; return; fi
    file="$DEST/event-$epoch-$level.log"
    # Reserve before collection so crashes/failures still consume the write budget.
    if ! (set -o noclobber; printf 'CAPTURE RESERVED / INCOMPLETE\n' > "$file") 2>/dev/null; then
        capture_alert_once "$level" 'Cannot reserve incident file'; return
    fi
    # Stream essential evidence first, directly into the reserved incident file.
    # If the host dies partway through, already-written sections remain useful.
    if collect "$level" "$file" >> "$file"; then
        timeout -k 1 3 sync "$file" || note 'Incident flush failed or timed out'
        notify_event 'Memory pressure report saved' "level=$level available=${available}KiB; $file (best-effort flush)"
    else
        notify_event 'Memory pressure capture incomplete' "Partial evidence may be in $file"
    fi
    local files=("$DEST"/event-??????????-[12].log)
    # Fixed-width epoch filenames sort chronologically in C locale.
    while (( ${#files[@]} > KEEP )); do
        f=${files[0]}; rm -f -- "$f" || break
        files=("${files[@]:1}")
    done
}

container_anon_kib() {
    local pid=$1 id controllers rel base value
    [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cgroup ]] || return 1
    while IFS=: read -r id controllers rel; do
        [[ $rel == /* && $rel != *..* ]] || continue
        if [[ $id == 0 && -z $controllers ]]; then
            base=/sys/fs/cgroup$rel
            value=$(awk '$1=="anon" {print int($2/1024)}' "$base/memory.stat" 2>/dev/null)
        elif [[ ,$controllers, == *,memory,* ]]; then
            base=/sys/fs/cgroup/memory$rel
            value=$(awk '$1=="total_rss" {print int($2/1024)}' "$base/memory.stat" 2>/dev/null)
        else continue; fi
        [[ $value =~ ^[0-9]+$ ]] || return 1
        printf '%s\n' "$value"; return 0
    done < "/proc/$pid/cgroup"
    return 1
}
select_candidate() {
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
        excluded=0
        for x in $EXCLUDE_CONTAINERS; do [[ $name == "$x" ]] && excluded=1; done
        (( excluded )) && continue
        used=$(container_anon_kib "$pid") || continue
        if (( used >= CONTAINER_MIN_KIB && used > best )); then
            best=$used; candidate_kib=$used; candidate_id=$cid; candidate_name=$name; candidate_pid=$pid
        fi
    done <<< "$rows"
    [[ -n $candidate_id ]]
}
maybe_restart() {
    local current used
    action=disabled
    (( RESTART_CONTAINER )) || return
    action=already-attempted
    [[ ! -e $RUN/container-restart-attempted ]] || return
    action=no-eligible-container
    select_candidate || return
    # Recheck the same ID/PID and memory before acting, avoiding name reuse.
    current=$(timeout -k 1 3 docker inspect --format '{{.State.Running}} {{.State.Pid}}' "$candidate_id") || return
    [[ $current == "true $candidate_pid" ]] || return
    used=$(container_anon_kib "$candidate_pid") || return
    (( used >= CONTAINER_MIN_KIB )) || return
    # Once per boot, including failure: never loop restart an unhealthy service.
    : > "$RUN/container-restart-attempted" || return
    action="restart-failed-or-timed-out:$candidate_name:anon-${used}KiB"
    if timeout -k 2 30 docker restart --time 10 "$candidate_id" > /dev/null 2>&1; then
        action="restarted:$candidate_name:anon-${used}KiB"
    fi
    note "$action"
    notify_event 'Container memory recovery attempted' "$action; only one attempt allowed per boot. Check container state and host pressure."
}

tick() {
    now=$(mono)
    # A long scheduling gap is not proof of continuously observed pressure.
    if (( previous >= 0 && now-previous > INTERVAL*3 )); then reset_streaks; fi
    previous=$now
    if ! metrics; then reset_streaks; return; fi
    classify; advance
    action=none
    if (( critical && ! critted )); then
        # Capture first critical observation immediately, before optional recovery.
        critted=1; warned=1
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
    export LC_ALL=C
    umask 077
    [[ $EUID == 0 ]] || { echo 'Run as root.' >&2; return 1; }
    local dep
    for dep in hostname timeout flock findmnt awk head date df sync ps tail dmesg; do
        command -v "$dep" >/dev/null || { echo "Missing: $dep" >&2; return 1; }
    done
    [[ -z $TARGET_CONTAINER || $TARGET_CONTAINER =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { echo 'Invalid TARGET_CONTAINER.' >&2; return 1; }
    local key
    for key in INTERVAL WARN_PCT CRIT_PCT RECOVER_PCT WARN_SECONDS CRIT_SECONDS RECOVER_SECONDS USE_PSI PSI_SOME PSI_FULL RESTART_CONTAINER CONTAINER_MIN_KIB NOTIFY WARN_COOLDOWN CRIT_COOLDOWN DAILY_MAX KEEP SECTION_BYTES; do
        [[ ${!key} =~ ^(0|[1-9][0-9]{0,8})$ ]] || { echo "Invalid setting: $key" >&2; return 1; }
    done
    (( INTERVAL >= 5 && CRIT_PCT > 0 && CRIT_PCT < WARN_PCT && WARN_PCT < RECOVER_PCT && RECOVER_PCT <= 100 && WARN_SECONDS >= INTERVAL && CRIT_SECONDS >= INTERVAL && RECOVER_SECONDS >= INTERVAL && USE_PSI <= 1 && RESTART_CONTAINER <= 1 && NOTIFY <= 1 && PSI_SOME > 0 && PSI_FULL > 0 && PSI_SOME <= 100 && PSI_FULL <= 100 && CONTAINER_MIN_KIB > 0 && CRIT_COOLDOWN >= 3600 && WARN_COOLDOWN >= 3600 && DAILY_MAX > 0 && DAILY_MAX <= 4 && KEEP >= DAILY_MAX && KEEP <= 12 && SECTION_BYTES > 0 && SECTION_BYTES <= 65536 )) || { echo 'Invalid thresholds or safety limits.' >&2; return 1; }
    [[ ! -L $RUN ]] || return 1
    mkdir -p "$RUN" || return 1
    exec 9>"$RUN/lock"
    flock -n 9 || { echo 'Watchdog already running.'; return 0; }
    printf '%s\n' "$$" > "$RUN/pid"
    trap 'rm -f "$RUN/pid" "$RUN/capture.tmp"; exit 0' TERM INT
    reset_streaks; warned=0; critted=0; acted=0; previous=-1
    note "Watchdog started; restart_container=$RESTART_CONTAINER psi=$USE_PSI"
    while :; do tick; sleep "$INTERVAL" 9>&- & wait "$!"; done
}

# Sourcing defines functions only, allowing deterministic tests with mock metrics.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
