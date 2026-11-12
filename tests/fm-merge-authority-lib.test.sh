#!/usr/bin/env bash
# tests/fm-merge-authority-lib.test.sh - bin/fm-merge-authority-lib.sh's
# fm_merge_authority_resolve: a loop over every task must reuse one
# `fm-afk-contract.sh validate` verdict while the away-posture record is
# unchanged, and must validate again the moment the record or state/.afk
# changes, with every task's answer identical to a fresh validate.
#
# The defect this pins: the fleet snapshot's contribution input resolved the
# authority of each task by running validate again, 139 s on a contended host
# with 28 tasks, all for the same answer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-authority-lib-tests)

make_home() {  # <name> -> prints the home dir, with a valid away record
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state"
  write_record "$home" 'Away until the morning.'
  printf '%s\n' "$home"
}

write_record() {  # <home> <words-line>
  cat > "$1/state/.afk-contract" <<RECORD
version: 2
entered: 2026-09-20T01:00:00Z
entered_epoch: 1789600000
expected_return: 2026-09-20T09:00:00Z
reach_channels: none
reach_announced: No phone channel is configured; anything that needs you waits for your return.
spend_max_concurrent_workers: 3
confirmed: 2026-09-20T01:00:05Z
confirmed_epoch: 1789600005
words: |-
  $2
RECORD
}

# A validate that counts its runs, then runs the real one. The library reaches
# the script through _FM_MERGE_AUTHORITY_LIB_DIR after it has been sourced.
make_counting_validate() {  # <name> -> prints the stub dir
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir"
  cat > "$dir/fm-afk-contract.sh" <<STUB
#!/usr/bin/env bash
echo run >> "$dir/runs"
exec "$ROOT/bin/fm-afk-contract.sh" "\$@"
STUB
  chmod +x "$dir/fm-afk-contract.sh"
  printf '%s\n' "$dir"
}

runs() {  # <stub dir>
  if [ -f "$1/runs" ]; then wc -l < "$1/runs" | tr -d ' '; else echo 0; fi
}

# Resolve each task in a fresh bash process with the counting stub installed,
# printing "<id> <status> <authority> <reason>" per task.
resolve_all() {  # <home> <stub dir> <id>...
  local home=$1 stub=$2
  shift 2
  bash -c '
    . "$1/bin/fm-merge-authority-lib.sh"
    _FM_MERGE_AUTHORITY_LIB_DIR=$2
    home=$3
    shift 3
    for id in "$@"; do
      status=0
      fm_merge_authority_resolve "$home" "$home/state" "$home/state/$id.meta" "$id" || status=$?
      printf "%s %s %s %s\n" "$id" "$status" "$FM_MERGE_AUTHORITY" "$FM_MERGE_AUTHORITY_REASON"
    done
  ' _ "$ROOT" "$stub" "$home" "$@"
}

test_one_validate_serves_every_task() {
  local home stub out
  home=$(make_home many-tasks)
  stub=$(make_counting_validate many-tasks-stub)
  out=$(resolve_all "$home" "$stub" t1 t2 t3 t4 t5 t6)
  assert_equals 6 "$(printf '%s\n' "$out" | grep -c ' 0 away away$')" "every task resolves to away authority"
  assert_equals 1 "$(runs "$stub")" "validate runs once for six tasks, not once per task"
  pass "fm_merge_authority_resolve: one validate run serves every task"
}

test_a_rewritten_record_is_validated_again() {
  local home stub out
  home=$(make_home rewrite)
  stub=$(make_counting_validate rewrite-stub)
  out=$(bash -c '
    . "$1/bin/fm-merge-authority-lib.sh"
    _FM_MERGE_AUTHORITY_LIB_DIR=$2
    home=$3
    resolve() { fm_merge_authority_resolve "$home" "$home/state" "$home/state/$1.meta" "$1"; echo "$1 $? $FM_MERGE_AUTHORITY_REASON"; }
    resolve a
    resolve b
    printf "version: 9\n" > "$home/state/.afk-contract"
    resolve c
    resolve d
  ' _ "$ROOT" "$stub" "$home")
  assert_contains "$out" "a 0 away" "the first task sees the valid record"
  assert_contains "$out" "b 0 away" "the second task sees the valid record"
  assert_contains "$out" "c 1 record-unreadable" "a damaged record is not answered from the old verdict"
  assert_contains "$out" "d 1 record-unreadable" "the damaged verdict is reused too"
  assert_equals 2 "$(runs "$stub")" "validate runs again after the record changed, and only once more"
  pass "fm_merge_authority_resolve: a changed record is validated again"
}

test_a_new_away_marker_is_validated_again() {
  local home stub
  home=$(make_home marker)
  stub=$(make_counting_validate marker-stub)
  bash -c '
    . "$1/bin/fm-merge-authority-lib.sh"
    _FM_MERGE_AUTHORITY_LIB_DIR=$2
    home=$3
    fm_merge_authority_resolve "$home" "$home/state" "$home/state/a.meta" a
    : > "$home/state/.afk"
    fm_merge_authority_resolve "$home" "$home/state" "$home/state/b.meta" b
  ' _ "$ROOT" "$stub" "$home"
  assert_equals 2 "$(runs "$stub")" "state/.afk appearing invalidates the cached verdict"
  pass "fm_merge_authority_resolve: a changed state/.afk is validated again"
}

test_other_homes_and_a_missing_record_keep_their_own_answer() {
  local home other stub out
  home=$(make_home home-one)
  other=$(make_home home-two)
  write_record "$other" 'Different words, different size of record.'
  mkdir -p "$TMP_ROOT/bare/state"
  stub=$(make_counting_validate homes-stub)
  out=$(bash -c '
    . "$1/bin/fm-merge-authority-lib.sh"
    _FM_MERGE_AUTHORITY_LIB_DIR=$2
    for home in "$3" "$4" "$5" "$3"; do
      fm_merge_authority_resolve "$home" "$home/state" "$home/state/a.meta" a
      echo "$? $FM_MERGE_AUTHORITY_REASON"
    done
  ' _ "$ROOT" "$stub" "$home" "$other" "$TMP_ROOT/bare")
  assert_equals $'0 away\n0 away\n0 attended\n0 away' "$out" "each home gets the answer of its own record"
  assert_equals 3 "$(runs "$stub")" "a home with no record never runs validate; returning to a home validates it again"
  pass "fm_merge_authority_resolve: the cache is keyed by home and record"
}

fm_test_run \
  test_one_validate_serves_every_task \
  test_a_rewritten_record_is_validated_again \
  test_a_new_away_marker_is_validated_again \
  test_other_homes_and_a_missing_record_keep_their_own_answer
