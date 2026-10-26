#!/usr/bin/env bash
# Behavioral coverage for bin/fm-review-rules.sh: the printed reviewer rules say
# a reviewer never runs the whole suite locally, name the rented-machine run as
# the owner of the full suite, allow focused tests of the changed paths, and
# point at the review delta packet; the script is read-only and takes no input.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RULES="$ROOT/bin/fm-review-rules.sh"

test_rules_text() {
  local out rc
  out=$("$RULES" 2>&1); rc=$?
  expect_code 0 "$rc" "rules exit"
  assert_contains "$out" "Do not run the project's full test suite on this machine" "no full suite locally"
  assert_contains "$out" "rented machine" "the full suite is the rented-machine run"
  assert_contains "$out" "exact final head" "the suite runs at the final head"
  assert_contains "$out" "focused tests of the paths this change touches" "focused tests allowed"
  assert_contains "$out" "fm-review-delta.sh" "delta packet is named"
  pass "reviewer rules say no full suite locally and allow focused tests"
}

test_rules_are_stable_and_side_effect_free() {
  local dir out1 out2
  dir=$(fm_test_tmproot fm-review-rules)
  out1=$(HOME="$dir" FM_HOME="$dir" "$RULES"); out2=$(HOME="$dir" FM_HOME="$dir" "$RULES")
  assert_equals "$out1" "$out2" "same text every time"
  assert_equals "" "$(find "$dir" -mindepth 1 ! -name .fm-test-fixture | head -1)" "nothing written"
  pass "rules are deterministic and write nothing"
}

test_rules_text
test_rules_are_stable_and_side_effect_free

echo '# all fm-review-rules tests passed'
