#!/usr/bin/env bash
# tests/fm-wake-drain-probe.test.sh - behavior tests for `fm-wake-drain.sh
# --probe`, the provable-empty verdict that lets a routine re-arm wake end
# without a captain-facing turn. They drive the real drain over crafted homes:
# a wake with nothing behind it is QUIET (and --settle retires its recovery
# episode), while every kind of real content - a queued row, a note, an open
# decision, an interrupted handling episode, an ineligible wake reason - is NEWS
# and is still presented in full by the drain that follows, because the probe
# consumes nothing.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
REASON='check: rearm-resurface'
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-probe-tests)

# probe <state> [args...]: the probe's stdout, run as main.
probe() {
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" "$DRAIN" --probe "$@" 2>/dev/null
}

# baseline <state> <task>: one real drain over a routine status line, so the
# home has the presentation manifest every drained home has.
baseline() {
  printf 'working: starting\n' > "$1/$2.status"
  FM_STATE_OVERRIDE="$1" "$DRAIN" >/dev/null 2>&1
}

# publish_downtime <state>: open a downtime episode the way a watcher close does.
publish_downtime() {
  FM_STATE_OVERRIDE="$1" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_recovery_marker_publish "$2/.watcher-down" downtime
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1"
}

test_empty_rearm_is_quiet() {
  local dir state out rc
  dir=$(make_case empty)
  state="$dir/state"
  out=$(probe "$state" --reason "$REASON"); rc=$?
  expect_code 0 "$rc" "probe exit"
  assert_equals "QUIET" "$out" "an empty re-arm wake is quiet"
  pass "empty re-arm wake: QUIET"
}

test_ineligible_reasons_are_news() {
  local dir state out
  dir=$(make_case reasons)
  state="$dir/state"
  out=$(probe "$state" --reason 'heartbeat'); assert_contains "$out" "NEWS:" "heartbeat is never quiet"
  out=$(probe "$state" --reason 'stale: win (no output)'); assert_contains "$out" "NEWS:" "stale is never quiet"
  out=$(probe "$state" --reason 'check: merged https://example.invalid/pr/1'); assert_contains "$out" "NEWS:" "another check is never quiet"
  out=$(probe "$state"); assert_contains "$out" "NEWS:" "no reason is news"
  pass "only the re-arm resurface reason can be quiet"
}

test_downtime_episode_settles_only_when_asked() {
  local dir state out marker
  dir=$(make_case settle)
  state="$dir/state"
  publish_downtime "$state"
  marker=$(cat "$state/.watcher-down")
  out=$(probe "$state" --reason "$REASON")
  assert_equals "QUIET" "$out" "an empty downtime episode is quiet"
  assert_equals "$marker" "$(cat "$state/.watcher-down")" "plain probe leaves the episode untouched"
  out=$(probe "$state" --reason "$REASON" --settle)
  assert_contains "$out" "QUIET settled recovery generation" "settle retires the episode"
  case "$(cat "$state/.watcher-down")" in acked:*) ;; *) fail "episode is acknowledged: $(cat "$state/.watcher-down")" ;; esac
  out=$(probe "$state" --reason "$REASON" --settle)
  assert_equals "QUIET" "$out" "a settled episode needs nothing more"
  pass "downtime episode: quiet, and --settle retires it"
}

test_queued_row_is_news_and_survives() {
  local dir state out drained
  dir=$(make_case queued)
  state="$dir/state"
  append_wake "$state" check 'merged:pr-9' 'check: merged https://example.invalid/pr/9' >/dev/null
  out=$(probe "$state" --reason "$REASON" --settle)
  assert_contains "$out" "NEWS: queued wake rows" "a queued row is news"
  drained=$(FM_STATE_OVERRIDE="$state" "$DRAIN" 2>/dev/null)
  assert_contains "$drained" "merged https://example.invalid/pr/9" "the drain still presents the row"
  pass "queued row: NEWS, and nothing was consumed"
}

test_note_and_decision_are_news_and_survive() {
  local dir state out drained
  dir=$(make_case content)
  state="$dir/state"
  baseline "$state" task1
  printf 'note: the build is green\n' >> "$state/task1.status"
  out=$(probe "$state" --reason "$REASON")
  assert_contains "$out" "NEWS: UNREAD STATUS" "an unread note is news"
  drained=$(FM_STATE_OVERRIDE="$state" "$DRAIN" 2>/dev/null)
  assert_contains "$drained" "the build is green" "the unread note is still presented once by the drain"

  dir=$(make_case decision)
  state="$dir/state"
  baseline "$state" task2
  printf 'needs-decision [key=api]: REST or RPC\n' >> "$state/task2.status"
  out=$(probe "$state" --reason "$REASON")
  assert_contains "$out" "NEWS: OPEN DECISIONS" "an open decision is news"
  drained=$(FM_STATE_OVERRIDE="$state" "$DRAIN" 2>/dev/null)
  assert_contains "$drained" "REST or RPC" "the drain still presents the decision"

  printf 'resolved [key=api]: REST\n' >> "$state/task2.status"
  out=$(probe "$state" --reason "$REASON")
  assert_equals "QUIET" "$out" "a closed decision is no longer news"
  pass "unread note and open decision: NEWS and untouched; closed decision: QUIET"
}

test_routine_status_alone_is_quiet() {
  local dir state out
  dir=$(make_case routine)
  state="$dir/state"
  baseline "$state" task3
  printf 'working: still going\n' >> "$state/task3.status"
  out=$(probe "$state" --reason "$REASON")
  assert_equals "QUIET" "$out" "an unchanged routine status is not news"
  pass "routine status line: QUIET"
}

test_home_without_baseline_is_news_and_loses_nothing() {
  local dir state out drained
  dir=$(make_case nobaseline)
  state="$dir/state"
  printf 'note: first note ever\n' > "$state/task4.status"
  out=$(probe "$state" --reason "$REASON")
  assert_contains "$out" "NEWS: no status presentation baseline" "no baseline is news"
  drained=$(FM_STATE_OVERRIDE="$state" "$DRAIN" 2>/dev/null)
  assert_contains "$drained" "first note ever" "the first drain still presents the note"
  pass "home with no presentation baseline: NEWS and nothing lost"
}

test_interrupted_handling_is_news() {
  local dir state out
  dir=$(make_case handling)
  state="$dir/state"
  printf 'announced:handling:g1\n' > "$state/.watcher-down"
  out=$(probe "$state" --reason "$REASON" --settle)
  assert_contains "$out" "NEWS: an interrupted handling episode" "handling episode needs its turn"
  assert_equals "announced:handling:g1" "$(cat "$state/.watcher-down")" "episode untouched"
  pass "interrupted handling episode: NEWS"
}

test_empty_rearm_is_quiet
test_ineligible_reasons_are_news
test_downtime_episode_settles_only_when_asked
test_queued_row_is_news_and_survives
test_note_and_decision_are_news_and_survive
test_routine_status_alone_is_quiet
test_home_without_baseline_is_news_and_loses_nothing
test_interrupted_handling_is_news

echo '# all fm-wake-drain-probe tests passed'
