#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-budget.sh (the daily Claude budget).
#
# Drives the public argv and environment interface with a fake quota-axi on
# PATH serving a canned `--json` snapshot, and a fixed clock
# (FM_CLAUDE_BUDGET_NOW), so no case touches the network, a credential, or the
# real quota. Pins:
#   1. budget = remaining percent / days to the end date, with the sample
#      numbers worked by hand;
#   2. the end date is configurable by flag, environment, and config file, and
#      a malformed one exits 2;
#   3. the day's allowance is fixed at the first run of the UTC day, the flag
#      flips only when the quota spent since then exceeds it, and the next UTC
#      day starts a fresh baseline;
#   4. a run with no readable quota keeps the previous flag, and a run after
#      the end date records end-passed;
#   5. --flag goes `unknown` when the record is older than two hourly runs;
#   6. the script runs with the minimal environment cron provides and appends
#      one log row per run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-claude-budget.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-budget)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$HOME_DIR/config"
BASE_PATH=$PATH

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FAKE_QUOTA_FAIL:-0}" = 1 ] && exit 1
[ "${1:-}" = --json ] || exit 2
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

write_quota() {  # <path> <claude all_models remaining percent> [status]
  cat > "$1" <<JSON
{ "generatedAt": "2026-10-27T22:00:00Z", "schemaVersion": 5, "providers": [
  { "provider": "claude", "quotaSemantics": { "status": "${3:-known}", "effectiveAvailability": [
    { "scope": "all_models", "status": "${3:-known}", "effectivePercentRemaining": $2 },
    { "scope": "model:fable", "status": "known", "effectivePercentRemaining": 7 } ] } },
  { "provider": "codex", "quotaSemantics": { "status": "known", "effectiveAvailability": [
    { "scope": "all_models", "status": "known", "effectivePercentRemaining": 99 } ] } } ] }
JSON
}

epoch_of() { jq -nr --arg t "$1" '$t | fromdateiso8601'; }
T0=$(epoch_of 2026-10-27T22:00:00Z)   # exactly 5 days before the default end
T1=$(epoch_of 2026-10-27T01:00:00Z)   # early in a UTC day, 5.875 days before the end
HOUR=3600

# run_budget <epoch> <remaining-percent> [args...]: one run on the fixed clock.
run_budget() {
  local now=$1 pct=$2 quota="$TMP_ROOT/quota.json"
  shift 2
  write_quota "$quota" "$pct"
  OUT=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_CLAUDE_BUDGET_NOW="$now" QUOTA_AXI_FIXTURE="$quota" "$TOOL" "$@" 2>&1)
  CODE=$?
}
state_val() { sed -n "s/^$1=//p" "$STATE/claude-budget.state"; }
flag() { PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_CLAUDE_BUDGET_NOW="$1" "$TOOL" --flag; }

# 1. The budget arithmetic, worked by hand: 52% over exactly 5 days.
run_budget "$T0" 52
expect_code 0 "$CODE" "a run with a readable quota exits 0"
assert_equals ok "$(state_val status)" "status ok"
assert_equals 52 "$(state_val remaining_pct)" "remaining percent is read from the Claude all_models row"
assert_equals 5.0000 "$(state_val days_left)" "five days to 2026-11-01T22:00:00Z"
assert_equals 10.40 "$(state_val budget_pct_per_day)" "52% over 5 days is 10.40% a day"
assert_equals 0 "$(state_val above_budget)" "nothing spent yet: within budget"
assert_contains "$OUT" 'budget=10.40%/day' "the summary prints the budget"
[ "$(wc -l < "$HOME_DIR/data/claude-budget.log")" = 1 ] || fail "one log row per run"
pass "budget: 52% remaining over 5 days is 10.40% a day, recorded in the state and the log"

# 2. The end date is configurable; a malformed one exits 2.
run_budget "$T0" 52 --end 2026-10-30T22:00:00Z
assert_equals 3.0000 "$(state_val days_left)" "--end moves the end date"
assert_equals 17.33 "$(state_val budget_pct_per_day)" "52% over 3 days is 17.33% a day"
rm -f "$STATE/claude-budget.state"
printf '# renewal\n2026-10-28T22:00:00Z\n' > "$HOME_DIR/config/claude-budget-end"
run_budget "$T0" 52
assert_equals 1.0000 "$(state_val days_left)" "config/claude-budget-end is the end date when no flag or env is set"
rm -f "$HOME_DIR/config/claude-budget-end" "$STATE/claude-budget.state"
FM_CLAUDE_BUDGET_END=2026-10-29T22:00:00Z run_budget "$T0" 52
assert_equals 2.0000 "$(state_val days_left)" "FM_CLAUDE_BUDGET_END is the end date when no flag is set"
rm -f "$STATE/claude-budget.state"
run_budget "$T0" 52 --end tomorrow
expect_code 2 "$CODE" "a malformed end date exits 2"
assert_contains "$OUT" 'not YYYY-MM-DDTHH:MM:SSZ' "the malformed end date is named"
run_budget "$T0" 52 --end 2026-13-45T25:61:61Z
expect_code 2 "$CODE" "an impossible end date exits 2"
pass "budget: the end date comes from --end, the environment, or config, and a bad one exits 2"

