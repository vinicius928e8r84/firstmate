#!/usr/bin/env bash
# Behavioral coverage for bin/fm-pr-merge-main.sh: a clean merge of the base
# into a PR branch, the already-current no-op, a conflict that stops with the
# conflicted files listed, the cheap --check commands, the refusals for a dirty
# worktree, and the review-pin report on an unpushed merge commit. The script
# must never push, so every case also asserts the origin did not move.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity

TMP_ROOT=$(fm_test_tmproot fm-pr-merge-main)
MERGE_MAIN="$ROOT/bin/fm-pr-merge-main.sh"

# Every merge needs a registered commit identity; the default home registers one
# for the worlds' shared repo name "origin". Individual tests build their own homes.
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/config"
printf '%s\n' '# project identity' 'origin pinned@example.com Pinned Author' > "$FM_HOME/config/commit-identity"

# make_world <name>: origin with a three-file main, a clone "pr" on branch feat
# carrying one own commit to a.txt. Prints the world directory.
make_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w"
  git init -q -b main "$w/seed"
  printf 'a1\na2\na3\n' > "$w/seed/a.txt"
  printf 'b1\nb2\nb3\n' > "$w/seed/b.txt"
  git -C "$w/seed" add . && git -C "$w/seed" commit -qm seed
  git clone -q --bare "$w/seed" "$w/origin.git"
  git clone -q "file://$w/origin.git" "$w/pr"
  git -C "$w/pr" checkout -q -b feat
  printf 'a1\nOWN\na3\n' > "$w/pr/a.txt"
  git -C "$w/pr" commit -qam 'own change'
  printf '%s\n' "$w"
}

# advance_main <world> <file> <content>: land one commit on origin's main.
advance_main() {
  git clone -q "file://$1/origin.git" "$1/pusher"
  printf '%s' "$3" > "$1/pusher/$2"
  git -C "$1/pusher" add -A
  git -C "$1/pusher" commit -qm "main moves $2"
  git -C "$1/pusher" push -q origin main
  fm_test_remove_tree "$1/pusher"
}

origin_refs() { git -C "$1/origin.git" for-each-ref --format='%(refname) %(objectname)'; }

test_clean_merge() {
  local w out rc before
  w=$(make_world clean)
  advance_main "$w" b.txt $'b1\nB-main\nb3\n'
  before=$(origin_refs "$w")
  out=$("$MERGE_MAIN" --worktree "$w/pr" 2>&1); rc=$?
  expect_code 0 "$rc" "clean merge exit"
  assert_contains "$out" "MERGE-CLEAN" "clean merge is reported"
  assert_equals 3 "$(git -C "$w/pr" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" "head is a two-parent merge commit"
  assert_equals "B-main" "$(sed -n 2p "$w/pr/b.txt")" "main's change arrived"
  assert_equals "OWN" "$(sed -n 2p "$w/pr/a.txt")" "own change kept"
  assert_equals "$before" "$(origin_refs "$w")" "nothing was pushed"
  pass "clean merge: merged, reported, not pushed"
}

test_already_current() {
  local w out rc head
  w=$(make_world current)
  head=$(git -C "$w/pr" rev-parse HEAD)
  out=$("$MERGE_MAIN" --worktree "$w/pr" 2>&1); rc=$?
  expect_code 0 "$rc" "already-current exit"
  assert_contains "$out" "ALREADY-CURRENT origin/main" "no-op is reported"
  assert_equals "$head" "$(git -C "$w/pr" rev-parse HEAD)" "head unchanged"
  pass "already current: no-op"
}

