#!/bin/bash
# Safe deterministic tests: no live pressure, flash writes or Docker actions.
set -u
source "$(dirname "$0")/../unraid-memory-watchdog.sh"
NOTIFY=0
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
DEST=$T/events; RUN=$T/run
mkdir -p "$DEST" "$RUN"
passed=0
ok() { passed=$((passed+1)); printf 'PASS %s\n' "$1"; }
check() { if ! eval "$2"; then echo "FAIL $1: $2"; exit 1; fi; ok "$1"; }

total=10000; available=1600; some=0; full=0; USE_PSI=0
classify
check 'healthy cache is not pressure' '(( ! warning && ! critical ))'
available=1500; classify
check 'warning boundary inclusive' '(( warning && ! critical ))'
available=500; classify
check 'critical boundary inclusive' '(( critical && warning ))'
USE_PSI=1; available=5000; some=21; full=12; classify
check 'PSI alone warns but cannot stop container' '(( warning && ! critical ))'
available=1400; classify
check 'PSI critical requires low available memory' '(( critical ))'
USE_PSI=0; available=5000; classify
check 'PSI disabled is ignored' '(( ! warning && ! critical ))'

# Mock only inputs and effects; execute the real state machine.
fake_now=0; fake_available=100; valid=1; captures=; stops=0
mono() { echo "$fake_now"; }
metrics() { total=10000; available=$fake_available; some=0; full=0; (( valid )); }
capture() { captures+="$1"; }
maybe_restart() { stops=$((stops+1)); }
reset_streaks; warned=0; critted=0; acted=0; previous=-1
tick
fake_now=30; tick
check 'critical logs immediately but recovery waits' '[[ $captures == 2 ]] && (( stops == 0 ))'
fake_now=60; tick
check 'sustained critical captures and acts once' '[[ $captures == 2 ]] && (( stops == 1 ))'
fake_now=90; tick
check 'continuing critical does not flood' '[[ $captures == 2 ]] && (( stops == 1 ))'
fake_available=2500; fake_now=120; tick
fake_now=150; tick; fake_now=180; tick; fake_now=210; tick; fake_now=240; tick
check 'recovery rearms only after hysteresis duration' '(( ! critted && ! warned ))'
fake_available=1000; fake_now=270; tick; fake_now=300; tick; fake_now=330; tick
check 'warning captures after three samples' '[[ $captures == 21 ]]'
fake_available=100; fake_now=360; tick; fake_now=390; tick; fake_now=420; tick
check 'critical escalation follows warning' '[[ $captures == 212 ]]'
reset_streaks; warned=0; critted=0; acted=0; previous=-1; captures=; fake_available=1000
fake_now=0; tick; valid=0; fake_now=30; tick; valid=1; fake_now=60; tick
check 'invalid sample breaks streak' '[[ -z $captures ]]'
fake_now=300; tick
check 'long scheduling gap breaks streak' '[[ -z $captures ]]'

# Reload real functions, keeping tests confined to temporary paths.
source "$(dirname "$0")/../unraid-memory-watchdog.sh"
NOTIFY=0
DEST=$T/events; RUN=$T/run
touch "$DEST/event-1800000000-1.log"
check 'warning cooldown persists in ledger' '! budget 1 1800000100'
check 'warning does not consume critical cooldown' 'budget 2 1800000100'
touch "$DEST/event-1800000200-2.log"
check 'critical cooldown enforced' '! budget 2 1800000300'
touch "$DEST/event-1800000400-2.log" "$DEST/event-1800000600-2.log"
check 'rolling daily cap enforced' '! budget 2 1800040000'
check 'daily cap expires' 'budget 2 1800090000'
check 'backwards wall clock fails closed' '! budget 2 1799999999'

check 'recovery is disabled in delivered defaults' '(( RESTART_CONTAINER == 0 ))'
maybe_restart
check 'disabled recovery creates no marker' '[[ $action == disabled && ! -e $RUN/container-restart-attempted ]]'
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'MOCK'
#!/bin/bash
a=$(printf '%064d' 1); b=$(printf '%064d' 2)
case "$1" in
  ps) printf '%s\n%s\n' "$a" "$b";;
  inspect)
    if [[ $* == *State.Running* ]]; then
      printf 'true %s\n' "${MOCK_PID:-222}"
    else printf '%s /fixture-1 111\n%s /fixture-2 222\n' "$a" "$b"; fi;;
  restart) [[ $* == "restart --time 10 $b" && ${MOCK_FAIL:-0} == 0 ]];;
  *) exit 99;;
esac
MOCK
chmod +x "$T/bin/docker"
export PATH="$T/bin:$PATH"
RESTART_CONTAINER=1
container_anon_kib() { case "$1" in 111) echo 1000;; 222) echo 3000000;; esac; }
select_candidate
check 'auto selection chooses largest eligible container' '[[ $candidate_name == fixture-2 && $candidate_pid == 222 ]]'
EXCLUDE_CONTAINERS=fixture-2
select_candidate
check 'excluded container is never selected' '[[ -z $candidate_id ]]'
EXCLUDE_CONTAINERS=; TARGET_CONTAINER=fixture-1
select_candidate
check 'exact target does not fall back to another container' '[[ -z $candidate_id ]]'
TARGET_CONTAINER=
export MOCK_PID=999
maybe_restart
check 'changed PID prevents restart' '[[ ! -e $RUN/container-restart-attempted ]]'
unset MOCK_PID
container_anon_kib() { return 1; }
maybe_restart
check 'unreadable attribution fails closed' '[[ ! -e $RUN/container-restart-attempted ]]'
container_anon_kib() { case "$1" in 111) echo 1000;; 222) echo 3000000;; esac; }
maybe_restart
check 'large container receives bounded restart by ID' '[[ $action == restarted:* && -e $RUN/container-restart-attempted ]]'
maybe_restart
check 'restart marker survives daemon restart' '[[ $action == already-attempted ]]'
rm "$RUN/container-restart-attempted"
export MOCK_FAIL=1
maybe_restart
check 'failed restart also consumes boot allowance' '[[ $action == restart-failed* && -e $RUN/container-restart-attempted ]]'

