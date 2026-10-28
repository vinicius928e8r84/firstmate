#!/usr/bin/env bash
# Behavior tests for bin/fm-summary-gate.sh (the quiet-orchestrator gate).
#
# Drives the executable on a fixed clock (FM_SUMMARY_GATE_NOW) against an
# isolated state dir. Pins:
#   1. the first summary is sent and marks the hour, a second one inside 60
#      minutes is suppressed (exit 1, nothing marked), and one at 60 minutes
#      goes through and re-marks;
#   2. a merge-ready PR, a blocker, and a captain decision always go through,
#      even inside the hour, and never move the mark;
#   3. the mark is a durable file, so a fresh process keeps the hour, and
#      `mark` records a summary that went out without the gate;
#   4. simultaneous summaries send exactly once;
#   5. an unknown kind or unwritable state is an error (exit 2), never a
#      `suppress`, so a broken gate cannot swallow a message.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-summary-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-summary-gate)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"
T0=1793140000
MIN=60

gate() {  # <epoch> <args...> -> OUT, CODE
  local now=$1
  shift
  OUT=$(FM_HOME="$HOME_DIR" FM_SUMMARY_GATE_NOW="$now" "$TOOL" "$@" 2>&1)
  CODE=$?
}

# 1. One summary per hour.
gate "$T0" decide summary
expect_code 0 "$CODE" "the first summary is allowed"
assert_equals send "$OUT" "the first summary says send"
assert_equals "$T0" "$(cat "$HOME_DIR/state/.last-summary")" "the send marks the summary time"
gate "$((T0 + 10 * MIN))" decide summary
expect_code 1 "$CODE" "a second summary 10 minutes later is suppressed"
assert_equals suppress "$OUT" "a suppressed summary says suppress"
gate "$((T0 + 59 * MIN + 59))" decide summary
expect_code 1 "$CODE" "one second before the hour is still suppressed"
assert_equals "$T0" "$(cat "$HOME_DIR/state/.last-summary")" "a suppressed summary does not move the mark"
gate "$((T0 + 60 * MIN))" decide summary
expect_code 0 "$CODE" "a summary at 60 minutes goes through"
assert_equals "$((T0 + 60 * MIN))" "$(cat "$HOME_DIR/state/.last-summary")" "and re-marks the hour"
pass "summary gate: the first summary sends, a second inside 60 minutes is suppressed, one at 60 minutes sends"

# 2. Urgent kinds always go through and never use up the hour.
T1=$((T0 + 60 * MIN))
for kind in merge-ready blocker decision; do
  gate "$((T1 + 1))" decide "$kind"
  expect_code 0 "$CODE" "$kind goes through inside the hour"
  assert_equals send "$OUT" "$kind says send"
done
assert_equals "$T1" "$(cat "$HOME_DIR/state/.last-summary")" "urgent kinds never move the mark"
gate "$((T1 + 5 * MIN))" decide summary
expect_code 1 "$CODE" "an urgent message did not spend or reset the hour: the summary is still suppressed"
rm -f "$HOME_DIR/state/.last-summary"
gate "$T0" decide blocker
[ ! -e "$HOME_DIR/state/.last-summary" ] || fail "an urgent message must not create the mark"
gate "$T0" decide summary
expect_code 0 "$CODE" "after only urgent messages the hour's summary is still available"
pass "summary gate: merge-ready, blocker, and decision always go through and never move the mark"

