#!/usr/bin/env bash
# tests/fm-wake-shadow.test.sh - bin/fm-wake-shadow.sh, the shadow log of check and
# signal wakes. It is observational: the log must carry the features and the
# candidate verdict, and the drain that feeds it must present exactly what it
# presented before, whether or not the log is on or can be written.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SHADOW="$ROOT/bin/fm-wake-shadow.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-shadow-tests)

# No supervision host, so the drain's BRANCH OUTCOMES section stays out of the output.
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

row() {  # <epoch> <seq> <kind> <key> <payload>
  printf '%s\t%s\t%s\t%s\t%s\n' "$@"
}

seed_task() {  # <state> <task> <kind> <status-line>...
  local state=$1 task=$2 kind=$3
  shift 3
  printf 'window=fm:%s\nkind=%s\n' "$task" "$kind" > "$state/$task.meta"
  : > "$state/$task.status"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$state/$task.status"; done
}

field() {  # <log> <seq> <jq-field>
  jq -r --argjson seq "$2" 'select(.seq == $seq) | .'"$3" "$1" | head -n 1
}

test_candidate_rule_and_features() {
  local dir state log
  dir=$(make_case shadow-rule)
  state="$dir/state"
  log="$state/wake-shadow.jsonl"
  mkdir -p "$dir/data"
  printf '# Backlog\n\n## In flight\n- [ ] busy - a task (repo: x) (kind: ship)\n' > "$dir/data/backlog.md"
  seed_task "$state" busy ship 'working: compiling'
  seed_task "$state" finished ship 'done: PR https://example.test/pull/9'
  seed_task "$state" asking ship 'working: halfway' 'needs-decision: pick A or B'
  seed_task "$state" resting ship 'paused: waiting for CI'
  {
    row 1792000000 1 signal busy.status 'busy.status changed'
    row 1792000001 2 signal finished.status 'finished.status changed'
    row 1792000002 3 signal asking.status 'asking.status changed'
    row 1792000003 4 signal resting.status 'resting.status changed'
    row 1792000004 5 check pr-poll 'check: merge poll: nothing new'
    row 1792000005 6 stale busy 'stale: pane quiet'
    row 1792000006 7 heartbeat fleet 'heartbeat'
    row 1792000007 8 signal ghost.status 'ghost.status changed'
  } | FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$dir/data" "$SHADOW" record \
    || fail "record must exit 0"

  [ "$(wc -l < "$log")" -eq 6 ] || fail "only check and signal rows are logged, found $(wc -l < "$log"): $(cat "$log")"
  [ "$(field "$log" 1 candidate)" = noop ] || fail "a working line on a recorded task is the noop candidate"
  [ "$(field "$log" 1 status_verb)" = working ] || fail "verb not recorded"
  [ "$(field "$log" 1 backlog)" = 'In flight' ] || fail "backlog section not recorded: $(field "$log" 1 backlog)"
  [ "$(field "$log" 1 task_kind)" = ship ] || fail "task kind not recorded"
  [ "$(field "$log" 2 candidate)" = deliver ] || fail "a done line must be delivered"
  [ "$(field "$log" 3 candidate)" = deliver ] || fail "a task with an open decision must be delivered"
  [ "$(field "$log" 3 open_decisions)" = 1 ] || fail "open decisions not counted: $(field "$log" 3 open_decisions)"
  [ "$(field "$log" 4 candidate)" = noop ] || fail "a paused line on a recorded task is the noop candidate"
  [ "$(field "$log" 5 candidate)" = deliver ] || fail "checks are always delivered in rule v1"
  [ "$(field "$log" 5 task)" = '' ] || fail "a check row has no task"
  [ "$(field "$log" 8 candidate)" = deliver ] || fail "a signal with no recorded task must be delivered"
  [ -z "$(field "$log" 6 seq)" ] && [ -z "$(field "$log" 7 seq)" ] || fail "stale and heartbeat rows must not be logged"
  [ "$(field "$log" 1 rule)" = v1 ] || fail "rule version missing"
  pass "shadow log records check and signal rows with features and a conservative candidate"
}