test_conflict_stops_with_files() {
  local w out rc
  w=$(make_world conflict)
  advance_main "$w" a.txt $'a1\nTHEIRS\na3\n'
  out=$("$MERGE_MAIN" --worktree "$w/pr" --check 'echo SHOULD-NOT-RUN' 2>&1); rc=$?
  expect_code 10 "$rc" "conflict exit"
  assert_contains "$out" "MERGE-CONFLICT" "conflict is reported"
  assert_contains "$out" "  conflicted: a.txt" "conflicted file is listed"
  assert_not_contains "$out" "SHOULD-NOT-RUN" "checks do not run on a conflict"
  [ -e "$(git -C "$w/pr" rev-parse --absolute-git-dir)/MERGE_HEAD" ] || fail "merge is left in progress for the model"
  out=$("$MERGE_MAIN" --worktree "$w/pr" 2>&1); rc=$?
  expect_code 3 "$rc" "second run refuses while the merge is open"
  pass "conflict: stops, lists files, leaves the merge open"
}

test_checks() {
  local w out rc
  w=$(make_world checks)
  advance_main "$w" b.txt $'b1\nB-main\nb3\n'
  out=$("$MERGE_MAIN" --worktree "$w/pr" --check 'grep -q B-main b.txt && echo CHECK-ONE-RAN' --check 'echo CHECK-TWO-RAN' 2>&1); rc=$?
  expect_code 0 "$rc" "passing checks exit"
  assert_contains "$out" "CHECK-ONE-RAN" "first check ran in the worktree"
  assert_contains "$out" "CHECK-TWO-RAN" "second check ran"
  w=$(make_world checks-fail)
  advance_main "$w" b.txt $'b1\nB-main\nb3\n'
  out=$("$MERGE_MAIN" --worktree "$w/pr" --check 'false' --check 'echo NEVER' 2>&1); rc=$?
  expect_code 11 "$rc" "failing check exit"
  assert_contains "$out" "CHECK-FAILED false" "failing check is named"
  assert_not_contains "$out" "NEVER" "later checks are skipped"
  pass "checks: run after a clean merge, first failure stops"
}

test_dirty_refused() {
  local w out rc
  w=$(make_world dirty)
  advance_main "$w" b.txt $'b1\nB-main\nb3\n'
  printf 'x\n' >> "$w/pr/a.txt"
  out=$("$MERGE_MAIN" --worktree "$w/pr" 2>&1); rc=$?
  expect_code 3 "$rc" "dirty exit"
  assert_contains "$out" "uncommitted changes" "dirty worktree is refused"
  assert_equals "OWN" "$(sed -n 2p "$w/pr/a.txt")" "worktree untouched"
  pass "dirty worktree: refused"
}

test_verify_only_refuses_an_open_merge() {
  local w out rc
  w=$(make_world verify-open)
  advance_main "$w" a.txt $'a1\nTHEIRS\na3\n'
  "$MERGE_MAIN" --worktree "$w/pr" >/dev/null 2>&1
  out=$("$MERGE_MAIN" --worktree "$w/pr" --verify-only --check 'echo CHECK-RAN' 2>&1); rc=$?
  expect_code 3 "$rc" "verify-only on an unresolved merge"
  assert_contains "$out" "merge is in progress" "the open merge is named"
  assert_not_contains "$out" "CHECK-RAN" "no check runs on a half-resolved tree"
  w=$(make_world verify-dirty)
  printf 'x\n' >> "$w/pr/a.txt"
  out=$("$MERGE_MAIN" --worktree "$w/pr" --verify-only 2>&1); rc=$?
  expect_code 3 "$rc" "verify-only on a dirty tree"
  pass "verify-only: refuses an open merge or a dirty tree"
}

test_failed_merge_without_conflict_says_why() {
  local w out rc
  w=$(make_world untracked)
  advance_main "$w" z.txt $'from main\n'
  printf 'local scratch\n' > "$w/pr/z.txt"
  out=$("$MERGE_MAIN" --worktree "$w/pr" 2>&1); rc=$?
  expect_code 3 "$rc" "merge refused by git"
  assert_contains "$out" "z.txt" "git's own reason is shown"
  pass "a merge git refuses without a conflict shows git's reason"
}

