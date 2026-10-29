#!/usr/bin/env bash
# Behavior tests for bin/fm-verification-stale.sh: records whose cited bin/ files changed after the record date.
# shellcheck disable=SC2016 # single quotes are deliberate: the backticks are literal record text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-verification-stale)
fm_git_identity fmtest fmtest@example.invalid

# commit_on <repo> <date> <message>: commit everything staged with both dates pinned.
commit_on() {
  GIT_AUTHOR_DATE="$2T12:00:00+0000" GIT_COMMITTER_DATE="$2T12:00:00+0000" git -C "$1" commit -q -m "$3"
}

make_repo() {
  local repo=$1
  mkdir -p "$repo/bin" "$repo/docs/verification"
  git init -q "$repo"
  printf '#!/usr/bin/env bash\necho one\n' > "$repo/bin/fm-fresh.sh"
  printf '#!/usr/bin/env bash\necho one\n' > "$repo/bin/fm-moving.sh"
  printf 'Verified 2026-09-01 with `bin/fm-fresh.sh`, `bin/fm-moving.sh`, and `bin/fm-gone.sh`.\n' > "$repo/docs/verification/rec.md"
  printf 'Verified 2026-09-01 against nothing in bin.\n' > "$repo/docs/verification/uncited.md"
  printf 'No date here, see bin/fm-fresh.sh.\n' > "$repo/docs/verification/undated.md"
  git -C "$repo" add -A
  commit_on "$repo" 2026-09-01 init
  printf 'echo two\n' >> "$repo/bin/fm-moving.sh"
  git -C "$repo" add -A
  commit_on "$repo" 2026-09-02 "change after the record date"
}

test_lists_only_files_changed_after_the_record_date() {
  local repo=$TMP_ROOT/repo out status
  make_repo "$repo"
  out=$("$ROOT/bin/fm-verification-stale.sh" --root "$repo"); status=$?
  expect_code 0 "$status" "listing stale records is not a failure without --check"
  assert_contains "$out" "$(printf 'STALE\trec.md\t2026-09-01\tbin/fm-moving.sh\t1\t2026-09-02')" "a file changed after the record date must be listed with count and last change"
  assert_not_contains "$out" "bin/fm-fresh.sh	" "a file untouched since the record date must not be listed"
  assert_not_contains "$out" "fm-gone" "a cited file that is not tracked must be ignored"
  assert_contains "$out" "$(printf 'UNDATED\tundated.md')" "a record with no date must be reported"
  assert_contains "$out" "$(printf 'UNCITED\tuncited.md')" "a record citing no bin/ file must be reported"
  pass "verification-stale: lists only files changed after the record date"
}

test_same_day_change_is_not_stale() {
  local repo=$TMP_ROOT/sameday out
  make_repo "$repo"
  printf 'echo three\n' >> "$repo/bin/fm-fresh.sh"
  git -C "$repo" add -A
  commit_on "$repo" 2026-09-01 "same day as the record"
  out=$("$ROOT/bin/fm-verification-stale.sh" --root "$repo" "$repo/docs/verification/rec.md")
  assert_not_contains "$out" "fm-fresh" "a change on the record's own date must not count as after it"
  pass "verification-stale: a same-day change is not stale"
}

test_check_flag_and_named_record() {
  local repo=$TMP_ROOT/check out status
  make_repo "$repo"
  out=$("$ROOT/bin/fm-verification-stale.sh" --root "$repo" --check "$repo/docs/verification/rec.md"); status=$?
  expect_code 1 "$status" "--check must fail when a stale file is listed"
  assert_not_contains "$out" "uncited.md" "only the named record may be examined"
  out=$("$ROOT/bin/fm-verification-stale.sh" --root "$repo" --check "$repo/docs/verification/uncited.md"); status=$?
  expect_code 0 "$status" "--check must pass when nothing is stale"
  pass "verification-stale: --check exit status and named records"
}

test_usage_errors() {
  local out status
  out=$("$ROOT/bin/fm-verification-stale.sh" --bogus 2>&1); status=$?
  expect_code 2 "$status" "an unknown option is a usage error"
  out=$("$ROOT/bin/fm-verification-stale.sh" --root "$TMP_ROOT" 2>&1); status=$?
  expect_code 2 "$status" "a root that is not a git repository is a usage error"
  assert_contains "$out" "not a git repository" "the refusal must say why"
  pass "verification-stale: usage errors exit 2"
}

test_lists_only_files_changed_after_the_record_date
test_same_day_change_is_not_stale
test_check_flag_and_named_record
test_usage_errors
