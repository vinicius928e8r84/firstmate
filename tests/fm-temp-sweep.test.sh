#!/usr/bin/env bash
# Behavioral coverage for bin/fm-temp-sweep.sh: leaked temporaries are removed by prefix and age in both the tmp and state
# directories; anything young, touched inside the window, held by a live process, protected, or a live lock is kept; dry-run
# lists without deleting; --tmp-age sweeps every old tmp entry except the protected names and live task ids.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-temp-sweep.sh"

# old <path> [days]: backdate a path (and everything below it) by N days
old() { local d=${2:-5}; find "$1" -exec touch -h -d "@$(( $(date +%s) - d*86400 ))" {} +; }

fixture() {
  local root; root=$(fm_test_tmproot fm-tempsweep) || fail "tmproot"
  mkdir -p "$root/home/state" "$root/tmp"
  printf '%s\n' "$root"
}

sweep() { FM_HOME="$1/home" "$SWEEP" --tmp-dir "$1/tmp" --state-dir "$1/home/state" "${@:2}" 2>&1; }

test_rules_remove_old_leaks_and_keep_the_rest() {
  local root out s=""
  root=$(fixture); s=$root/home/state
  : > "$s/.home-summary-error.AbCdEf"; old "$s/.home-summary-error.AbCdEf"
  : > "$s/.claude-autoarm-output.ZzZzZz"
  mkdir "$s/.wake-queue.lock.owner.OLD123"; old "$s/.wake-queue.lock.owner.OLD123"
  mkdir "$root/tmp/fm-fleet-tasks.AAAAAA"; : > "$root/tmp/fm-fleet-tasks.AAAAAA/x"; old "$root/tmp/fm-fleet-tasks.AAAAAA"
  mkdir "$root/tmp/fm-fleet-snapshot.BBBBBB"; : > "$root/tmp/fm-fleet-snapshot.BBBBBB/x"; old "$root/tmp/fm-fleet-snapshot.BBBBBB"
  : > "$root/tmp/fm-fleet-snapshot.BBBBBB/fresh"                    # newest file inside the window keeps the whole directory
  mkdir "$root/tmp/fm-timeout-status.CCCCCC"; old "$root/tmp/fm-timeout-status.CCCCCC"
  : > "$root/tmp/unrelated-old-file"; old "$root/tmp/unrelated-old-file" 30
  out=$(sweep "$root" --apply)
  assert_absent "$s/.home-summary-error.AbCdEf" "old state temporary removed"
  assert_absent "$s/.wake-queue.lock.owner.OLD123" "old unowned lock directory removed"
  assert_absent "$root/tmp/fm-fleet-tasks.AAAAAA" "old tmp directory removed"
  assert_absent "$root/tmp/fm-timeout-status.CCCCCC" "old timeout-status directory removed"
  assert_present "$s/.claude-autoarm-output.ZzZzZz" "young temporary kept"
  assert_present "$root/tmp/fm-fleet-snapshot.BBBBBB" "directory with a file inside the window kept"
  assert_present "$root/tmp/unrelated-old-file" "rules mode ignores names outside the prefix table"
  assert_contains "$out" "entries" "summary printed"
  pass "rules mode removes old leaked prefixes and keeps young, busy-window and unrelated entries"
}

test_dry_run_deletes_nothing() {
  local root out
  root=$(fixture)
  : > "$root/home/state/.watch-arm-output.Q1w2E3"; old "$root/home/state/.watch-arm-output.Q1w2E3"
  out=$(sweep "$root" --dry-run)
  assert_present "$root/home/state/.watch-arm-output.Q1w2E3" "dry-run keeps the file"
  assert_contains "$out" ".watch-arm-output.Q1w2E3" "dry-run lists it"
  assert_contains "$out" "would be removed" "dry-run says would"
  pass "dry-run lists and deletes nothing"
}

