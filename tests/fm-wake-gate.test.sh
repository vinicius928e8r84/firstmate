#!/usr/bin/env bash
# tests/fm-wake-gate.test.sh - the state gate in front of stale and heartbeat wakes
# (fm_wake_gate in bin/fm-wake-lib.sh, wired into bin/fm-watch.sh). A pane going quiet
# behind a done: status, or a repeat of an alarm already delivered while nothing
# about the task changed, must not wake the model; every genuine event (a new status
# line, a check result, a worker stuck behind a non-terminal status, a blocked task
# the first time, a record older than the forced interval) must still wake.
# The pure gate is driven as a library; the wiring is driven through a real
# fm-watch.sh subprocess against a fake tmux pane, like tests/fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-gate-tests)

# Run the gate in a fresh shell scoped to <state>; exit 0 = deliver, 1 = absorb.
gate() {  # <state> <key> [task]
  FM_STATE_OVERRIDE=$1 FM_DATA_OVERRIDE="$1/../data" bash -c '
    . "$1"
    fm_wake_gate "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$2" "${3:-}"
}

watch_bg() {  # <state> <fakebin> <out> <window> <capture-file>
  local state=$1 fakebin=$2 out=$3 window=$4 capture=$5
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$state/../data" \
    FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$WATCH" > "$out" 2>/dev/null &
}

# A quiet pane for <window>: recorded task, status already presented, pane hash stable once.
quiet_task() {  # <state> <task> <window> <status-line> <pane-text> <capture-file>
  local state=$1 task=$2 window=$3 line=$4 pane=$5 capture=$6 key
  printf 'window=%s\nkind=ship\n' "$window" > "$state/$task.meta"
  printf '%s\n' "$line" > "$state/$task.status"
  prime_status_seen "$state" "$state/$task.status"
  printf '%s' "$pane" > "$capture"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$pane")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
}

# Wait until the watcher exits (a wake) or logs an absorbed decision (no wake); stop it.
# Prints "wake" or "quiet".
settle() {  # <state> <pid> <out>
  local state=$1 pid=$2 out=$3 i=0
  while [ "$i" -lt 600 ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; echo wake; return 0; }
    grep -q 'absorbed' "$state/.watch-triage.log" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  if [ -s "$out" ]; then echo wake; else echo quiet; fi
}

age_record() {  # <state>: make the forced-interval stamp seven hours old
  sed -i.bak "s/^forced_at=.*/forced_at=$(( $(date +%s) - 7 * 3600 ))/" "$1/.wake-hash"
}

test_gate_new_subject_delivers_and_repeat_is_absorbed() {
  local dir state
  dir=$(make_case gate-repeat); state="$dir/state"; mkdir -p "$dir/data"
  printf 'blocked: waiting on a review\n' > "$state/t1.status"
  gate "$state" stale:w1:terminal t1 || fail "a first alarm for a subject was absorbed"
  gate "$state" stale:w1:terminal t1 && fail "a repeat alarm with nothing changed was delivered"
  gate "$state" stale:w2:terminal t1 || fail "a different subject was absorbed by another subject's record"
  [ -s "$state/.wake-hash" ] || fail "the gate left no state/.wake-hash record"
  pass "the gate delivers a new subject once and absorbs an unchanged repeat"
}

test_gate_redelivers_when_the_tasks_own_state_changes() {
  local dir state
  dir=$(make_case gate-own-change); state="$dir/state"; mkdir -p "$dir/data"
  printf 'blocked: waiting on a review\n' > "$state/t1.status"
  printf 'working: other lane\n' > "$state/t2.status"
  gate "$state" stale:w1:terminal t1 || fail "first alarm absorbed"
  printf 'working: unrelated lane moved on\n' >> "$state/t2.status"
  gate "$state" stale:w1:terminal t1 && fail "another task's status change re-armed an unchanged alarm"
  printf 'blocked: waiting on a different review\n' >> "$state/t1.status"
  gate "$state" stale:w1:terminal t1 || fail "the task's own new status line did not re-arm the alarm"
  printf 'hold t1 pending the captain\n' > "$dir/data/backlog.md"
  gate "$state" stale:w1:terminal t1 || fail "a backlog line naming the task did not re-arm the alarm"
  gate "$state" stale:w1:terminal t1 && fail "an unchanged repeat after re-delivery was delivered"
  printf 't1\tdoes the project exist?\n' > "$dir/data/captain-asks.tsv"
  gate "$state" stale:w1:terminal t1 || fail "a captain ask naming the task did not re-arm the alarm"
  pass "an alarm re-arms on the task's own status, backlog or ask change and not on unrelated traffic"
}

