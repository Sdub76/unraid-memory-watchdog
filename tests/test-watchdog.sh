#!/bin/bash
# Safe deterministic tests: no live pressure, flash writes or Docker actions.
# These tests exercise real watchdog decisions while substituting harmless inputs
# and commands. The invented container names/IDs below are test fixtures only.
# Run as root on Linux: the daemon lifecycle tests use the real startup checks.

# Treat an undefined variable as an error, helping catch mistakes in test setup.
# We deliberately do not use "set -e": many tests expect a function to refuse an
# operation. check() decides whether that refusal was the correct outcome.
set -u
# Load function definitions without starting the watchdog's endless main loop.
source "$(dirname "$0")/../unraid-memory-watchdog.sh"
# Never contact Unraid's notification system while testing.
NOTIFY=0
# mktemp creates a new, private scratch directory. Everything written by these tests
# stays below it, except normal reads of Linux's process and command information.
T=$(mktemp -d)
# Remove only this freshly created scratch tree when the test process exits.
trap 'rm -rf -- "$T"' EXIT
# Replace the production flash/RAM locations before calling report functions.
DEST=$T/events; RUN=$T/run
mkdir -p "$DEST" "$RUN"
passed=0
# Each check has a readable name and an assertion written here in this file.
# eval runs that fixed assertion; no downloaded text or user input is evaluated.
ok() { passed=$((passed+1)); printf 'PASS %s\n' "$1"; }
check() { if ! eval "$2"; then echo "FAIL $1: $2"; exit 1; fi; ok "$1"; }

# Use an invented total of 10,000 KiB so percentage boundaries are easy to follow.
# Check normal memory, exact warning/critical boundaries, and optional PSI rules.
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
# Replacing a Bash function with the same name redirects calls to our fake version.
# The clock advances by assignment instead of waiting minutes or exhausting RAM.
# captures stores severities (for example "21" = critical, then a later warning).
# stops counts calls to the recovery decision; it never runs Docker here.
fake_now=0; fake_available=100; valid=1; captures=; stops=0
mono() { echo "$fake_now"; }
metrics() { total=10000; available=$fake_available; some=0; full=0; (( valid )); }
capture() { captures+="$1"; }
maybe_restart() { stops=$((stops+1)); }
reset_streaks; warned=0; critted=0; acted=0; previous=-1
# At time zero, critical evidence should be requested immediately. Recovery waits
# until three low-memory observations span sixty seconds, then runs once only.
tick
fake_now=30; tick
check 'critical logs immediately but recovery waits' '[[ $captures == 2 ]] && (( stops == 0 ))'
fake_now=60; tick
check 'sustained critical captures and acts once' '[[ $captures == 2 ]] && (( stops == 1 ))'
fake_now=90; tick
check 'continuing critical does not flood' '[[ $captures == 2 ]] && (( stops == 1 ))'
fake_available=2500; fake_now=120; tick
# Hold memory above the recovery threshold for the full rearming period.
fake_now=150; tick; fake_now=180; tick; fake_now=210; tick; fake_now=240; tick
check 'recovery rearms only after hysteresis duration' '(( ! critted && ! warned ))'
fake_available=1000; fake_now=270; tick; fake_now=300; tick; fake_now=330; tick
# After recovery, a warning can start a fresh report and then escalate to critical.
check 'warning captures after three samples' '[[ $captures == 21 ]]'
fake_available=100; fake_now=360; tick; fake_now=390; tick; fake_now=420; tick
check 'critical escalation follows warning' '[[ $captures == 212 ]]'
reset_streaks; warned=0; critted=0; acted=0; previous=-1; captures=; fake_available=1000
# A bad reading or a long scheduling gap must break a warning streak instead of
# counting an unobserved interval as confirmed, continuous pressure.
fake_now=0; tick; valid=0; fake_now=30; tick; valid=1; fake_now=60; tick
check 'invalid sample breaks streak' '[[ -z $captures ]]'
fake_now=300; tick
check 'long scheduling gap breaks streak' '[[ -z $captures ]]'

# Reload real functions, keeping tests confined to temporary paths.
# This discards the fake clock/metrics/capture functions from the preceding tests.
source "$(dirname "$0")/../unraid-memory-watchdog.sh"
NOTIFY=0
DEST=$T/events; RUN=$T/run
touch "$DEST/event-1800000000-1.log"
# Empty files are enough to test the persistent allowance: timestamps and severity
# come from filenames, not report contents. All times here are invented constants.
check 'warning cooldown persists in ledger' '! budget 1 1800000100'
check 'warning does not consume critical cooldown' 'budget 2 1800000100'
touch "$DEST/event-1800000200-2.log"
check 'critical cooldown enforced' '! budget 2 1800000300'
touch "$DEST/event-1800000400-2.log" "$DEST/event-1800000600-2.log"
check 'rolling daily cap enforced' '! budget 2 1800040000'
check 'daily cap expires' 'budget 2 1800090000'
check 'backwards wall clock fails closed' '! budget 2 1799999999'

