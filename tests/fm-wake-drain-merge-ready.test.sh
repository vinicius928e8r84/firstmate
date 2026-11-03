#!/usr/bin/env bash
# tests/fm-wake-drain-merge-ready.test.sh - behavior tests for the MERGE-READY
# WAITING section bin/fm-wake-drain.sh prints from the status logs: every PR a
# task reported MERGE-READY that no later status line says was merged, so a
# routine line appended afterwards cannot bury the captain's pending merge call.
# The tests drive the real drain over crafted status logs and assert on its
# printed output.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-merge-ready-tests)

drain_case() {  # <case-dir> -> drain output on stdout
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" || fail "drain failed in $1"
}

test_buried_merge_ready_is_listed_with_its_age() {
  local dir state now out
  dir=$(make_case buried)
  state="$dir/state"
  now=$(date +%s)
  {
    printf 'done [at=%s]: PR 605 https://example.test/o/r/pull/605 MERGE-READY risk BAIXA\n' $((now - 7200))
    printf 'working [at=%s]: next issue, 2 of 5 tests written\n' $((now - 3600))
    printf 'working [at=%s]: still on the next issue\n' $((now - 60))
  } > "$state/mm-sm.status"
  out=$(drain_case "$dir")
  grep -F 'MERGE-READY WAITING' <<<"$out" >/dev/null || fail "buried MERGE-READY produced no section: $out"
  grep -F 'mm-sm https://example.test/o/r/pull/605 MERGE-READY waiting 2h: ' <<<"$out" >/dev/null \
    || fail "listed row lacked its task, URL, and age: $out"
  pass "a MERGE-READY buried under later routine lines is listed with its wait"
}

test_every_waiting_report_is_listed_oldest_first() {
  local dir state now out first second
  dir=$(make_case several)
  state="$dir/state"
  now=$(date +%s)
  printf 'done [at=%s]: PR 12 MERGE-READY newer\n' $((now - 3600)) > "$state/aa.status"
  printf 'done [at=%s]: PR 7 MERGE-READY older\n' $((now - 36000)) > "$state/bb.status"
  printf 'done [at=%s]: PR 9 MERGE-READY mid\n' $((now - 7200)) >> "$state/bb.status"
  out=$(drain_case "$dir")
  first=$(grep -n 'MERGE-READY waiting' <<<"$out" | sed -n 1p)
  second=$(grep -n 'MERGE-READY waiting' <<<"$out" | sed -n 3p)
  grep -F 'bb PR 7 MERGE-READY waiting 10h' <<<"$first" >/dev/null || fail "oldest report was not first: $out"
  grep -F 'aa PR 12 MERGE-READY waiting 1h' <<<"$second" >/dev/null || fail "newest report was not last: $out"
  pass "every waiting report is listed, oldest first, across tasks"
}

test_a_later_merge_line_retires_the_report() {
  local dir state now out
  dir=$(make_case merged)
  state="$dir/state"
  now=$(date +%s)
  {
    printf 'done [at=%s]: PR 600 MERGE-READY\n' $((now - 9000))
    printf 'done [at=%s]: PR 601 MERGE-READY\n' $((now - 8000))
    printf 'done [at=%s]: ack, 600 merged and cleaned up\n' $((now - 100))
  } > "$state/mm-sm.status"
  out=$(drain_case "$dir")
  if grep -F 'PR 600' <<<"$out" >/dev/null; then fail "a merged PR still listed: $out"; fi
  grep -F 'PR 601 MERGE-READY waiting' <<<"$out" >/dev/null || fail "the unmerged sibling vanished: $out"
  # A merge line from another task retires it too, and "not merged" does not.
  printf 'done [at=%s]: PR 601 is not merged yet\n' "$now" >> "$state/mm-sm.status"
  out=$(drain_case "$dir")
  grep -F 'PR 601 MERGE-READY waiting' <<<"$out" >/dev/null || fail "'not merged' retired the report: $out"
  printf 'done [at=%s]: merged 601 into main\n' "$now" > "$state/main-side.status"
  out=$(drain_case "$dir")
  if grep -F 'MERGE-READY WAITING' <<<"$out" >/dev/null; then fail "cross-task merge did not retire: $out"; fi
  pass "a later merge line retires its PR, a negated one does not, another task's counts"
}

test_url_report_is_retired_only_by_its_own_url() {
  local dir state now out
  dir=$(make_case url)
  state="$dir/state"
  now=$(date +%s)
  {
    printf 'done [at=%s]: https://example.test/a/b/pull/55 MERGE-READY\n' $((now - 5000))
    printf 'done [at=%s]: merged https://example.test/c/d/pull/55\n' $((now - 100))
  } > "$state/t1.status"
  out=$(drain_case "$dir")
  grep -F 'https://example.test/a/b/pull/55 MERGE-READY waiting' <<<"$out" >/dev/null \
    || fail "another repository's merge retired this PR: $out"
  printf 'done [at=%s]: merged https://example.test/a/b/pull/55\n' "$now" >> "$state/t1.status"
  out=$(drain_case "$dir")
  if grep -F 'MERGE-READY WAITING' <<<"$out" >/dev/null; then fail "its own merge URL did not retire it: $out"; fi
  pass "a URL-named report is retired only by that exact URL"
}

test_old_reports_and_clean_fleets_print_nothing() {
  local dir state now out
  dir=$(make_case quiet)
  state="$dir/state"
  now=$(date +%s)
  printf 'done [at=%s]: PR 3 MERGE-READY long forgotten\n' $((now - 10 * 86400)) > "$state/old.status"
  printf 'working [at=%s]: routine\n' "$now" > "$state/calm.status"
  out=$(drain_case "$dir")
  if grep -F 'MERGE-READY WAITING' <<<"$out" >/dev/null; then fail "an old or absent report printed: $out"; fi
  pass "reports past the age cap and fleets with none print nothing"
}

test_buried_merge_ready_is_listed_with_its_age
test_every_waiting_report_is_listed_oldest_first
test_a_later_merge_line_retires_the_report
test_url_report_is_retired_only_by_its_own_url
test_old_reports_and_clean_fleets_print_nothing