test_gate_heartbeat_uses_the_whole_fleet_digest() {
  local dir state
  dir=$(make_case gate-heartbeat); state="$dir/state"; mkdir -p "$dir/data"
  printf 'working: a\n' > "$state/t1.status"
  gate "$state" heartbeat || fail "first heartbeat absorbed"
  gate "$state" heartbeat && fail "a heartbeat with an unchanged fleet was delivered"
  printf 'working: b\n' >> "$state/t1.status"
  gate "$state" heartbeat || fail "a heartbeat after the fleet changed was absorbed"
  printf 'new ask\n' > "$dir/data/captain-asks.tsv"
  gate "$state" heartbeat || fail "a heartbeat after a new captain ask was absorbed"
  pass "a heartbeat is judged against every status line, the backlog and the asks"
}

test_gate_forces_a_wake_after_the_interval() {
  local dir state
  dir=$(make_case gate-force); state="$dir/state"; mkdir -p "$dir/data"
  printf 'blocked: stuck\n' > "$state/t1.status"
  gate "$state" stale:w1:terminal t1 || fail "first alarm absorbed"
  gate "$state" stale:w1:terminal t1 && fail "repeat inside the interval delivered"
  age_record "$state"
  gate "$state" stale:w1:terminal t1 || fail "a repeat older than the forced interval stayed hidden"
  gate "$state" stale:w1:terminal t1 && fail "the forced delivery did not restart the interval"
  pass "a repeat is delivered once the record is older than six hours, so a stuck worker is never hidden"
}

test_stale_on_a_done_status_is_absorbed() {
  local dir state fakebin out window capture pid verdict
  dir=$(make_case done-stale); state="$dir/state"; fakebin="$dir/fakebin"; mkdir -p "$dir/data"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-done"
  quiet_task "$state" fin "$window" 'done: PR https://example.test/pr/3' 'finished, awaiting review' "$capture"
  watch_bg "$state" "$fakebin" "$out" "$window" "$capture"
  pid=$!
  verdict=$(settle "$state" "$pid" "$out")
  [ "$verdict" = quiet ] || fail "a stale pane behind a done: status woke the model: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a stale pane behind a done: status was queued"
  grep -q 'latest status is done' "$state/.watch-triage.log" || fail "the done gate left no triage record"
  pass "a stale pane behind a done: status raises no wake"
}

test_stale_on_a_blocked_status_wakes_once_then_is_absorbed() {
  local dir state fakebin out window capture pid verdict
  dir=$(make_case blocked-stale); state="$dir/state"; fakebin="$dir/fakebin"; mkdir -p "$dir/data"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-blk"
  quiet_task "$state" blk "$window" 'blocked: waiting on the review' 'waiting, pane one' "$capture"
  watch_bg "$state" "$fakebin" "$out" "$window" "$capture"
  pid=$!
  verdict=$(settle "$state" "$pid" "$out")
  [ "$verdict" = wake ] || fail "a stale pane behind a blocked: status did not wake"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "the stale wake did not name the window: $(cat "$out")"
  # the pane repaints (new hash) while nothing about the task changed: the repeat is absorbed
  : > "$out"; rm -f "$state/.watch-triage.log" "$state/.wake-queue" "$state/.wake-queue.seq" "$state/.watcher-down"
  quiet_task "$state" blk "$window" 'blocked: waiting on the review' 'waiting, pane two repainted' "$capture"
  watch_bg "$state" "$fakebin" "$out" "$window" "$capture"
  pid=$!
  verdict=$(settle "$state" "$pid" "$out")
  [ "$verdict" = quiet ] || fail "a repainted pane with unchanged state woke the model again: $(cat "$out")"
  grep -q 'state unchanged' "$state/.watch-triage.log" || fail "the unchanged-state gate left no triage record"
  pass "a blocked task alarms once and its unchanged repeat is absorbed"
}

