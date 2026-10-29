#!/usr/bin/env bash
# Behavioral coverage for bin/fm-adapter-limits.sh and the arm defaults that read its table:
# the shipped table passes its own check, a knob past the smallest limit it must stay inside is
# refused naming the inequality, a missing row is refused, the arm's confirmation cap and back-off
# cap come from the table, and the hook timeout the table records is the one the Claude settings set.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-adapter-limits)
LIMITS="$ROOT/bin/fm-adapter-limits.sh"

# table_with <file> <name> <value>: copy the shipped table with one value replaced.
table_with() {
  awk -F'\t' -v OFS='\t' -v n="$2" -v v="$3" '$1 == n { $2 = v } { print }' "$ROOT/bin/fm-adapter-limits.tsv" > "$1"
}

test_shipped_table_passes() {
  local out rc
  out=$("$LIMITS" check 2>&1); rc=$?
  expect_code 0 "$rc" "shipped table check exit"
  assert_contains "$out" "adapter limits ok" "check reports success"
  assert_equals 200 "$("$LIMITS" get arm_term_wait)" "get prints a row's value"
  pass "shipped table passes its own check"
}

test_oversized_knobs_are_refused() {
  local t="$TMP_ROOT/over.tsv" out rc
  table_with "$t" arm_backoff_cap 100
  out=$(FM_ADAPTER_LIMITS_FILE="$t" "$LIMITS" check 2>&1); rc=$?
  expect_code 1 "$rc" "backoff past the hook timeout"
  assert_contains "$out" "arm_confirm_cap + arm_backoff_cap" "the failed inequality is named"
  table_with "$t" arm_term_wait 2900
  out=$(FM_ADAPTER_LIMITS_FILE="$t" "$LIMITS" check 2>&1); rc=$?
  expect_code 1 "$rc" "TERM wait past the retire allowance"
  assert_contains "$out" "adapter_retire_allowance" "the retire allowance is named"
  table_with "$t" arm_confirm_base 13
  out=$(FM_ADAPTER_LIMITS_FILE="$t" "$LIMITS" check 2>&1); rc=$?
  expect_code 1 "$rc" "unloaded window past the ready timeout"
  assert_contains "$out" "adapter_ready_timeout" "the ready timeout is named"
  pass "a knob past the smallest limit is refused with the inequality named"
}

test_missing_row_is_refused() {
  local t="$TMP_ROOT/missing.tsv" out rc
  grep -v '^arm_term_cleanup' "$ROOT/bin/fm-adapter-limits.tsv" > "$t"
  out=$(FM_ADAPTER_LIMITS_FILE="$t" "$LIMITS" check 2>&1); rc=$?
  expect_code 1 "$rc" "missing row"
  assert_contains "$out" "missing row arm_term_cleanup" "the missing row is named"
  "$LIMITS" get no_such_row >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "get of an unknown row"
  pass "a missing row is refused"
}

test_arm_defaults_read_the_table() {
  local t="$TMP_ROOT/read.tsv" win back
  awk -F'\t' -v OFS='\t' '$1 == "arm_confirm_cap" { $2 = 77 } $1 == "arm_backoff_cap" { $2 = 44 } { print }' "$ROOT/bin/fm-adapter-limits.tsv" > "$t"
  win=$(env -u FM_ARM_CONFIRM_CAP FM_ADAPTER_LIMITS_FILE="$t" FM_STATE_OVERRIDE="$TMP_ROOT/state" FM_LOAD1_OVERRIDE=1000 FM_NCPU_OVERRIDE=1 \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_arm_confirm_window 10' _ "$ROOT")
  back=$(env -u FM_ARM_BACKOFF_CAP FM_ADAPTER_LIMITS_FILE="$t" FM_STATE_OVERRIDE="$TMP_ROOT/state" FM_LOAD1_OVERRIDE=1000 FM_NCPU_OVERRIDE=1 \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_arm_backoff_seconds 8' _ "$ROOT")
  assert_equals 77 "$win" "confirmation cap comes from the table"
  assert_equals 44 "$back" "back-off cap comes from the table"
  win=$(env -u FM_ARM_CONFIRM_CAP FM_STATE_OVERRIDE="$TMP_ROOT/state" FM_LOAD1_OVERRIDE=1000 FM_NCPU_OVERRIDE=1 \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_arm_confirm_window 10' _ "$ROOT")
  assert_equals "$("$LIMITS" get arm_confirm_cap)" "$win" "the shipped default is the shipped row"
  pass "arm confirmation and back-off caps read the table"
}

test_claude_hook_timeout_matches_settings() {
  local want
  want=$("$LIMITS" get claude_hook_timeout)
  jq -e --argjson t "$want" '[.hooks[][].hooks[] | .timeout] | index($t) != null' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "no Claude hook in .claude/settings.json carries the table's claude_hook_timeout $want"
  pass "the table's Claude hook timeout is one the settings carry"
}

test_shipped_table_passes
test_oversized_knobs_are_refused
test_missing_row_is_refused
test_arm_defaults_read_the_table
test_claude_hook_timeout_matches_settings

echo '# all fm-adapter-limits tests passed'
