#!/usr/bin/env bash
# Behavioral coverage for bin/fm-close-finished-lanes.sh over fake task state and fake
# crew-state/teardown/hold commands (no real workers): a finished scout with a report closes
# with its logs archived first, an unlanded ship is kept when teardown refuses and is never
# forced, a held or open-decision task is kept, secondmates are skipped, live tasks are kept,
# the per-run cap holds, --dry-run changes nothing, and a concurrent run does nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-close-finished-lanes)
CLOSE="$ROOT/bin/fm-close-finished-lanes.sh"

# make_world <name>: a home with fake crew-state, teardown and hold commands.
# Per-task fixtures: $W/cs/<id> (state word), $W/hold/<id> (hold exit code),
# $W/refuse/<id> (teardown refusal text). Teardown logs its argv to $W/td.log.
make_world() {
  W="$TMP_ROOT/$1"
  mkdir -p "$W/home/state" "$W/home/data" "$W/cs" "$W/hold" "$W/refuse" "$W/pr"
  cat > "$W/crew-state" <<SH
#!/usr/bin/env bash
echo "state: \$(cat "$W/cs/\$1" 2>/dev/null || echo unknown) · source: status-log"
SH
  cat > "$W/hold-cmd" <<SH
#!/usr/bin/env bash
exit \$(cat "$W/hold/\$2" 2>/dev/null || echo 1)
SH
  cat > "$W/teardown" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$W/td.log"
if [ -f "$W/refuse/\$1" ]; then cat "$W/refuse/\$1" >&2; exit 1; fi
rm -f "$W/home/state/\$1.meta"
echo "torn down \$1"
SH
  cat > "$W/pr-cmd" <<SH
#!/usr/bin/env bash
# fake PR reader: prints the fixture $W/pr/<last url segment>, exits 0 only for merged
v=\$(cat "$W/pr/\${1##*/}" 2>/dev/null || echo unknown); echo "\$v"; [ "\$v" = merged ]
SH
  chmod +x "$W/pr-cmd" "$W/crew-state" "$W/hold-cmd" "$W/teardown"
}

# add_task <id> <kind> <state> [meta-extra...]
add_task() {
  local id=$1 kind=$2 st=$3
  shift 3
  fm_write_meta "$W/home/state/$id.meta" "kind=$kind" "worktree=$W/wt-$id" "$@"
  printf 'done [at=1]: finished\n' > "$W/home/state/$id.status"
  printf '%s\n' "$st" > "$W/cs/$id"
}

# run_close [args]: REAL_PR_READER set (even empty) swaps the fake PR reader for the real one.
run_close() {
  HOME="$TMP_ROOT/h" FM_HOME="$W/home" FM_LANE_CLOSE_CREW_STATE_CMD="$W/crew-state" \
    FM_LANE_CLOSE_TEARDOWN_CMD="$W/teardown" FM_LANE_CLOSE_HOLD_CMD="$W/hold-cmd" FM_LANE_CLOSE_PR_CMD="${REAL_PR_READER:+}${REAL_PR_READER-$W/pr-cmd}" \
    bash "$CLOSE" "$@" 2>&1
}

test_done_scout_with_report_closes_and_archives() {
  make_world close
  mkdir -p "$W/tmp-s1" "$W/home/data/s1"
  echo "pipeline log" > "$W/tmp-s1/run.log"
  echo "ignore" > "$W/tmp-s1/binary.dat"
  echo report > "$W/home/data/s1/report.md"
  add_task s1 scout "done" "tasktmp=$W/tmp-s1"
  out=$(run_close --apply)
  assert_contains "$out" "closed: s1" "finished scout with a report must close"
  assert_contains "$out" "1 closed, 0 kept, 0 skipped" "summary counts the close"
  assert_absent "$W/home/state/s1.meta" "teardown ran"
  arch=$(echo "$W"/home/data/s1/archive-*)
  assert_present "$arch/status.log" "status log archived"
  assert_present "$arch/meta" "metadata archived"
  assert_present "$arch/tasktmp/run.log" "tasktmp log archived"
  assert_absent "$arch/tasktmp/binary.dat" "only logs are archived"
  assert_equals "s1" "$(cat "$W/td.log")" "teardown called with the id and never --force"
  pass "done scout with report closes after archiving its logs"
}

test_scout_without_report_is_kept() {
  make_world noreport
  add_task s2 scout "done"
  out=$(run_close --apply)
  assert_contains "$out" "kept: s2 scout has no report" "no report keeps the scout"
  assert_absent "$W/td.log" "no teardown attempted"
  pass "scout without a report is kept"
}

