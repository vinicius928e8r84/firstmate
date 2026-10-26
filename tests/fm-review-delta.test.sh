#!/usr/bin/env bash
# Behavioral coverage for bin/fm-review-delta.sh: the verdict and packet for a
# clean main merge whose neighbouring context moved, a hand-resolved merge whose
# own +/- lines stayed the same, a PR whose own change really differs, a stacked
# PR whose base landed, the --pin lookup, and the refusals. The script is
# read-only, so each case also asserts the repository head did not move.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity

TMP_ROOT=$(fm_test_tmproot fm-review-delta)
DELTA="$ROOT/bin/fm-review-delta.sh"

# make_repo <name>: main with a ten-line a.txt, branch feat with one own commit
# that rewrites line 5. Prints the repo path; the reviewed head is feat's tip.
make_repo() {
  local r="$TMP_ROOT/$1"
  git init -q -b main "$r"
  seq 1 10 | sed 's/^/a/' > "$r/a.txt"
  printf 'b\n' > "$r/b.txt"
  git -C "$r" add . && git -C "$r" commit -qm seed
  git -C "$r" checkout -q -b feat
  sed -i '5s/.*/OWN5/' "$r/a.txt"
  git -C "$r" commit -qam 'own: rewrite line 5'
  printf '%s\n' "$r"
}

# main_commit <repo> <sed-expr> [file]: land one commit on main, return to feat.
main_commit() {
  local r=$1 f=${3:-a.txt}
  git -C "$r" checkout -q main
  sed -i "$2" "$r/$f"
  git -C "$r" commit -qam "main: $2"
  git -C "$r" checkout -q feat
}

test_clean_merge_neighbouring_context() {
  local r reviewed out rc
  r=$(make_repo clean)
  reviewed=$(git -C "$r" rev-parse HEAD)
  main_commit "$r" '3s/.*/MAIN3/'
  git -C "$r" merge -q --no-edit main || fail "fixture merge must be clean"
  assert_equals 1 "$(git -C "$r" rev-list --merges "$reviewed..HEAD" | wc -l | tr -d ' ')" "the head carries a merge commit past the reviewed head"
  out=$("$DELTA" --repo "$r" --reviewed "$reviewed" --base main 2>&1); rc=$?
  expect_code 0 "$rc" "identical own change exits 0"
  assert_contains "$out" "DELTA-NONE" "verdict"
  assert_contains "$out" "byte-identical" "explicit identical statement"
  assert_contains "$out" "1 files, +1/-1" "counts are stated"
  assert_contains "$out" "none: every merge in the range" "no hand-resolved hunks"
  assert_not_contains "$out" "range-diff" "no range-diff when nothing changed"
  # Line 3 sits in the -U3 context of the PR's change (line 5), so a context-sensitive fingerprint would differ here.
  [ "$(git -C "$r" diff --no-renames main HEAD | git -C "$r" patch-id --stable | cut -d' ' -f1)" != "$(git -C "$r" diff "$reviewed~1" "$reviewed" | git -C "$r" patch-id --stable | cut -d' ' -f1)" ] || fail "fixture sanity: patch-id must differ"
  pass "clean merge, neighbouring context moved: DELTA-NONE"
}

test_resolved_conflict_same_own_lines() {
  local r reviewed out rc
  r=$(make_repo resolved)
  reviewed=$(git -C "$r" rev-parse HEAD)
  git -C "$r" checkout -q main
  sed -i '5a MAINADD' "$r/a.txt"
  git -C "$r" commit -qam 'main: add after 5'
  git -C "$r" checkout -q feat
  git -C "$r" merge --no-edit main >/dev/null 2>&1 && fail "fixture must conflict"
  printf '%s\n' a1 a2 a3 a4 OWN5 MAINADD a6 a7 a8 a9 a10 > "$r/a.txt"
  git -C "$r" commit -qam 'merge main, keep both'
  out=$("$DELTA" --repo "$r" --reviewed "$reviewed" --base main 2>&1); rc=$?
  expect_code 1 "$rc" "resolved merge needs a look"
  assert_contains "$out" "DELTA-RESOLVED-ONLY" "verdict"
  assert_contains "$out" "byte-identical" "own change still identical"
  assert_contains "$out" "MAINADD" "the resolved hunk is shown"
  pass "hand-resolved merge: only the resolved hunks"
}

