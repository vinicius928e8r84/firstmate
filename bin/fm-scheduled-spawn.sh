#!/usr/bin/env bash
# fm-scheduled-spawn.sh - run the captain's recurring scheduled loops (the daily audit, the weekly retro, correct,
# architecture and benchmark runs, the monthly run, the end-of-day cleanup) so a refusal can never silently lose one.
# Usage: fm-scheduled-spawn.sh <loop> <fm-spawn.sh args...>     spawn through the reserved pool, retrying and alerting
#        fm-scheduled-spawn.sh wrap <loop> -- <command...>      run a wrapper script; a load refusal is a deferral
#        fm-scheduled-spawn.sh queue <loop> -- <command...>     queue a wrapper run for the next tick (a lost run)
#        fm-scheduled-spawn.sh tick                             the hourly retry tick (bin/fm-cron-deferred.sh's job)
#        fm-scheduled-spawn.sh status                           one line per loop: last result and any pending run
# <loop> is a name of letters, digits, dot, underscore and dash, other than wrap, queue, tick or status.
# Spawn mode runs `fm-spawn.sh <args> --scheduled-loop <loop>`: bin/fm-spawn.sh admits that lane from the reserve of
# config/lane-capacity (docs/configuration.md "Lane capacity"), never from the ordinary cap. Any non-zero status - the
# 75 lane or project deferral, the 76 memory floor, 1, anything - is retried up to FM_SCHEDULED_SPAWN_ATTEMPTS (3) times
# with a doubling pause starting at FM_SCHEDULED_SPAWN_BACKOFF_SEC (20; keep the whole span under any `timeout` the
# caller applies). The spawn's own failure records are suppressed while this runs, because this helper owns the alert.
# After the final failure it raises an alert through bin/fm-lane-guard.sh (state/.lane-guard-alerts, the watcher
# webhook, data/tools/fm-asks.sh when present), writes state/scheduled-loops/<loop>.pending so the tick runs it
# again, and exits with the spawn's last status. A later success clears the pending record and the alert.
# Durable record: state/scheduled-loops/<loop>.last, key=value lines: loop, at (epoch), at_utc, exit (the last
# command's status), attempts, result (ok | failed | deferred-load | queued | expired), detail.
# Load contract for the private wrappers (the "refused by load" deferral). A wrapper that declines to run only
# because the host load average is over its own gate exits 79 and prints, on stdout or stderr, one line:
#   scheduled-load-refused load1=<X> max=<Y>
# (X the load it saw, Y its threshold). `wrap` treats that as a deferral and not as a failure or a loss: it keeps
# state/scheduled-loops/<loop>.pending, exits 79 itself, and the tick re-runs the wrapper command once the 1-minute
# load average is below Y (and only then, so a loaded host is not poked every hour). Every other status counts
# as a run result: 0 clears the pending run and any alert; anything else alerts and is retried by the tick up to
# FM_SCHEDULED_MAX_TRIES (6) times. A pending run that has not run by the end of its UTC day alerts once, in the last
# FM_SCHEDULED_EOD_LEAD_SEC (3600) of that day or after it, and keeps being retried; one older than
# FM_SCHEDULED_PENDING_MAX_DAYS (7) days is dropped with an alert. A newer run of the same loop replaces its pending
# record. The pending record is plain text: queued_at, day, kind, reason, max_load, load1, tries, alerted, eod_alerted
# and one arg= line per argument of the command (an argument with a newline cannot be queued).
# Alerts use bin/fm-lane-guard.sh's key lane-guard-scheduled-<loop>.
# Exit: spawn mode = the spawn's last status; wrap = the wrapper's status (79 for a load deferral); queue 0; tick 0;
#   64 usage; 75 another instance is already running that loop.
# Env: FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE; FM_SCHEDULED_NOW (epoch, tests), FM_SCHEDULED_LOAD1 (tests),
#   FM_SCHEDULED_SPAWN_BIN (tests), FM_SCHEDULED_DEFAULT_MAX_LOAD (threshold when a wrapper prints none, 8).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
F=${FM_HOME:-$(cd "$HERE/.." && pwd)}
S=${FM_STATE_OVERRIDE:-$F/state}
C=${FM_CONFIG_OVERRIDE:-$F/config}
DIR=$S/scheduled-loops
SPAWN=${FM_SCHEDULED_SPAWN_BIN:-$HERE/fm-spawn.sh}
LOAD_EXIT=79
ATTEMPTS=${FM_SCHEDULED_SPAWN_ATTEMPTS:-3}
BACKOFF=${FM_SCHEDULED_SPAWN_BACKOFF_SEC:-20}
MAX_TRIES=${FM_SCHEDULED_MAX_TRIES:-6}
EOD_LEAD=${FM_SCHEDULED_EOD_LEAD_SEC:-3600}
PENDING_MAX_DAYS=${FM_SCHEDULED_PENDING_MAX_DAYS:-7}
DEFAULT_MAX_LOAD=${FM_SCHEDULED_DEFAULT_MAX_LOAD:-8}
for v in "$ATTEMPTS" "$BACKOFF" "$MAX_TRIES" "$EOD_LEAD" "$PENDING_MAX_DAYS"; do
  [[ $v =~ ^[0-9]+$ ]] || { echo "fm-scheduled-spawn: the FM_SCHEDULED_* numbers must be non-negative integers (got '$v')" >&2; exit 64; }