test_unlanded_ship_refusal_is_reported_not_forced() {
  make_world refuse
  add_task sh1 ship "done" "pr=https://example.test/o/r/pull/11"
  echo merged > "$W/pr/11"
  echo "REFUSED: sh1 has unlanded commits" > "$W/refuse/sh1"
  out=$(run_close --apply)
  assert_contains "$out" "kept: sh1 teardown refused (exit 1): REFUSED: sh1 has unlanded commits" "refusal is reported"
  assert_equals "sh1" "$(cat "$W/td.log")" "refusal is never retried with --force"
  assert_present "$W/home/state/sh1.meta" "refused lane untouched"
  assert_equals "" "$(ls "$W/home/data/sh1" 2>/dev/null)" "archive of a refused lane is removed"
  pass "teardown refusal is reported and never forced"
}

test_held_and_open_decision_tasks_are_kept() {
  make_world held
  add_task h1 ship "done" "pr=https://example.test/o/r/pull/21"
  echo merged > "$W/pr/21"
  add_task h2 ship "done" "pr=https://example.test/o/r/pull/22"
  echo merged > "$W/pr/22"
  add_task h3 ship "done" "pr=https://example.test/o/r/pull/23"
  echo merged > "$W/pr/23"
  add_task h4 ship "done" "pr=https://example.test/o/r/pull/24"
  echo merged > "$W/pr/24"
  echo 0 > "$W/hold/h1"
  echo 2 > "$W/hold/h2"
  printf 'needs-decision [at=1] [key=q1]: pick\n' > "$W/home/state/h3.status"
  out=$(run_close --apply)
  assert_contains "$out" "kept: h1 open captain hold" "open hold keeps the task"
  assert_contains "$out" "kept: h2 captain hold state unknown" "unknown hold state keeps the task"
  assert_contains "$out" "kept: h3 open decision in status log" "open decision keeps the task"
  assert_contains "$out" "closed: h4" "the unheld task closes"
  assert_equals "h4" "$(cat "$W/td.log")" "only the unheld task reached teardown"
  pass "held and open-decision tasks are kept"
}

test_secondmate_and_live_tasks_are_left_alone() {
  make_world live
  add_task m1 secondmate "done"
  add_task r1 ship working
  add_task r2 ship unknown
  out=$(run_close --apply)
  assert_contains "$out" "skipped: m1 secondmate" "secondmate skipped"
  assert_contains "$out" "kept: r1 not finished (state: working)" "live task kept"
  assert_contains "$out" "kept: r2 not finished (state: unknown)" "unreadable task kept"
  assert_absent "$W/td.log" "nothing torn down"
  pass "secondmates and live tasks are left alone"
}

test_cap_dry_run_and_lock() {
  make_world cap
  add_task c1 ship "done" "pr=https://example.test/o/r/pull/31"
  echo merged > "$W/pr/31"
  add_task c2 ship "done" "pr=https://example.test/o/r/pull/32"
  echo merged > "$W/pr/32"
  add_task c3 ship "done" "pr=https://example.test/o/r/pull/33"
  echo merged > "$W/pr/33"
  out=$(run_close --dry-run --max 2)
  assert_contains "$out" "would close: c1" "dry-run lists candidates"
  assert_contains "$out" "kept: c3 per-run cap of 2 reached, not examined" "cap applies"
  assert_absent "$W/td.log" "dry-run tears nothing down"
  assert_present "$W/home/state/c1.meta" "dry-run keeps state"
  out=$(run_close --apply --max 2)
  assert_contains "$out" "2 closed, 1 kept" "apply honours the cap"
  assert_present "$W/home/state/c3.meta" "task past the cap stays"
  out=$(run_close --apply --budget 10)
  assert_contains "$out" "kept: c3 time budget of 10s reached before it was checked" "a budget that cannot cover one teardown stops cleanly"
  ( exec 8> "$W/home/state/.lane-close.lock"; flock -n 8 && out=$(run_close --apply) && echo "$out" > "$W/locked.out" )
  assert_contains "$(cat "$W/locked.out")" "another run holds the lock" "concurrent run is excluded"
  pass "cap, dry-run, budget and lock behave"
}