test_hand_edit_on_a_clean_merge_is_shown() {
  local r reviewed out rc
  r=$(make_repo evil)
  reviewed=$(git -C "$r" rev-parse HEAD)
  main_commit "$r" '3s/.*/MAIN3/'
  git -C "$r" merge -q --no-commit --no-ff main || fail "fixture merge must be clean"
  printf 'smuggled\n' >> "$r/b.txt"
  git -C "$r" commit -qam 'merge main (with an extra edit)'
  out=$("$DELTA" --repo "$r" --reviewed "$reviewed" --base main 2>&1); rc=$?
  expect_code 1 "$rc" "a hand edit needs a look"
  assert_contains "$out" "+smuggled" "the edit is shown against git's own merge"
  assert_not_contains "$out" "MAIN3" "git's own merge result is not shown"
  assert_not_contains "$out" "byte-identical" "no identical claim when the merge carried an edit"
  pass "hand edit hidden in a clean merge: shown, and the own change no longer identical"
}

test_own_change_differs() {
  local r reviewed out rc
  r=$(make_repo changed)
  reviewed=$(git -C "$r" rev-parse HEAD)
  sed -i '7s/.*/FOLLOWUP7/' "$r/a.txt"
  git -C "$r" commit -qam 'own: follow-up on line 7'
  out=$("$DELTA" --repo "$r" --reviewed "$reviewed" --base main 2>&1); rc=$?
  expect_code 1 "$rc" "changed own change exits 1"
  assert_contains "$out" "DELTA-OWN-CHANGED" "verdict"
  assert_contains "$out" "DIFFER" "difference stated"
  assert_contains "$out" "range-diff of the PR's own commits" "range-diff section"
  assert_contains "$out" "own: follow-up on line 7" "the new commit is in the range-diff"
  assert_not_contains "$out" "byte-identical" "no identical claim"
  pass "own change differs: range-diff packet"
}

test_stacked_pr_after_base_landed() {
  local r reviewed out rc
  r="$TMP_ROOT/stack"
  git init -q -b main "$r"
  seq 1 10 | sed 's/^/a/' > "$r/a.txt"
  printf 'b\n' > "$r/b.txt"
  git -C "$r" add . && git -C "$r" commit -qm seed
  git -C "$r" checkout -q -b base-pr
  sed -i '2s/.*/BASE2/' "$r/a.txt"; git -C "$r" commit -qam 'base pr: line 2'
  git -C "$r" checkout -q -b top-pr
  printf 'top\n' > "$r/b.txt"; git -C "$r" commit -qam 'top pr: b'
  reviewed=$(git -C "$r" rev-parse HEAD)
  git -C "$r" checkout -q main && git -C "$r" merge -q --squash base-pr >/dev/null && git -C "$r" commit -qm "squash: base pr"
  git -C "$r" checkout -q top-pr && git -C "$r" merge -q --no-edit main
  out=$("$DELTA" --repo "$r" --reviewed "$reviewed" --base main 2>&1); rc=$?
  expect_code 1 "$rc" "stack shrink is not silently accepted"
  assert_contains "$out" "DELTA-OWN-CHANGED" "own lines shrank when the base landed"
  assert_contains "$out" "top pr: b" "own commit listed in the range-diff"
  case "$out" in *"= "*"top pr: b"*) : ;; *) fail "the unchanged own commit shows as equal in the range-diff"$'\n'"$out" ;; esac
  pass "stacked PR: range-diff pairs the surviving own commit as equal"
}

test_pin_lookup_and_refusals() {
  local r reviewed out rc home
  r=$(make_repo pinned)
  reviewed=$(git -C "$r" rev-parse HEAD)
  home="$TMP_ROOT/home"; mkdir -p "$home/data/review-pins"
  printf 'repo=o/r\npr=9\nreviewed_head=%s\n' "$reviewed" > "$home/data/review-pins/o__r-9.pin"
  out=$(FM_HOME="$home" "$DELTA" --repo "$r" --pin o/r 9 --base main 2>&1); rc=$?
  expect_code 0 "$rc" "pin lookup at the reviewed head"
  assert_contains "$out" "DELTA-NONE" "same head is no delta"
  out=$(FM_HOME="$home" "$DELTA" --repo "$r" --pin o/r 10 --base main 2>&1); rc=$?
  expect_code 3 "$rc" "missing pin"
  out=$("$DELTA" --repo "$r" --reviewed deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --base main 2>&1); rc=$?
  expect_code 3 "$rc" "unknown reviewed commit"
  assert_contains "$out" "fetch it first" "tells what to do"
  "$DELTA" --repo "$r" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no reviewed head is a usage error"
  pass "pin lookup and refusals"
}

test_clean_merge_neighbouring_context
test_resolved_conflict_same_own_lines
test_hand_edit_on_a_clean_merge_is_shown
test_own_change_differs
test_stacked_pr_after_base_landed
test_pin_lookup_and_refusals

echo '# all fm-review-delta tests passed'