# 3. The mark is durable; `mark` and `status`.
gate "$((T0 + 30 * MIN))" status
assert_contains "$OUT" "last-summary: $T0" "status names the last summary"
assert_contains "$OUT" 'next-summary-allowed-in: 1800s' "status counts down to the next allowed summary"
gate "$((T0 + 90 * MIN))" status
assert_contains "$OUT" 'next-summary-allowed-in: 0s' "status reports 0s once the hour has passed"
gate "$((T0 + 100 * MIN))" mark
expect_code 0 "$CODE" "mark records a summary sent without the gate"
gate "$((T0 + 101 * MIN))" decide summary
expect_code 1 "$CODE" "a marked summary holds the hour for a fresh process"
rm -f "$HOME_DIR/state/.last-summary"
gate "$T0" status
assert_contains "$OUT" 'last-summary: never' "no mark reads as never"
printf 'garbage\n' > "$HOME_DIR/state/.last-summary"
gate "$T0" decide summary
expect_code 0 "$CODE" "a corrupt mark counts as no summary yet"
pass "summary gate: the mark is a durable file, mark and status work, a corrupt mark is ignored"

# 4. Simultaneous summaries send exactly once, and every caller gets a
# contract answer: `send` with exit 0 or `suppress` with exit 1, never an
# error that a caller testing the exit status would read as silence.
rm -f "$HOME_DIR/state/.last-summary"
for i in $(seq 1 24); do
  (FM_HOME="$HOME_DIR" FM_SUMMARY_GATE_NOW="$T0" "$TOOL" decide summary > "$TMP_ROOT/race.$i" 2>&1; echo $? > "$TMP_ROOT/race.$i.rc") &
done
wait
sends=0
for i in $(seq 1 24); do
  out=$(cat "$TMP_ROOT/race.$i"); rc=$(cat "$TMP_ROOT/race.$i.rc")
  case "$out/$rc" in
    send/0) sends=$((sends + 1)) ;;
    suppress/1) ;;
    *) fail "simultaneous caller $i broke the contract: '$out' exit $rc" ;;
  esac
done
[ "$sends" = 1 ] || fail "exactly one of 24 simultaneous summaries should send, got $sends"
[ ! -d "$HOME_DIR/state/.summary-gate.lock" ] || fail "the lock must be released after the race"
pass "summary gate: 24 simultaneous summaries send exactly once and every caller gets send/0 or suppress/1"

# 4b. A mark dated in the future (clock step back, a test clock) never mutes summaries.
printf '%s\n' "$((T0 + 99999999))" > "$HOME_DIR/state/.last-summary"
gate "$T0" decide summary
expect_code 0 "$CODE" "a future-dated mark counts as no summary yet"
assert_equals send "$OUT" "a future-dated mark sends"
assert_equals "$T0" "$(cat "$HOME_DIR/state/.last-summary")" "and is replaced by the real time"
printf '%s\n' "$((T0 + 99999999))" > "$HOME_DIR/state/.last-summary"
gate "$T0" status
assert_contains "$OUT" 'last-summary: never' "status reads a future-dated mark as never"
pass "summary gate: a mark in the future is ignored, not obeyed for decades"

# 4c. A stale lock left by a dead holder is stolen, and a held fresh lock is not.
rm -f "$HOME_DIR/state/.last-summary"
mkdir "$HOME_DIR/state/.summary-gate.lock"
touch -t 202001010000 "$HOME_DIR/state/.summary-gate.lock"
gate "$T0" decide summary
expect_code 0 "$CODE" "a stale lock is stolen: $OUT"
pass "summary gate: a stale lock from a dead holder is stolen"

# 5. Errors are never a silent suppress.
gate "$T0" decide nonsense
expect_code 2 "$CODE" "an unknown kind is an error"
assert_not_contains "$OUT" suppress "an unknown kind never reads as suppress"
OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="/dev/null/nope" FM_SUMMARY_GATE_NOW="$T0" "$TOOL" decide summary 2>&1); CODE=$?
expect_code 2 "$CODE" "unwritable state is an error"
assert_not_contains "$OUT" suppress "unwritable state never reads as suppress"
gate "$T0" bogus
expect_code 2 "$CODE" "an unknown command is an error"
pass "summary gate: an unknown kind or unwritable state exits 2 and never says suppress"

printf '# all fm-summary-gate tests passed\n'