test_ship_with_open_or_unreadable_pr_is_kept() {
  make_world openpr
  add_task p1 ship "done" "pr=https://example.test/o/r/pull/41"
  add_task p2 ship "done" "pr=https://example.test/o/r/pull/42"
  add_task p3 ship "done" "pr=https://example.test/o/r/pull/43"
  echo open > "$W/pr/41"
  echo merged > "$W/pr/42"
  out=$(run_close --apply)
  assert_contains "$out" "kept: p1 PR not merged (open)" "an open PR keeps the ship"
  assert_contains "$out" "kept: p3 PR not merged (unknown)" "an unreadable PR keeps the ship"
  assert_contains "$out" "closed: p2" "a merged PR closes the ship"
  assert_equals "p2" "$(cat "$W/td.log")" "only the merged ship reached teardown"
  assert_present "$W/home/state/p1.meta" "open-PR ship keeps its record for the guarded merge"
  pass "ship with an open or unreadable PR is kept"
}

test_prless_ship_needs_branch_on_local_default() {
  make_world local
  local proj="$W/proj"
  git init -q -b main "$proj"
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$proj" worktree add -q -b fm/l1 "$W/wt-l1"
  git -C "$proj" worktree add -q -b fm/l2 "$W/wt-l2"
  git -C "$W/wt-l2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
  add_task l1 ship "done" "project=$proj" "branch=fm/l1" "mode=local-only"
  add_task l2 ship "done" "project=$proj" "branch=fm/l2" "mode=local-only"
  fm_write_meta "$W/home/state/l1.meta" "kind=ship" "worktree=$W/wt-l1" "project=$proj" "branch=fm/l1" "mode=local-only"
  fm_write_meta "$W/home/state/l2.meta" "kind=ship" "worktree=$W/wt-l2" "project=$proj" "branch=fm/l2" "mode=local-only"
  out=$(run_close --apply)
  assert_contains "$out" "closed: l1" "a branch already on local main closes"
  assert_contains "$out" "kept: l2 no merged PR recorded and branch not on main" "an unmerged ready branch is kept"
  pass "PR-less ship closes only when its branch is on the local default branch"
}

test_archive_copy_failure_keeps_the_lane() {
  make_world archfail
  add_task a1 ship "done" "pr=https://example.test/o/r/pull/51" "tasktmp=$W/tmp-a1"
  echo merged > "$W/pr/51"
  mkdir -p "$W/tmp-a1"
  echo log > "$W/tmp-a1/x.log"
  chmod 000 "$W/tmp-a1/x.log"
  if [ -r "$W/tmp-a1/x.log" ]; then chmod 644 "$W/tmp-a1/x.log"; pass "skipped archive-failure case (running as a user that reads mode 000)"; return 0; fi
  out=$(run_close --apply)
  chmod 644 "$W/tmp-a1/x.log"
  assert_contains "$out" "kept: a1 could not save archive" "a failed copy keeps the lane"
  assert_absent "$W/td.log" "no teardown after a failed archive"
  pass "archive copy failure keeps the lane"
}

test_real_pr_reader_call_shape() {
  make_world realpr
  add_task g1 ship "done" "pr=https://github.com/octo/repo/pull/61"
  add_task g2 ship "done" "pr=https://github.com/octo/repo/pull/62"
  local fakebin
  fakebin=$(fm_fakebin "$W/fakebin")
  # Answers only a graphql read shaped like the real helper's: owner, repo, number as three -F fields.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"owner=octo"*"repo=repo"*"number=61"*) printf 'state=MERGED\nmerged=true\n' ;;
  *"owner=octo"*"repo=repo"*"number=62"*) printf 'state=OPEN\nmerged=false\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh"
  out=$(PATH="$fakebin:$PATH" REAL_PR_READER='' run_close --apply)
  assert_contains "$out" "closed: g1" "a merged PR read through the real reader closes the ship"
  assert_contains "$out" "kept: g2 PR not merged (open)" "an open PR read through the real reader keeps the ship"
  pass "the real PR reader is called with the shape the helper expects"
}