done
[ "$ATTEMPTS" -ge 1 ] || ATTEMPTS=1

now() { echo "${FM_SCHEDULED_NOW:-$(date +%s)}"; }
utc() { date -u -d "@$1" +%FT%TZ; }
day_of() { date -u -d "@$1" +%F; }
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 64; }
valid_loop() { [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] && case $1 in wrap|queue|tick|status) return 1 ;; esac; }
load1() { local l=${FM_SCHEDULED_LOAD1:-}; [ -n "$l" ] || l=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null); echo "$l"; }
guard() { FM_HOME=$F FM_STATE_OVERRIDE=$S FM_CONFIG_OVERRIDE=$C FM_LG_NOW=$(now) "$HERE/fm-lane-guard.sh" "$@" </dev/null >/dev/null 2>&1 || true; }
alert() { guard alert "scheduled-$1" "$2"; echo "scheduled loop $1: ALERT: $2" >&2; }
clear_alert() { guard clear-alert "scheduled-$1"; }
fget() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

write_last() { # <loop> <exit> <attempts> <result> <detail>
  local at; at=$(now); mkdir -p "$DIR" || return 0
  printf 'loop=%s\nat=%s\nat_utc=%s\nexit=%s\nattempts=%s\nresult=%s\ndetail=%s\n' \
    "$1" "$at" "$(utc "$at")" "$2" "$3" "$4" "$5" > "$DIR/$1.last.tmp" && mv "$DIR/$1.last.tmp" "$DIR/$1.last"
}