test_live_process_and_live_locks_are_kept() {
  local root s pid
  root=$(fixture); s=$root/home/state
  mkdir "$root/tmp/fm-contributions.HELD01"; old "$root/tmp/fm-contributions.HELD01"
  ( cd "$root/tmp/fm-contributions.HELD01" && exec sleep 60 ) & pid=$!
  mkdir "$s/.claude-autoarm.lock.owner.LIVE01"; printf '%s\n' "$pid" > "$s/.claude-autoarm.lock.owner.LIVE01/pid"; old "$s/.claude-autoarm.lock.owner.LIVE01"
  mkdir "$s/.fm-lease-command.lock.owner.LINK01"; old "$s/.fm-lease-command.lock.owner.LINK01"
  ln -s "$s/.fm-lease-command.lock.owner.LINK01" "$s/.fm-lease-command.lock"
  sweep "$root" --apply >/dev/null
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_present "$root/tmp/fm-contributions.HELD01" "directory that is a live process cwd kept"
  assert_present "$s/.claude-autoarm.lock.owner.LIVE01" "lock owner whose pid is alive kept"
  assert_present "$s/.fm-lease-command.lock.owner.LINK01" "target of a *.lock symlink kept"
  pass "entries held by live processes or live locks are kept"
}

test_tmp_age_sweeps_everything_old_but_protected_names() {
  local root out
  root=$(fixture)
  mkdir "$root/tmp/scratch-old" "$root/tmp/fm-main" "$root/tmp/fm-fill" "$root/tmp/pmfbkey" "$root/tmp/fm-live-task-1109" "$root/tmp/young"
  : > "$root/tmp/scratch-old/f"; : > "$root/tmp/oldfile.txt"
  printf 'pid=1\n' > "$root/home/state/live-task-1109.meta"
  old "$root/tmp/scratch-old" 12; old "$root/tmp/oldfile.txt" 12; old "$root/tmp/fm-main" 12; old "$root/tmp/fm-fill" 12
  old "$root/tmp/pmfbkey" 12; old "$root/tmp/fm-live-task-1109" 12
  out=$(sweep "$root" --apply --tmp-age 7)
  assert_absent "$root/tmp/scratch-old" "old entry removed"
  assert_absent "$root/tmp/oldfile.txt" "old file removed"
  assert_present "$root/tmp/fm-main" "fm-main protected"
  assert_present "$root/tmp/fm-fill" "fm-fill protected"
  assert_present "$root/tmp/pmfbkey" "pmfbkey protected"
  assert_present "$root/tmp/fm-live-task-1109" "directory named after a task with a state record protected"
  assert_present "$root/tmp/young" "young entry kept"
  assert_contains "$out" "entries" "summary printed"
  pass "--tmp-age removes old entries except protected names, live task ids and young entries"
}

test_read_only_directories_are_removed() {
  local root
  root=$(fixture)
  mkdir -p "$root/tmp/bb-provider-bridge-provider-acp-Ro0001/hooks"; : > "$root/tmp/bb-provider-bridge-provider-acp-Ro0001/hooks/h"
  old "$root/tmp/bb-provider-bridge-provider-acp-Ro0001" 5
  chmod a-w "$root/tmp/bb-provider-bridge-provider-acp-Ro0001/hooks"
  sweep "$root" --apply >/dev/null
  assert_absent "$root/tmp/bb-provider-bridge-provider-acp-Ro0001" "read-only tree removed"
  pass "read-only directory trees are removed"
}

test_bad_usage() {
  local rc
  "$SWEEP" --tmp-age x >/dev/null 2>&1; rc=$?; expect_code 64 "$rc" "non-numeric age refused"
  "$SWEEP" --bogus >/dev/null 2>&1; rc=$?; expect_code 64 "$rc" "unknown flag refused"
  pass "bad arguments exit 64"
}

test_rules_remove_old_leaks_and_keep_the_rest
test_dry_run_deletes_nothing
test_live_process_and_live_locks_are_kept
test_tmp_age_sweeps_everything_old_but_protected_names
test_read_only_directories_are_removed
test_bad_usage

echo '# all fm-temp-sweep tests passed'