# First verify the shipped default cannot request any container restart.
check 'recovery is disabled in delivered defaults' '(( RESTART_CONTAINER == 0 ))'
maybe_restart
check 'disabled recovery creates no marker' '[[ $action == disabled && ! -e $RUN/container-restart-attempted ]]'
mkdir -p "$T/bin"
# Create a pretend docker executable before enabling recovery tests. timeout starts
# a separate program, so a real executable fixture is needed, not just a function.
# It returns two invented containers and refuses any unexpected Docker command.
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
# Put the fixture first in PATH so every tested Docker call reaches it, never the
# host Docker daemon. The parent shell and actual Docker installation are unchanged.
export PATH="$T/bin:$PATH"
RESTART_CONTAINER=1
# Invent application-memory counts: the second container qualifies; the first does not.
container_anon_kib() { case "$1" in 111) echo 1000;; 222) echo 3000000;; esac; }
select_candidate
check 'auto selection chooses largest eligible container' '[[ $candidate_name == fixture-2 && $candidate_pid == 222 ]]'
EXCLUDE_CONTAINERS=fixture-2
# Excluding the largest candidate must not make an undersized one qualify.
select_candidate
check 'excluded container is never selected' '[[ -z $candidate_id ]]'
EXCLUDE_CONTAINERS=; TARGET_CONTAINER=fixture-1
# An exact target prevents choosing another container even when it is larger.
select_candidate
check 'exact target does not fall back to another container' '[[ -z $candidate_id ]]'
TARGET_CONTAINER=
export MOCK_PID=999
# Simulate a container being replaced between selection and the final identity check.
maybe_restart
check 'changed PID prevents restart' '[[ ! -e $RUN/container-restart-attempted ]]'
unset MOCK_PID
# Simulate missing memory accounting; uncertainty must prevent action.
container_anon_kib() { return 1; }
maybe_restart
check 'unreadable attribution fails closed' '[[ ! -e $RUN/container-restart-attempted ]]'
container_anon_kib() { case "$1" in 111) echo 1000;; 222) echo 3000000;; esac; }
# With all guards satisfied, the fixture accepts only the correct restart by ID.
maybe_restart
check 'large container receives bounded restart by ID' '[[ $action == restarted:* && -e $RUN/container-restart-attempted ]]'
maybe_restart
check 'restart marker survives daemon restart' '[[ $action == already-attempted ]]'
rm "$RUN/container-restart-attempted"
# Removing this marker is deliberate test setup only. Real updates must preserve it.
# Make the pretend Docker command fail and verify even failure consumes the attempt.
export MOCK_FAIL=1
maybe_restart
check 'failed restart also consumes boot allowance' '[[ $action == restart-failed* && -e $RUN/container-restart-attempted ]]'

# Notification command is a fixture, never Unraid's real notification service.
# This executable writes received arguments into a scratch file instead of sending
# anything. The assertion checks the event name and the required Alert severity.
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
# yes produces endless harmless text. sleep pretends to be a diagnostic that hangs.
# Verify output and wait time are limited without creating any host memory pressure.
SECTION_BYTES=1024
section noisy bash -c 'yes x' > "$T/noisy"
check 'noisy command output bounded' '(( $(wc -c < "$T/noisy") < 1200 ))'
start=$SECONDS
section hung sleep 30 > "$T/hung"
check 'hung command returns within timeout allowance' '(( SECONDS-start <= 6 ))'