# The lane must have been finished for the whole quiet period (default 6 h) before it closes.
test_a_lane_closes_only_after_its_quiet_period() {
  make_world ttl
  add_task t1 ship "done" "pr=https://example.test/o/r/pull/71"
  add_task t2 ship "done" "pr=https://example.test/o/r/pull/72"
  add_task t3 scout "done"
  echo merged > "$W/pr/71"; echo merged > "$W/pr/72"; mkdir -p "$W/home/data/t3"; echo r > "$W/home/data/t3/report.md"
  printf 'done [at=%s]: finished\n' "$(( $(date +%s) - 600 ))" > "$W/home/state/t1.status"
  printf 'done [at=%s]: finished\n' "$(( $(date +%s) - 21700 ))" > "$W/home/state/t2.status"
  printf 'turn-ended without a stamp\n' > "$W/home/state/t3.status"   # no time in the line: the file's last write counts
  touch -d '2 hours ago' "$W/home/state/t3.status"
  out=$(run_close --apply)
  assert_contains "$out" "waits for its 21600s quiet period" "a lane that ended ten minutes ago must wait"
  assert_contains "$out" "closed: t2" "a lane finished more than six hours ago closes"
  assert_contains "$out" "kept: t3 finished" "a lane with an unstamped line counts from the file's last write"
  assert_equals "t2" "$(cat "$W/td.log")" "only the lane past its quiet period reached teardown"
  out=$(FM_LANE_CLOSE_TTL=300 run_close --apply --max 1)
  assert_contains "$out" "closed: t1" "FM_LANE_CLOSE_TTL sets the quiet period"
  add_task t4 ship "done" "pr=https://example.test/o/r/pull/74"
  echo merged > "$W/pr/74"
  printf 'done [at=%s]: finished\n' "$(date +%s)" > "$W/home/state/t4.status"
  out=$(run_close --apply --ttl 0)
  assert_contains "$out" "closed: t4" "--ttl 0 turns the wait off"
  pass "a lane closes only after its quiet period"
}

test_dirty_inbox_and_waiting_spawn_keep_the_lane() {
  make_world guards
  local proj="$W/proj" other="$W/other" i
  git init -q -b main "$proj"; git init -q -b main "$other"
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$proj" worktree add -q -b fm/g1 "$W/wt-g1"
  git -C "$proj" worktree add -q -b fm/g2 "$W/wt-g2"
  git -C "$proj" worktree add -q -b fm/g3 "$W/wt-g3"
  git -C "$proj" worktree add -q -b fm/g4 "$W/wt-g4"
  for i in g1 g2 g3 g4; do
    fm_write_meta "$W/home/state/$i.meta" "kind=ship" "worktree=$W/wt-$i" "project=$proj" "branch=fm/$i" "mode=local-only"
    printf 'done [at=1]: finished\n' > "$W/home/state/$i.status"; echo done > "$W/cs/$i"
  done
  echo scratch > "$W/wt-g1/untracked.txt"
  mkdir -p "$W/home/state/g2.inbox"; echo "please look" > "$W/home/state/g2.inbox/003.msg"
  mkdir -p "$W/home/state/.spawn-waiting"
  printf 'pid=%s\nproject=%s\nat=1\n' "$$" "$proj" > "$W/home/state/.spawn-waiting/newtask"
  out=$(run_close --apply)
  assert_contains "$out" "kept: g1 uncommitted changes in its local copy" "an untracked file keeps the lane"
  assert_contains "$out" "kept: g2 unhandled steering message in its inbox" "an unhandled message keeps the lane"
  assert_contains "$out" "kept: g3 yields to the spawn of newtask waiting for the same project" "a waiting spawn for the project is served first"
  assert_absent "$W/td.log" "a guarded lane reached teardown"
  # a marker whose spawn is gone, or for another project, no longer holds anything back
  printf 'pid=%s\nproject=%s\nat=1\n' "99999999" "$proj" > "$W/home/state/.spawn-waiting/newtask"
  printf 'pid=%s\nproject=%s\nat=1\n' "$$" "$other" > "$W/home/state/.spawn-waiting/other"
  out=$(run_close --apply --max 1)
  assert_contains "$out" "closed: g3" "a stale or foreign marker must not hold a lane back"
  assert_contains "$(cat "$W/home/state/.resil.log")" "task=g3 cause=finished-lane action=close" "the close was not logged"
  pass "uncommitted changes, an unhandled message and a waiting spawn each keep a lane; stale markers do not"
}

test_usage_error() {
  make_world usage
  run_close --bogus > /dev/null; rc=$?
  assert_equals 64 "$rc" "unknown flag is a usage error"
  pass "usage error exits 64"
}

test_done_scout_with_report_closes_and_archives
test_scout_without_report_is_kept
test_unlanded_ship_refusal_is_reported_not_forced
test_held_and_open_decision_tasks_are_kept
test_secondmate_and_live_tasks_are_left_alone
test_cap_dry_run_and_lock
test_ship_with_open_or_unreadable_pr_is_kept
test_prless_ship_needs_branch_on_local_default
test_archive_copy_failure_keeps_the_lane
test_real_pr_reader_call_shape
test_a_lane_closes_only_after_its_quiet_period
test_dirty_inbox_and_waiting_spawn_keep_the_lane
test_usage_error

echo '# all fm-close-finished-lanes tests passed'