# ---- the pending record
pending_file() { echo "$DIR/$1.pending"; }
write_pending() { # <loop> <kind> <reason> <max_load> <load1> <tries> <queued_at> <alerted> <eod_alerted> <arg>...
  local loop=$1 kind=$2 reason=$3 maxl=$4 l1=$5 tries=$6 queued=$7 al=$8 eod=$9 f a
  shift 9
  for a in "$@"; do
    case $a in *$'\n'*) echo "fm-scheduled-spawn: an argument with a newline cannot be queued for a retry" >&2; return 1 ;; esac
  done
  mkdir -p "$DIR" || return 1
  f=$(pending_file "$loop")
  {
    printf 'loop=%s\nkind=%s\nreason=%s\nqueued_at=%s\nday=%s\nmax_load=%s\nload1=%s\ntries=%s\nalerted=%s\neod_alerted=%s\n' \
      "$loop" "$kind" "$reason" "$queued" "$(day_of "$queued")" "$maxl" "$l1" "$tries" "$al" "$eod"
    for a in "$@"; do printf 'arg=%s\n' "$a"; done
  } > "$f.tmp" && mv "$f.tmp" "$f"
}
# Loads PENDING_* for <loop>; returns 1 when there is none.
read_pending() {
  local f; f=$(pending_file "$1"); [ -f "$f" ] || return 1
  PENDING_KIND=$(fget "$f" kind); PENDING_REASON=$(fget "$f" reason); PENDING_QUEUED=$(fget "$f" queued_at)
  PENDING_DAY=$(fget "$f" day); PENDING_MAX_LOAD=$(fget "$f" max_load); PENDING_TRIES=$(fget "$f" tries)
  PENDING_ALERTED=$(fget "$f" alerted); PENDING_EOD=$(fget "$f" eod_alerted)
  mapfile -t PENDING_ARGS < <(sed -n 's/^arg=//p' "$f")
  [[ ${PENDING_QUEUED:-} =~ ^[0-9]+$ ]] || PENDING_QUEUED=$(now)
  [[ ${PENDING_TRIES:-} =~ ^[0-9]+$ ]] || PENDING_TRIES=0
  PENDING_DAY=$(day_of "$PENDING_QUEUED")
}
# The pending state to carry into a re-written record: its first-queued time and flags when one exists for this loop.
carry_pending() {
  if read_pending "$1"; then
    CARRY_QUEUED=$PENDING_QUEUED CARRY_TRIES=$PENDING_TRIES CARRY_ALERTED=$PENDING_ALERTED CARRY_EOD=$PENDING_EOD
  else
    CARRY_QUEUED=$(now) CARRY_TRIES=0 CARRY_ALERTED='' CARRY_EOD=''
  fi
}
resolve_run() { # <loop> <exit> <attempts>: the run succeeded
  rm -f "$(pending_file "$1")"
  write_last "$1" "$2" "$3" ok "ran"
  clear_alert "$1"
}

lock_loop() { # <loop>: one instance per loop; 75 when another holds it
  mkdir -p "$DIR" || return 0
  exec 8>"$DIR/$1.lock"
  flock -n 8 || { echo "fm-scheduled-spawn: another run of scheduled loop $1 is in progress" >&2; exit 75; }
}

# ---- spawn mode
run_spawn() { # <loop> <spawn args...>; ATTEMPTS bounds the tries. Sets SPAWN_RC, SPAWN_TRIES.
  local loop=$1 i pause=$BACKOFF
  shift
  SPAWN_RC=1 SPAWN_TRIES=0
  for ((i = 1; i <= ATTEMPTS; i++)); do
    SPAWN_TRIES=$i
    FM_SCHEDULED_SPAWN_HELPER=1 "$SPAWN" "$@" --scheduled-loop "$loop"
    SPAWN_RC=$?
    [ "$SPAWN_RC" -ne 0 ] || return 0
    echo "fm-scheduled-spawn: scheduled loop $loop spawn attempt $i of $ATTEMPTS exited $SPAWN_RC" >&2
    if [ "$i" -lt "$ATTEMPTS" ]; then
      sleep "$pause"
      pause=$((pause * 2))
    fi
  done
  return "$SPAWN_RC"
}
spawn_loop() { # <loop> <spawn args...>
  local loop=$1 rc tries at
  shift
  carry_pending "$loop"
  run_spawn "$loop" "$@"
  rc=$SPAWN_RC tries=$SPAWN_TRIES
  if [ "$rc" -eq 0 ]; then
    resolve_run "$loop" 0 "$tries"
    return 0
  fi
  at=$(now)
  write_last "$loop" "$rc" "$tries" failed "spawn refused or failed; the tick retries it"
  write_pending "$loop" spawn spawn-failed '' '' $((CARRY_TRIES + 1)) "$CARRY_QUEUED" "$(day_of "$CARRY_QUEUED")" "$CARRY_EOD" "$@" || true
  if [ "$CARRY_ALERTED" != "$(day_of "$CARRY_QUEUED")" ]; then
    alert "$loop" "scheduled loop $loop did not start: the spawn exited $rc after $tries attempt(s) at $(utc "$at"); it is retried hourly until it runs"
  fi
  return "$rc"
}