# 3. A fixed day allowance, a flag that flips on spend, a fresh day resets it.
rm -f "$STATE/claude-budget.state" "$HOME_DIR/data/claude-budget.log"
run_budget "$T1" 52
run_budget "$((T1 + HOUR))" 50
assert_equals 2.00 "$(state_val spent_today_pct)" "2% spent since the day baseline"
assert_equals 8.85 "$(state_val day_budget_pct)" "the day's allowance stays fixed at the baseline's 8.85%"
assert_equals 0 "$(state_val above_budget)" "2% of a 8.85% allowance is within budget"
assert_equals within_budget "$(flag "$((T1 + HOUR))")" "--flag reads within_budget"
run_budget "$((T1 + 2 * HOUR))" 40
assert_equals 12.00 "$(state_val spent_today_pct)" "12% spent since the day baseline"
assert_equals 1 "$(state_val above_budget)" "12% against an 8.85% allowance is above budget"
assert_equals above_budget "$(flag "$((T1 + 2 * HOUR))")" "--flag reads above_budget"
run_budget "$((T1 + 86400))" 40
assert_equals 2026-10-28 "$(state_val day)" "a new UTC day takes a new baseline"
assert_equals 0 "$(state_val above_budget)" "the new day starts within budget"
assert_equals 8.21 "$(state_val day_budget_pct)" "40% over 4.875 days is an 8.21% allowance"
pass "budget: the flag flips when today's spend passes the fixed allowance and resets on a new UTC day"

# 4. No readable quota keeps the previous flag; after the end date nothing is enforced.
run_budget "$((T1 + 86400 + 2 * HOUR))" 28
assert_equals 12.00 "$(state_val spent_today_pct)" "12% spent against the new day's 8.21% allowance"
assert_equals 1 "$(state_val above_budget)" "above budget again"
NOW4=$((T1 + 86400 + 3 * HOUR))
OUT=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_CLAUDE_BUDGET_NOW="$NOW4" FAKE_QUOTA_FAIL=1 QUOTA_AXI_FIXTURE="$TMP_ROOT/quota.json" "$TOOL" 2>&1); CODE=$?
expect_code 0 "$CODE" "an unreadable quota is not a failure of the hourly job"
assert_equals no-quota "$(state_val status)" "the record says the quota was unreadable"
assert_equals 1 "$(state_val above_budget)" "an unreadable quota keeps the previous flag"
write_quota "$TMP_ROOT/quota.json" 28 stale
OUT=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_CLAUDE_BUDGET_NOW="$NOW4" QUOTA_AXI_FIXTURE="$TMP_ROOT/quota.json" "$TOOL" 2>&1)
assert_equals no-quota "$(state_val status)" "a stale quota with no known number is unreadable, not zero"
assert_equals 1 "$(state_val above_budget)" "a stale quota keeps the previous flag"
assert_equals 40 "$(state_val day_start_remaining_pct)" "a failed attempt keeps the day's baseline"
assert_equals above_budget "$(flag "$NOW4")" "the kept flag still reads above_budget inside two hours"
assert_equals unknown "$(flag "$((T1 + 86400 + 2 * HOUR + 2 * HOUR + 1))")" "and ages out to unknown when quota stays unreadable"
run_budget "$(epoch_of 2026-11-02T00:00:00Z)" 20
assert_equals end-passed "$(state_val status)" "after the end date there is no budget to enforce"
assert_equals 0 "$(state_val above_budget)" "end-passed is within budget"
pass "budget: an unreadable quota keeps the previous flag and a run after the end date enforces nothing"

# 5. --flag never pins a stale verdict.
run_budget "$T0" 52
rm -f "$STATE/claude-budget.state"
assert_equals unknown "$(flag "$T0")" "no record is unknown"
run_budget "$T0" 52
assert_equals within_budget "$(flag "$((T0 + 2 * HOUR))")" "a record exactly two hours old still counts"
assert_equals unknown "$(flag "$((T0 + 2 * HOUR + 1))")" "a record older than two hourly runs is unknown"
pass "budget: --flag is unknown for a missing or stale record"

# 6. Cron runs with a minimal environment and no terminal.
rm -f "$STATE/claude-budget.state" "$HOME_DIR/data/claude-budget.log"
write_quota "$TMP_ROOT/quota.json" 52
OUT=$(env -i PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_CLAUDE_BUDGET_NOW="$T0" QUOTA_AXI_FIXTURE="$TMP_ROOT/quota.json" "$TOOL" </dev/null 2>&1); CODE=$?
expect_code 0 "$CODE" "a cron-style run succeeds with a minimal environment"
[ "$(wc -l < "$HOME_DIR/data/claude-budget.log")" = 1 ] || fail "one log row per run"
assert_equals "$T0	52	5.0000	10.40	0.00	0" "$(cat "$HOME_DIR/data/claude-budget.log")" "the log row carries the numbers"
pass "budget: runs from a minimal cron environment and appends one log row"

printf '# all fm-claude-budget tests passed\n'