# Notification command is a fixture, never Unraid's real notification service.
cat > "$T/bin/notify" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" > "$NOTIFY_TEST_LOG"
MOCK
chmod +x "$T/bin/notify"
export NOTIFY_TEST_LOG=$T/notification
NOTIFY_CMD=$T/bin/notify; NOTIFY=1
notify_event 'Test subject' 'Test description'
check 'notification includes event and severity' 'grep -q "Unraid memory watchdog" "$T/notification" && grep -q -- "-i alert" "$T/notification"'
NOTIFY=0

# Real timeout/output limiter; producers stay outside flash and never use Docker.
SECTION_BYTES=1024
section noisy bash -c 'yes x' > "$T/noisy"
check 'noisy command output bounded' '(( $(wc -c < "$T/noisy") < 1200 ))'
start=$SECONDS
section hung sleep 30 > "$T/hung"
check 'hung command returns within timeout allowance' '(( SECONDS-start <= 6 ))'

# Real collector/capture with fake flash check and deterministic section payload.
source "$(dirname "$0")/../unraid-memory-watchdog.sh"
NOTIFY=0
DEST=$T/captures; RUN=$T/run; mkdir -p "$DEST"
flash_ready() { return 0; }
section() { printf '%s\n' "$1"; head -c 65536 /dev/zero; }
total=10000; available=500; some=0; full=0; action=none
capture 2
files=("$DEST"/*.log)
check 'real capture reserves one bounded report' '(( ${#files[@]} == 1 && $(wc -c < "${files[0]}") < 530000 ))'
check 'report has completion footer' 'tail -c 200 "${files[0]}" | grep -aq "CAPTURE COMPLETE"'
capture 2
files=("$DEST"/*.log)
check 'repeat capture blocked by persistent cooldown' '(( ${#files[@]} == 1 ))'
for n in {1..12}; do touch "$DEST/event-17000000$(printf '%02d' "$n")-1.log"; done
# Existing report prevents capture and deletion: budget failures never prune evidence.
capture 2
files=("$DEST"/*.log)
check 'budget denial does not prune evidence' '(( ${#files[@]} == 13 ))'
rm "${files[@]}"
for n in {1..12}; do touch "$DEST/event-17000000$(printf '%02d' "$n")-1.log"; done
capture 2
files=("$DEST"/*.log)
check 'retention removes oldest after a new capture' '(( ${#files[@]} == 12 )) && [[ ! -e $DEST/event-1700000001-1.log ]]'

DEST=$T/partial; mkdir -p "$DEST"
collect() { printf 'EARLY EVIDENCE\n'; return 1; }
capture 2
files=("$DEST"/*.log)
check 'partial collection leaves early evidence in reserved file' 'grep -q "EARLY EVIDENCE" "${files[0]}" && ! grep -q "CAPTURE COMPLETE" "${files[0]}"'
check 'incomplete capture consumes write budget' '! budget 2 "$(date +%s)"'
flash_ready() { return 1; }
DEST=$T/unmounted
capture 2
check 'unavailable flash creates no fallback report' '[[ ! -e $DEST ]]'

# Real single-instance lock and clean termination, with monitoring disabled.
script_path=$(cd "$(dirname "$0")/.." && pwd)/unraid-memory-watchdog.sh
bash -c 'source "$1"; RUN=$2; tick() { :; }; main' _ "$script_path" "$T/daemon" > "$T/daemon.log" 2>&1 &
daemon_pid=$!
for n in {1..30}; do [[ -s $T/daemon/pid ]] && break; sleep 0.1; done
check 'daemon creates PID and holds exclusive lock' '[[ -s $T/daemon/pid ]] && ! flock -n "$T/daemon/lock" true'
bash -c 'source "$1"; RUN=$2; tick() { :; }; main' _ "$script_path" "$T/daemon" > "$T/duplicate.log" 2>&1
check 'duplicate instance exits without replacing PID' 'grep -q "already running" "$T/duplicate.log" && [[ $(cat "$T/daemon/pid") == "$daemon_pid" ]]'
kill "$daemon_pid"; wait "$daemon_pid"
check 'termination removes PID and releases lock' '[[ ! -e $T/daemon/pid ]] && flock -n "$T/daemon/lock" true'
bash -c 'source "$1"; RUN=$2; CRIT_PCT=50; main' _ "$script_path" "$T/bad" > "$T/bad.log" 2>&1
check 'invalid settings fail before daemon starts' '[[ ! -e $T/bad/pid ]] && grep -q "Invalid thresholds" "$T/bad.log"'
printf '\n%s tests passed. No live Docker or flash actions.\n' "$passed"