# ---- wrap mode
parse_load_line() { # <output file>: sets REFUSED_LOAD1 REFUSED_MAX; returns 1 when the contract line is absent
  local line
  line=$(grep -E '^scheduled-load-refused( |$)' "$1" | tail -1) || return 1
  [ -n "$line" ] || return 1
  REFUSED_LOAD1=$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]load1=\([0-9][0-9.]*\).*/\1/p')
  REFUSED_MAX=$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]max=\([0-9][0-9.]*\).*/\1/p')
  [ -n "$REFUSED_MAX" ] || REFUSED_MAX=$DEFAULT_MAX_LOAD
}
wrap_loop() { # <loop> <command...>
  local loop=$1 rc out at
  shift
  carry_pending "$loop"
  out=$(mktemp "${TMPDIR:-/tmp}/fm-scheduled.XXXXXX") || exit 1
  "$@" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    resolve_run "$loop" 0 1
    rm -f "$out"
    return 0
  fi
  at=$(now)
  if [ "$rc" -eq "$LOAD_EXIT" ] && parse_load_line "$out"; then
    write_last "$loop" "$rc" 1 deferred-load "load ${REFUSED_LOAD1:-?} over ${REFUSED_MAX}; re-queued for the tick"
    write_pending "$loop" wrap load "$REFUSED_MAX" "${REFUSED_LOAD1:-}" "$CARRY_TRIES" "$CARRY_QUEUED" "$CARRY_ALERTED" "$CARRY_EOD" "$@" || true
    rm -f "$out"
    return "$LOAD_EXIT"
  fi
  rm -f "$out"
  write_last "$loop" "$rc" 1 failed "the command exited $rc; the tick retries it"
  write_pending "$loop" wrap run-failed '' '' $((CARRY_TRIES + 1)) "$CARRY_QUEUED" "$(day_of "$CARRY_QUEUED")" "$CARRY_EOD" "$@" || true
  if [ "$CARRY_ALERTED" != "$(day_of "$CARRY_QUEUED")" ]; then
    alert "$loop" "scheduled loop $loop failed: its command exited $rc at $(utc "$at"); it is retried hourly until it runs"
  fi
  return "$rc"
}

# ---- queue: a lost run, to be run by the next tick when the load allows
queue_loop() { # <loop> <command...>
  local loop=$1 at
  shift
  carry_pending "$loop"
  at=$(now)
  write_pending "$loop" wrap queued "$DEFAULT_MAX_LOAD" '' 0 "$at" '' '' "$@" || return 1
  write_last "$loop" 0 0 queued "queued by hand for the tick"
  echo "scheduled loop $loop queued; the hourly tick runs it once the 1-minute load is under $DEFAULT_MAX_LOAD"
}

