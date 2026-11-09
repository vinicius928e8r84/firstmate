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

test_prs_the_local_records_show_merged_are_counted_not_listed() {
  local dir state data now out base
  dir=$(make_case recordsmerged)
  state="$dir/state"
  data="$dir/data"
  now=$(date +%s)
  base=https://example.test/o/r/pull
  mkdir -p "$state/parked-x" "$data/gone"
  {
    printf 'done [at=%s]: %s/701 MERGE-READY marker\n' $((now - 7200)) "$base"
    printf 'done [at=%s]: %s/702 MERGE-READY wake\n' $((now - 7100)) "$base"
    printf 'done [at=%s]: %s/703 MERGE-READY parked\n' $((now - 7000)) "$base"
    printf 'done [at=%s]: %s/704 MERGE-READY cached\n' $((now - 6900)) "$base"
    printf 'done [at=%s]: %s/705 MERGE-READY genuinely waiting\n' $((now - 6800)) "$base"
  } > "$state/mm-sm.status"
  # 701: merge-notified marker (provider, host, path, number) with poll data.
  printf 'fm-pr-poll-merge-notified-v1\ngithub\nexample.test\no/r\n701\n' > "$state/t701.pr-poll-merge-notified"
  printf 'github\n%s/701\nexample.test\no/r\n701\n' "$base" > "$state/t701.pr-poll"
  # 702: a merge-landed row still queued.
  printf '1\t%s\tcheck\tmerged-t702\tcheck: merge landed: t702 %s/702\n' "$now" "$base" > "$state/.wake-queue"
  # 703: a parked stand-in's poll data.
  printf 'github\n%s/703\nexample.test\no/r\n703\n' "$base" > "$state/parked-x/s703.pr-poll"
  # 704: a saved contribution observation that says merged.
  printf '{"records":[{"url":"%s/704","observation":{"state":"merged"}}]}\n' "$base" > "$data/gone/contributions.json"

  out=$(FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" "$DRAIN") || fail "drain failed: $out"
  for n in 701 702 703 704; do
    if grep -F "MERGE-READY waiting" <<<"$out" | grep -F "/$n " >/dev/null; then fail "recorded-merged PR $n still listed: $out"; fi
  done
  grep -F "$base/705 MERGE-READY waiting" <<<"$out" >/dev/null || fail "the genuinely waiting PR vanished: $out"
  grep -F 'MERGE-READY WAITING: 4 more not listed' <<<"$out" >/dev/null || fail "omitted PRs were not counted: $out"
  pass "PRs the local records already show merged are counted on one line, not listed"
}

test_a_row_naming_only_pr_number_matches_by_number_in_the_tasks_own_repository() {
  local dir state data now out
  dir=$(make_case bynumber)
  state="$dir/state"
  data="$dir/data"
  now=$(date +%s)
  mkdir -p "$data"
  printf 'kind=secondmate\nprojects=core,other-lib\nproject=/home/x/firstmate\n' > "$state/sm.meta"
  {
    printf 'done [at=%s]: PR 801 MERGE-READY plain row\n' $((now - 7200))
    printf 'done [at=%s]: PR 802 MERGE-READY but this is about sibling-app, not core\n' $((now - 7100))
    printf 'done [at=%s]: PR 803 MERGE-READY number merged only elsewhere\n' $((now - 7000))
    printf 'done [at=%s]: PR 804 MERGE-READY genuinely waiting\n' $((now - 6900))
  } > "$state/sm.status"
  # 801 merged in core, 802 merged in core AND the row names sibling-app,
  # 803 merged only in sibling-app, which is not one of the task's repositories.
  {
    printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/core\n801\n' > "$state/t801.pr-poll-merge-notified"
    printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/core\n802\n' > "$state/t802.pr-poll-merge-notified"
    printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/sibling-app\n803\n' > "$state/t803.pr-poll-merge-notified"
    printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/sibling-app\n802\n' > "$state/t802b.pr-poll-merge-notified"
  }
  out=$(FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" "$DRAIN") || fail "drain failed: $out"
  if grep -F 'MERGE-READY waiting' <<<"$out" | grep -F 'sm PR 801' >/dev/null; then fail "a number merged in the task's own repository was still listed: $out"; fi
  grep -F 'sm PR 802 MERGE-READY waiting' <<<"$out" >/dev/null || fail "a row naming a sibling repository was dropped by number: $out"
  grep -F 'sm PR 803 MERGE-READY waiting' <<<"$out" >/dev/null || fail "a number merged only in another repository dropped the row: $out"
  grep -F 'sm PR 804 MERGE-READY waiting' <<<"$out" >/dev/null || fail "the genuinely waiting row vanished: $out"
  grep -F 'MERGE-READY WAITING: 1 more not listed' <<<"$out" >/dev/null || fail "the one omitted row was not counted: $out"
  pass "a row naming only PR <n> drops by number inside the task's own repositories, never across repositories"
}

test_only_done_and_needs_decision_lines_report_ready_and_a_no_negates() {
  local dir state now out
  dir=$(make_case verbs)
  state="$dir/state"
  now=$(date +%s)
  {
    printf 'working [at=%s]: PR 901 will be MERGE-READY once CI is green\n' $((now - 7200))
    printf 'done [at=%s]: PR 902 opened (no MERGE-READY yet, review pending)\n' $((now - 7100))
    printf 'done [at=%s]: PR 903 not MERGE-READY, one P1 open\n' $((now - 7000))
    printf 'needs-decision [at=%s]: PR 904 MERGE-READY, captain call needed\n' $((now - 6900))
    printf 'done [at=%s]: PR 905 MERGE-READY\n' $((now - 6800))
  } > "$state/sm.status"
  out=$(drain_case "$dir")
  for n in 901 902 903; do
    if grep -F 'MERGE-READY waiting' <<<"$out" | grep -F "PR $n " >/dev/null; then fail "PR $n was listed as ready: $out"; fi
  done
  grep -F 'sm PR 904 MERGE-READY waiting' <<<"$out" >/dev/null || fail "a needs-decision ready report was dropped: $out"
  grep -F 'sm PR 905 MERGE-READY waiting' <<<"$out" >/dev/null || fail "a done ready report was dropped: $out"
  pass "only done and needs-decision lines report a PR ready, and no/not MERGE-READY negates it"
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
test_prs_the_local_records_show_merged_are_counted_not_listed
test_a_row_naming_only_pr_number_matches_by_number_in_the_tasks_own_repository
test_only_done_and_needs_decision_lines_report_ready_and_a_no_negates
test_old_reports_and_clean_fleets_print_nothing