test_stuck_worker_behind_a_working_status_still_wakes() {
  local dir state fakebin out window capture pid verdict
  dir=$(make_case stuck-stale); state="$dir/state"; fakebin="$dir/fakebin"; mkdir -p "$dir/data"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-stuck"
  quiet_task "$state" stuck "$window" 'working: step 3 of 5' 'no output for ages' "$capture"
  # a record for other subjects must not hide a newly stuck worker
  printf 'hash=old\nforced_at=%s\nseen=stale:test:fm-other:terminal=1-1\n' "$(date +%s)" > "$state/.wake-hash"
  watch_bg "$state" "$fakebin" "$out" "$window" "$capture"
  pid=$!
  verdict=$(settle "$state" "$pid" "$out")
  [ "$verdict" = wake ] || fail "a worker stuck behind a non-terminal status did not wake"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "the stuck-worker wake did not name the window: $(cat "$out")"
  pass "a worker stuck behind a non-terminal status past the stale grace still wakes"
}

test_a_forced_record_wakes_a_hidden_stale_again() {
  local dir state fakebin out window capture pid verdict
  dir=$(make_case forced-stale); state="$dir/state"; fakebin="$dir/fakebin"; mkdir -p "$dir/data"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-blk"
  quiet_task "$state" blk "$window" 'blocked: waiting on the review' 'waiting, pane one' "$capture"
  gate "$state" "stale:$window:terminal" blk || fail "could not seed the delivered record"
  age_record "$state"
  watch_bg "$state" "$fakebin" "$out" "$window" "$capture"
  pid=$!
  verdict=$(settle "$state" "$pid" "$out")
  [ "$verdict" = wake ] || fail "a stale alarm hidden for more than six hours was not forced through"
  pass "a hidden stale alarm is forced through once the record is older than six hours"
}

test_new_status_line_and_failure_wake_regardless_of_the_record() {
  local dir state fakebin out window capture pid verdict
  dir=$(make_case signal-wake); state="$dir/state"; fakebin="$dir/fakebin"; mkdir -p "$dir/data"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-sig"
  quiet_task "$state" sig "$window" 'working: routine' 'busy-looking pane' "$capture"
  gate "$state" heartbeat >/dev/null
  printf 'failed: the build is red\n' >> "$state/sig.status"
  watch_bg "$state" "$fakebin" "$out" "$window" "$capture"
  pid=$!
  verdict=$(settle "$state" "$pid" "$out")
  [ "$verdict" = wake ] || fail "a new failed: status line did not wake with a delivered record present"
  grep -q '^signal:' "$out" || fail "the failure did not arrive as a signal wake: $(cat "$out")"
  pass "a new failed: status line wakes even with a gate record in place"
}

test_check_result_wakes_regardless_of_the_record() {
  local dir state fakebin out pid verdict
  dir=$(make_case check-wake); state="$dir/state"; fakebin="$dir/fakebin"; mkdir -p "$dir/data" "$dir/config"
  out="$dir/watch.out"
  cat > "$state/pr-merged.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'pr-merged: https://example.test/pr/9 merged\n'
SH
  chmod 0700 "$state/pr-merged.check.sh"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" pr-merged >/dev/null \
    || fail "could not register the check"
  gate "$state" heartbeat >/dev/null
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$dir/data" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  verdict=$(settle "$state" "$pid" "$out")
  [ "$verdict" = wake ] || fail "a registered check result did not wake with a gate record present"
  grep -q '^check:' "$out" || fail "the check result did not arrive as a check wake: $(cat "$out")"
  pass "a check result (merged PR) wakes even with a gate record in place"
}

test_gate_new_subject_delivers_and_repeat_is_absorbed
test_gate_redelivers_when_the_tasks_own_state_changes
test_gate_heartbeat_uses_the_whole_fleet_digest
test_gate_forces_a_wake_after_the_interval
test_stale_on_a_done_status_is_absorbed
test_stale_on_a_blocked_status_wakes_once_then_is_absorbed
test_stuck_worker_behind_a_working_status_still_wakes
test_a_forced_record_wakes_a_hidden_stale_again
test_new_status_line_and_failure_wake_regardless_of_the_record
test_check_result_wakes_regardless_of_the_record