# ---- tick
load_allows() { # <max>: true when the load is below it or unreadable (the wrapper re-checks its own gate)
  local l; l=$(load1)
  [[ $l =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
  awk -v l="$l" -v m="$1" 'BEGIN{exit !(l < m)}'
}
tick_loop() { # <loop>
  local loop=$1 maxl deadline at age_days kind
  read_pending "$loop" || return 0
  at=$(now)
  kind=$PENDING_KIND
  age_days=$(( (at - PENDING_QUEUED) / 86400 ))
  if [ "$age_days" -ge "$PENDING_MAX_DAYS" ]; then
    rm -f "$(pending_file "$loop")"
    write_last "$loop" "$LOAD_EXIT" 0 expired "queued $(utc "$PENDING_QUEUED") and never ran"
    alert "$loop" "scheduled loop $loop never ran: queued $(utc "$PENDING_QUEUED") and dropped after $PENDING_MAX_DAYS days; run it by hand"
    return 0
  fi
  maxl=${PENDING_MAX_LOAD:-$DEFAULT_MAX_LOAD}
  local args=("${PENDING_ARGS[@]}") queued=$PENDING_QUEUED eod=$PENDING_EOD tries=$PENDING_TRIES reason=$PENDING_REASON
  if [ "${#args[@]}" -gt 0 ]; then
    # Only a load deferral waits on the load; a failed run or spawn is retried whatever it is, a bounded number of times.
    if [ "$reason" = load ] || [ "$reason" = queued ]; then
      ! load_allows "$maxl" || try_pending "$loop" "$kind" "${args[@]}"
    elif [ "$tries" -lt "$MAX_TRIES" ]; then
      try_pending "$loop" "$kind" "${args[@]}"
    fi
  fi
  # Still pending: warn once when the UTC day of its first queueing is about to end, or has.
  if read_pending "$loop"; then
    deadline=$(date -u -d "$PENDING_DAY +1 day" +%s)
    if [ "$at" -ge $((deadline - EOD_LEAD)) ] && [ "$PENDING_EOD" != "$PENDING_DAY" ]; then
      write_pending "$loop" "$PENDING_KIND" "$PENDING_REASON" "$PENDING_MAX_LOAD" "" "$PENDING_TRIES" "$PENDING_QUEUED" "$PENDING_ALERTED" "$PENDING_DAY" "${PENDING_ARGS[@]}" || true
      alert "$loop" "scheduled loop $loop has not run by the end of $PENDING_DAY (UTC): queued $(utc "$PENDING_QUEUED") (${PENDING_REASON}); the tick keeps retrying it"
    fi
  fi
  return 0
}
try_pending() { # <loop> <kind> <args...>
  local loop=$1 kind=$2
  shift 2
  ( lock_loop "$loop"
    if [ "$kind" = spawn ]; then
      ATTEMPTS=1
      spawn_loop "$loop" "$@"
    else
      wrap_loop "$loop" "$@"
    fi ) >/dev/null 2>&1 || true
}
tick() {
  local f loop
  mkdir -p "$DIR" || exit 0
  exec 9>"$DIR/.tick.lock"
  flock -n 9 || exit 0
  for f in "$DIR"/*.pending; do
    [ -e "$f" ] || continue
    loop=$(basename "$f" .pending)
    valid_loop "$loop" || continue
    tick_loop "$loop"
  done
  exit 0
}

status() {
  local f loop
  for f in "$DIR"/*.last; do
    [ -e "$f" ] || continue
    loop=$(basename "$f" .last)
    printf '%s: %s at %s exit=%s attempts=%s' "$loop" "$(fget "$f" result)" "$(fget "$f" at_utc)" "$(fget "$f" exit)" "$(fget "$f" attempts)"
    if read_pending "$loop"; then printf ' pending=%s since %s tries=%s' "$PENDING_REASON" "$(utc "$PENDING_QUEUED")" "$PENDING_TRIES"; fi
    printf '\n'
  done
  exit 0
}

# ---- dispatch
[ $# -ge 1 ] || usage
case $1 in
  tick) [ $# -eq 1 ] || usage; tick ;;
  status) [ $# -eq 1 ] || usage; status ;;
  wrap|queue)
    sub=$1
    if [ $# -lt 4 ] || [ "$3" != -- ] || ! valid_loop "$2"; then usage; fi
    loop=$2
    shift 3
    if [ "$sub" = queue ]; then queue_loop "$loop" "$@"; exit $?; fi
    lock_loop "$loop"
    wrap_loop "$loop" "$@"
    exit $? ;;
  -h|--help) usage ;;
  *)
    valid_loop "$1" || usage
    [ $# -ge 2 ] || usage
    loop=$1
    shift
    lock_loop "$loop"
    spawn_loop "$loop" "$@"
    exit $? ;;
esac
