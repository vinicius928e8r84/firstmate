#!/usr/bin/env bash
# tests/fm-repo-charter.test.sh - the per-repo secondmate charter printed by
# bin/fm-repo-charter.sh. The failure under test: the pm-sm charter was the
# modo-caverna charter copied under another name, so a repo's secondmate was told
# to work another repo. The charter is built from the repo, never copied.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHARTER="$ROOT/bin/fm-repo-charter.sh"
TMP_ROOT=$(fm_test_tmproot fm-repo-charter)

test_charter_names_only_its_own_repo() {
  local a b
  a=$("$CHARTER" alpha-app --slug acme/alpha-app) || fail "alpha charter failed"
  b=$("$CHARTER" beta-core --slug acme/beta-core) || fail "beta charter failed"
  assert_contains "$a" "Own the alpha-app (acme/alpha-app) PR pipeline" "the charter must name its own repo"
  assert_not_contains "$a" "beta-core" "a charter must not carry another repo's name"
  assert_not_contains "$b" "alpha-app" "a charter must not carry another repo's name"
  [ "$(printf '%s\n' "$a" | wc -l)" -eq 1 ] || fail "the charter must be one line"
  assert_contains "$a" "bin/fm-pr-merge.sh" "the default merge goes through the guarded merge script"
  assert_contains "$a" "bin/fm-secondmate-sleep.sh" "the charter must tell the mate it sleeps"
  assert_contains "$a" "150k" "the charter must name the compaction point"
  assert_not_contains "$a" "SIGSTOP" "the retired test throttle must not return"
  assert_not_contains "$a" "Codex" "the retired provider preference must not return"
  pass "charter: built from the repo, one line, no other repo's text, sleeping and script merge named"
}

test_charter_takes_the_repo_rule_and_merge_script() {
  local rule out
  rule="$TMP_ROOT/rule.txt"
  printf 'merge when proof ends PROVEN\nand review is clean\n' > "$rule"
  out=$("$CHARTER" alpha-app --slug acme/alpha-app --merge-script /opt/gate.sh --rule-file "$rule") || fail "charter failed"
  assert_contains "$out" "only through the script /opt/gate.sh" "the merge script must be the one given"
  assert_contains "$out" "under this rule: merge when proof ends PROVEN and review is clean." "the repo rule must replace the general one"
  assert_not_contains "$out" "LOW or MEDIUM" "the general rule must not survive a repo rule"
  pass "charter: the merge script and the repo's own rule are taken from the arguments"
}

test_scope_and_refusals() {
  local out status
  out=$("$CHARTER" alpha-app --slug acme/alpha-app --scope)
  assert_contains "$out" "alpha-app pull request queue" "scope names the repo"
  "$CHARTER" >/dev/null 2>&1; status=$?
  expect_code 2 "$status" "no project must be refused"
  "$CHARTER" alpha-app --slug 'not a slug' >/dev/null 2>&1; status=$?
  expect_code 2 "$status" "a malformed slug must be refused"
  "$CHARTER" alpha-app --slug acme/alpha-app --rule-file "$TMP_ROOT/missing" >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "an unreadable rule file must be refused"
  FM_PROJECTS_OVERRIDE="$TMP_ROOT/no-projects" "$CHARTER" alpha-app >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "a repo whose slug cannot be read must be refused"
  pass "charter: scope line and refusals"
}

test_slug_comes_from_the_clone_origin() {
  local proj out
  proj="$TMP_ROOT/projects/gamma"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" remote add origin https://github.com/acme/gamma.git
  out=$(FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects" "$CHARTER" gamma) || fail "charter failed"
  assert_contains "$out" "(acme/gamma)" "the slug must come from the clone's origin"
  pass "charter: the GitHub slug is read from the project clone"
}

test_charter_names_only_its_own_repo
test_charter_takes_the_repo_rule_and_merge_script
test_scope_and_refusals
test_slug_comes_from_the_clone_origin