test_repeat_marks_a_re_presented_row() {
  local dir state log
  dir=$(make_case shadow-repeat)
  state="$dir/state"
  log="$state/wake-shadow.jsonl"
  seed_task "$state" busy ship 'working: compiling'
  row 1792000000 5 signal busy.status 'busy.status changed' | FM_STATE_OVERRIDE="$state" "$SHADOW" record
  row 1792000000 5 signal busy.status 'busy.status changed' | FM_STATE_OVERRIDE="$state" "$SHADOW" record
  [ "$(jq -s '[.[] | select(.repeat == false)] | length' "$log")" -eq 1 ] || fail "the first presentation must be the only non-repeat"
  [ "$(jq -s '[.[] | select(.repeat == true)] | length' "$log")" -eq 1 ] || fail "the second presentation must be marked repeat"
  pass "a re-presented wake is marked repeat"
}

test_drain_output_is_identical_with_and_without_the_log() {
  local dir state with without
  dir=$(make_case shadow-drain)
  state="$dir/state"
  seed_task "$state" busy ship 'working: compiling'
  prime_status_seen "$state" "$state/busy.status"
  printf 'working: second step\n' >> "$state/busy.status"
  append_wake "$state" signal busy.status 'busy.status changed'
  append_wake "$state" check poll 'check: merge poll'
  cp -a "$state" "$dir/state.snap"
  with="$dir/with.out"
  without="$dir/without.out"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$with" 2>&1 || fail "drain with the log failed: $(cat "$with")"
  [ "$(wc -l < "$state/wake-shadow.jsonl")" -eq 2 ] || fail "the drain did not log its two rows: $(cat "$state/wake-shadow.jsonl" 2>/dev/null)"
  rm -rf "$state"
  cp -a "$dir/state.snap" "$state"
  FM_WAKE_SHADOW=0 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$without" 2>&1 || fail "drain without the log failed"
  [ ! -e "$state/wake-shadow.jsonl" ] || fail "FM_WAKE_SHADOW=0 still wrote the log"
  # The recovery generation differs between two real drains; everything else must match.
  sed 's/--recovery-generation [A-Za-z0-9._-]*/--recovery-generation G/' "$with" > "$with.norm"
  sed 's/--recovery-generation [A-Za-z0-9._-]*/--recovery-generation G/' "$without" > "$without.norm"
  cmp -s "$with.norm" "$without.norm" || fail "the log changed what the drain presents: $(diff "$with.norm" "$without.norm")"
  pass "the drain presents exactly the same text with the shadow log on and off"
}

test_an_unwritable_log_never_fails_the_drain() {
  local dir state out status
  dir=$(make_case shadow-unwritable)
  state="$dir/state"
  mkdir -p "$state/wake-shadow.jsonl"
  seed_task "$state" busy ship 'working: compiling'
  append_wake "$state" signal busy.status 'busy.status changed'
  out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>&1
  status=$?
  expect_code 0 "$status" "a log that cannot be written must not fail the drain: $(cat "$out")"
  grep -q 'busy.status changed' "$out" || fail "the drain lost the wake while the log was unwritable: $(cat "$out")"
  pass "an unwritable shadow log never fails or changes the drain"
}

test_log_rotates_once_past_its_cap_and_summarises() {
  local dir state log
  dir=$(make_case shadow-rotate)
  state="$dir/state"
  log="$state/wake-shadow.jsonl"
  seed_task "$state" busy ship 'working: compiling'
  row 1792000000 1 signal busy.status 'busy.status changed' | FM_STATE_OVERRIDE="$state" FM_WAKE_SHADOW_MAX_BYTES=10 "$SHADOW" record
  row 1792000001 2 signal busy.status 'busy.status changed' | FM_STATE_OVERRIDE="$state" FM_WAKE_SHADOW_MAX_BYTES=10 "$SHADOW" record
  [ -f "$log.1" ] || fail "a log past its cap was not rotated"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "the fresh log should hold only the row after rotation"
  FM_STATE_OVERRIDE="$state" "$SHADOW" summary | grep -q 'signal.*working.*noop' || fail "summary lost the counts"
  pass "the shadow log rotates once past its cap and summarises"
}

test_candidate_rule_and_features
test_repeat_marks_a_re_presented_row
test_drain_output_is_identical_with_and_without_the_log
test_an_unwritable_log_never_fails_the_drain
test_log_rotates_once_past_its_cap_and_summarises