test_missing_option_value_is_a_usage_error() {
  local rc
  timeout 10 "$MERGE_MAIN" --worktree >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--worktree without a value"
  timeout 10 "$MERGE_MAIN" --worktree "$TMP_ROOT" --check >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--check without a command"
  pass "missing option values exit 2 instead of spinning"
}

test_usage() {
  local rc
  "$MERGE_MAIN" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no worktree is a usage error"
  "$MERGE_MAIN" --worktree "$TMP_ROOT" --slug o/r >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "slug without pr is a usage error"
  pass "usage errors"
}

# A stub pin script with the real one's contract: it can only judge a head its
# scratch bare clone already holds, which the merge commit is until it is fetched.
make_pin_stub() {
  local stub="$TMP_ROOT/pin-stub.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
bare=$FM_PIN_WORK/${2//\//__}.git
printf '%s\n' "$*" >> "$FM_PIN_WORK/calls.log"
[ "$1" = check ] || exit 2
if [ "${4:-}" = --head ]; then
  git -C "$bare" cat-file -e "$5^{commit}" 2>/dev/null || { echo "PIN-INVALID $2#$3 head unknown to the pin clone"; exit 1; }
  echo "PIN-VALID $2#$3 stub"
  exit 0
fi
echo "PIN-VALID $2#$3 stub without head"
SH
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

test_pin_report_sees_unpushed_merge() {
  local w out rc stub work head
  w=$(make_world pin)
  advance_main "$w" b.txt $'b1\nB-main\nb3\n'
  stub=$(make_pin_stub)
  work="$TMP_ROOT/pin-work"
  mkdir -p "$work"
  git init -q --bare "$work/o__r.git"
  out=$(FM_REVIEW_PIN="$stub" FM_PIN_WORK="$work" "$MERGE_MAIN" --worktree "$w/pr" --slug o/r --pr 7 2>&1); rc=$?
  expect_code 0 "$rc" "pin report exit"
  head=$(git -C "$w/pr" rev-parse HEAD)
  assert_contains "$out" "MERGE-CLEAN" "merge happened"
  assert_contains "$out" "PIN-VALID o/r#7 stub" "pin verdict is relayed"
  assert_grep "check o/r 7 --head $head" "$work/calls.log" "pin was asked about the merged head"
  git -C "$work/o__r.git" cat-file -e "$head^{commit}" || fail "merge commit was fetched into the pin clone"
  out=$(FM_REVIEW_PIN="$TMP_ROOT/none" FM_PIN_WORK="$work" "$MERGE_MAIN" --worktree "$w/pr" --slug o/r --pr 7 --verify-only 2>&1); rc=$?
  expect_code 0 "$rc" "missing pin script does not fail the merge step"
  assert_contains "$out" "PIN-UNAVAILABLE" "missing pin script is stated"
  pass "pin report: unpushed merge head reaches the pin check"
}

# test_identity_pinned: the merge commit carries the registered identity even
# when the ambient git environment names someone else, and a project with no
# registration is refused untouched unless --allow-unpinned is given.
test_identity_pinned() {
  local w out rc head
  w=$(make_world pinned)
  advance_main "$w" b.txt $'b1\nB-main\nb3\n'
  out=$(GIT_AUTHOR_EMAIL=stray@example.com GIT_COMMITTER_EMAIL=stray@example.com "$MERGE_MAIN" --worktree "$w/pr" 2>&1); rc=$?
  expect_code 0 "$rc" "pinned merge exit"
  assert_contains "$out" "MERGE-CLEAN" "pinned merge happened"
  assert_equals "pinned@example.com" "$(git -C "$w/pr" log -1 --format=%ae)" "author email is the registered one"
  assert_equals "pinned@example.com" "$(git -C "$w/pr" log -1 --format=%ce)" "committer email is the registered one"
  assert_equals "Pinned Author" "$(git -C "$w/pr" log -1 --format=%an)" "author name is the registered one"
  pass "identity: the merge commit carries the registered identity over ambient git settings"

  w=$(make_world slug-key)
  advance_main "$w" b.txt $'b1\nB-main\nb3\n'
  printf 'o/r slug@example.com\n' > "$FM_HOME/config/commit-identity"
  out=$("$MERGE_MAIN" --worktree "$w/pr" --slug o/r --pr 3 2>&1); rc=$?
  expect_code 0 "$rc" "slug-keyed merge exit"
  assert_equals "slug@example.com" "$(git -C "$w/pr" log -1 --format=%ae)" "--slug selects the entry"
  assert_equals "$(git -C "$w/pr" config user.name 2>/dev/null || printf slug)" "$(git -C "$w/pr" log -1 --format=%an | sed 's/^fmtest$/slug/')" "an entry without a name keeps the ambient name"
  printf '# project identity\norigin pinned@example.com Pinned Author\n' > "$FM_HOME/config/commit-identity"
  pass "identity: --slug selects the entry"

  w=$(make_world unregistered)
  advance_main "$w" b.txt $'b1\nB-main\nb3\n'
  head=$(git -C "$w/pr" rev-parse HEAD)
  out=$(FM_HOME="$TMP_ROOT/empty-home" "$MERGE_MAIN" --worktree "$w/pr" 2>&1); rc=$?
  expect_code 3 "$rc" "unregistered project is refused"
  assert_contains "$out" "config/commit-identity" "the refusal says where to register"
  assert_equals "$head" "$(git -C "$w/pr" rev-parse HEAD)" "refused merge leaves the head alone"
  out=$(FM_HOME="$TMP_ROOT/empty-home" "$MERGE_MAIN" --worktree "$w/pr" --allow-unpinned 2>&1); rc=$?
  expect_code 0 "$rc" "--allow-unpinned merges without a registration"
  assert_contains "$out" "MERGE-CLEAN" "unpinned merge happened"
  pass "identity: unregistered project refused, --allow-unpinned opts out"
}

# make_mech_world <name> [only-file...]: origin with the files a mechanical resolution
# touches (a version number, an append-only index, a doc, a generated file with its
# source, and a code file). Main and the PR branch "feat" each change the named files
# (default: all of them) the way that conflicts. Prints the world directory.
make_mech_world() {
  local w="$TMP_ROOT/$1" f; shift
  local -a only=("$@")
  declare -A pr_side=([VERSION]=$'0.4.27\n' [INDEX.md]=$'| a |\n| b |\n| pr |\n' [DOC.md]=$'d-pr\n'
    [gen.txt]=$'1\n2\n3\n' [code.js]=$'code1\nPR\ncode3\n')
  declare -A main_side=([VERSION]=$'0.4.26\n' [INDEX.md]=$'| a |\n| b |\n| main |\n' [DOC.md]=$'d-main\n'
    [gen.txt]=$'1\n2\nZ\n' [code.js]=$'code1\nMAIN\ncode3\n')
  [ ${#only[@]} -gt 0 ] || only=(VERSION INDEX.md DOC.md gen.txt code.js)
  mkdir -p "$w/seed"
  git init -q -b main "$w/seed"
  printf '0.4.25\n' > "$w/seed/VERSION"
  printf '| a |\n| b |\n' > "$w/seed/INDEX.md"
  printf 'd1\n' > "$w/seed/DOC.md"
  printf '2\n1\n' > "$w/seed/src.txt"
  printf '1\n2\n' > "$w/seed/gen.txt"
  printf 'code1\ncode2\ncode3\n' > "$w/seed/code.js"
  git -C "$w/seed" add . && git -C "$w/seed" commit -qm seed
  git clone -q --bare "$w/seed" "$w/origin.git"
  git clone -q "file://$w/origin.git" "$w/pr"
  git clone -q "file://$w/origin.git" "$w/pusher"
  git -C "$w/pr" checkout -q -b feat
  printf '3\n2\n1\n' > "$w/pr/src.txt"
  for f in "${only[@]}"; do
    printf '%s' "${pr_side[$f]}" > "$w/pr/$f"
    printf '%s' "${main_side[$f]}" > "$w/pusher/$f"
  done
  git -C "$w/pr" commit -qam 'own change'
  git -C "$w/pusher" commit -qam 'main moves'
  git -C "$w/pusher" push -q origin main
  fm_test_remove_tree "$w/pusher"
  printf '%s\n' "$w"
}

write_rules() { # <rule>...: the home's merge-mechanical file
  printf '%s\n' '# mechanical rules' "$@" > "$FM_HOME/config/merge-mechanical"
}
RULES_ALL=('origin VERSION keep-pr' 'origin INDEX.md union' 'origin DOC.md take-main' 'origin gen.txt regen sort src.txt > gen.txt')

test_mechanical_settles_by_rule() {
  local w out rc before
  w=$(make_mech_world mech-ok VERSION INDEX.md DOC.md gen.txt)
  write_rules "${RULES_ALL[@]}"
  before=$(origin_refs "$w")
  out=$("$MERGE_MAIN" --worktree "$w/pr" --mechanical --check 'grep -q 0.4.27 VERSION && echo CHECK-RAN' 2>&1); rc=$?
  expect_code 0 "$rc" "mechanical merge exit"
  assert_contains "$out" "MERGE-MECHANICAL" "mechanical merge is reported"
  assert_contains "$out" "  resolved: VERSION (keep-pr)" "version path and rule are listed"
  assert_contains "$out" "  resolved: gen.txt (regen)" "generated path and rule are listed"
  assert_contains "$out" "CHECK-RAN" "checks run after a mechanical merge"
  assert_equals 3 "$(git -C "$w/pr" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" "head is a two-parent merge commit"
  assert_equals "" "$(git -C "$w/pr" status --porcelain --untracked-files=no)" "worktree is clean after the commit"
  assert_equals "0.4.27" "$(cat "$w/pr/VERSION")" "keep-pr keeps the PR's number"
  assert_equals "d-main" "$(cat "$w/pr/DOC.md")" "take-main takes the base's text"
  assert_equals "| a |,| b |,| pr |,| main |" "$(paste -sd, "$w/pr/INDEX.md")" "union keeps both sides' lines"
  assert_equals "1 2 3" "$(tr '\n' ' ' < "$w/pr/gen.txt" | sed 's/ $//')" "regen rewrote the generated file from its source"
  assert_no_regex '^(<<<<<<<|>>>>>>>) ' "$w/pr/INDEX.md" "no conflict marker is left"
  assert_equals "pinned@example.com" "$(git -C "$w/pr" log -1 --format=%ae)" "the merge commit carries the registered identity"
  assert_equals "$before" "$(origin_refs "$w")" "nothing was pushed"
  pass "mechanical: every conflict settled by its rule, committed with the identity, not pushed"
}

test_mechanical_stops_on_code() {
  local w out rc head
  w=$(make_mech_world mech-code)
  write_rules "${RULES_ALL[@]}"
  head=$(git -C "$w/pr" rev-parse HEAD)
  out=$("$MERGE_MAIN" --worktree "$w/pr" --mechanical 2>&1); rc=$?
  expect_code 10 "$rc" "a code conflict stops the run"
  assert_contains "$out" "MERGE-CONFLICT" "reported as a conflict"
  assert_contains "$out" "  code: code.js" "the path without a rule is named"
  assert_not_contains "$out" "code: VERSION" "a path with a rule is not called code"
  [ -e "$(git -C "$w/pr" rev-parse --absolute-git-dir)/MERGE_HEAD" ] || fail "the merge is left open for the model"
  assert_grep '<<<<<<< ' "$w/pr/VERSION" "no partial resolution: the covered file is still conflicted"
  assert_equals "$head" "$(git -C "$w/pr" rev-parse HEAD)" "head unchanged"
  pass "mechanical: a code conflict leaves the whole merge to the model"
}

test_mechanical_is_opt_in_and_rule_bound() {
  local w out rc
  w=$(make_mech_world mech-optin VERSION)
  write_rules "${RULES_ALL[@]}"
  out=$("$MERGE_MAIN" --worktree "$w/pr" 2>&1); rc=$?
  expect_code 10 "$rc" "rules alone resolve nothing without the flag"
  assert_not_contains "$out" "code:" "no mechanical classification without the flag"
  git -C "$w/pr" merge --abort
  rm -f "$FM_HOME/config/merge-mechanical"
  out=$("$MERGE_MAIN" --worktree "$w/pr" --mechanical 2>&1); rc=$?
  expect_code 10 "$rc" "no rule file means nothing is mechanical"
  assert_contains "$out" "  code: VERSION" "every path is code without a rule"
  git -C "$w/pr" merge --abort
  write_rules 'other-repo VERSION keep-pr'
  out=$("$MERGE_MAIN" --worktree "$w/pr" --mechanical 2>&1); rc=$?
  expect_code 10 "$rc" "another project's rule does not apply"
  git -C "$w/pr" merge --abort
  write_rules 'origin VERSION keep-pr'
  out=$("$MERGE_MAIN" --worktree "$w/pr" --mechanical 2>&1); rc=$?
  expect_code 0 "$rc" "the project's own rule applies"
  pass "mechanical: opt-in per run, bound to the project's rules"
}

test_mechanical_failed_regen_restores_the_conflict() {
  local w out rc
  w=$(make_mech_world mech-regen VERSION gen.txt)
  write_rules 'origin VERSION keep-pr' 'origin gen.txt regen false'
  out=$("$MERGE_MAIN" --worktree "$w/pr" --mechanical 2>&1); rc=$?
  expect_code 10 "$rc" "a failing generator stops the run"
  assert_contains "$out" "  conflicted: VERSION" "the plain conflict is reported"
  assert_grep '<<<<<<< ' "$w/pr/VERSION" "the version file is back to its conflicted form"
  [ -e "$(git -C "$w/pr" rev-parse --absolute-git-dir)/MERGE_HEAD" ] || fail "the merge is open again"
  pass "mechanical: a failing regen command restores the plain conflict"
}

test_mechanical_delete_modify_is_code() {
  local w out rc
  w=$(make_world delmod)
  git clone -q "file://$w/origin.git" "$w/pusher"
  git -C "$w/pusher" rm -q a.txt
  git -C "$w/pusher" commit -qm 'main deletes a.txt'
  git -C "$w/pusher" push -q origin main
  fm_test_remove_tree "$w/pusher"
  write_rules 'origin a.txt keep-pr'
  out=$("$MERGE_MAIN" --worktree "$w/pr" --mechanical 2>&1); rc=$?
  expect_code 10 "$rc" "a delete/modify conflict is never mechanical"
  assert_contains "$out" "  code: a.txt" "the path is named as code"
  git -C "$w/pr" merge --abort
  pass "mechanical: delete/modify conflicts are left to the model"
}

test_clean_merge
test_identity_pinned
test_already_current
test_conflict_stops_with_files
test_checks
test_dirty_refused
test_usage
test_verify_only_refuses_an_open_merge
test_failed_merge_without_conflict_says_why
test_missing_option_value_is_a_usage_error
test_pin_report_sees_unpushed_merge
test_mechanical_settles_by_rule
test_mechanical_stops_on_code
test_mechanical_is_opt_in_and_rule_bound
test_mechanical_failed_regen_restores_the_conflict
test_mechanical_delete_modify_is_code

echo '# all fm-pr-merge-main tests passed'