# Real collector/capture with fake flash check and deterministic section payload.
# Restore production functions again, then allow "flash" only in our scratch tree.
# Each diagnostic emits a fixed 64 KiB block, testing the actual report size ceiling.
source "$(dirname "$0")/../unraid-memory-watchdog.sh"
NOTIFY=0
DEST=$T/captures; RUN=$T/run; mkdir -p "$DEST"
flash_ready() { return 0; }
section() { printf '%s\n' "$1"; head -c 65536 /dev/zero; }
total=10000; available=500; some=0; full=0; action=none
capture 2
# The first report must have both the reservation and the completion footer.
files=("$DEST"/*.log)
check 'real capture reserves one bounded report' '(( ${#files[@]} == 1 && $(wc -c < "${files[0]}") < 530000 ))'
check 'report has completion footer' 'tail -c 200 "${files[0]}" | grep -aq "CAPTURE COMPLETE"'
capture 2
files=("$DEST"/*.log)
check 'repeat capture blocked by persistent cooldown' '(( ${#files[@]} == 1 ))'
for n in {1..12}; do touch "$DEST/event-17000000$(printf '%02d' "$n")-1.log"; done
# Add old reports to exercise retention without waiting for real calendar days.
# Existing report prevents capture and deletion: budget failures never prune evidence.
capture 2
files=("$DEST"/*.log)
check 'budget denial does not prune evidence' '(( ${#files[@]} == 13 ))'
rm "${files[@]}"
# Start a separate retention scenario where a new report is allowed. Only then
# should the oldest existing report be removed to make room within KEEP.
for n in {1..12}; do touch "$DEST/event-17000000$(printf '%02d' "$n")-1.log"; done
capture 2
files=("$DEST"/*.log)
check 'retention removes oldest after a new capture' '(( ${#files[@]} == 12 )) && [[ ! -e $DEST/event-1700000001-1.log ]]'

DEST=$T/partial; mkdir -p "$DEST"
# Pretend collection fails after writing its first evidence. The partial report
# must remain useful and must still consume its persistent write allowance.
collect() { printf 'EARLY EVIDENCE\n'; return 1; }
capture 2
files=("$DEST"/*.log)
check 'partial collection leaves early evidence in reserved file' 'grep -q "EARLY EVIDENCE" "${files[0]}" && ! grep -q "CAPTURE COMPLETE" "${files[0]}"'
check 'incomplete capture consumes write budget' '! budget 2 "$(date +%s)"'
flash_ready() { return 1; }
# Pretend the flash mount is unavailable. No fallback report directory may appear.
DEST=$T/unmounted
capture 2
check 'unavailable flash creates no fallback report' '[[ ! -e $DEST ]]'

# Real single-instance lock and clean termination, with monitoring disabled.
# Start a child Bash process using the real main(), but make tick() do nothing.
# Its lock/PID paths are temporary, so it cannot collide with a real watchdog.
script_path=$(cd "$(dirname "$0")/.." && pwd)/unraid-memory-watchdog.sh
# Use an empty explicit settings file so a developer's adjacent configuration cannot
# override these test cases. Empty settings preserve the values prepared by each test.
: > "$T/empty.conf"
bash -c 'source "$1"; RUN=$2; tick() { :; }; main "$3"' _ "$script_path" "$T/daemon" "$T/empty.conf" > "$T/daemon.log" 2>&1 &
daemon_pid=$!
# $! is the background child's ID. Give startup up to three seconds to publish it.
for n in {1..30}; do [[ -s $T/daemon/pid ]] && break; sleep 0.1; done
check 'daemon creates PID and holds exclusive lock' '[[ -s $T/daemon/pid ]] && ! flock -n "$T/daemon/lock" true'
bash -c 'source "$1"; RUN=$2; tick() { :; }; main "$3"' _ "$script_path" "$T/daemon" "$T/empty.conf" > "$T/duplicate.log" 2>&1
# A second child must notice the lock and exit without replacing the first PID.
check 'duplicate instance exits without replacing PID' 'grep -q "already running" "$T/duplicate.log" && [[ $(cat "$T/daemon/pid") == "$daemon_pid" ]]'
kill "$daemon_pid"; wait "$daemon_pid"
# Stop only the idle child created above, then confirm its cleanup releases the lock.
check 'termination removes PID and releases lock' '[[ ! -e $T/daemon/pid ]] && flock -n "$T/daemon/lock" true'
bash -c 'source "$1"; RUN=$2; CRIT_PCT=50; main "$3"' _ "$script_path" "$T/bad" "$T/empty.conf" > "$T/bad.log" 2>&1
# Deliberately reverse threshold order; startup must reject it before creating a PID.
check 'invalid settings fail before daemon starts' '[[ ! -e $T/bad/pid ]] && grep -q "Invalid thresholds" "$T/bad.log"'

# Settings are data, not code. Exercise normal edits and reject typos, command text,
# protected paths and oversized files without ever sourcing the supplied content.
printf ' WARN_PCT = 12 # a comment\nTARGET_CONTAINER="fixture-1"\nEXCLUDE_CONTAINERS="fixture-2 fixture-3"\n' > "$T/settings.conf"
load_config "$T/settings.conf"
check 'settings support whitespace comments and quoted names' '(( WARN_PCT == 12 )) && [[ $TARGET_CONTAINER == fixture-1 && $EXCLUDE_CONTAINERS == "fixture-2 fixture-3" ]]'
printf 'NOTIFY=0\r\nINTERVAL=45' > "$T/settings.conf"
load_config "$T/settings.conf"
check 'settings accept Windows line endings and missing final newline' '(( NOTIFY == 0 && INTERVAL == 45 ))'
printf 'RUN=/tmp/other\n' > "$T/settings.conf"
check 'settings cannot change protected runtime paths' '! load_config "$T/settings.conf"'
printf 'NOTIFY=$(touch %s)\n' "$T/unwanted-command" > "$T/settings.conf"
check 'settings never execute command substitutions' '! load_config "$T/settings.conf" && [[ ! -e $T/unwanted-command ]]'
printf 'this is not an assignment\n' > "$T/settings.conf"
check 'settings reject malformed lines' '! load_config "$T/settings.conf"'
head -c 17000 /dev/zero > "$T/settings.conf"
check 'settings file size is bounded' '! load_config "$T/settings.conf"'
printf '\n%s tests passed. No live Docker or flash actions.\n' "$passed"
