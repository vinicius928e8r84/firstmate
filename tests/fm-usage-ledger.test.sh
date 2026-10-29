#!/usr/bin/env bash
# Behavioral coverage for the usage ledger (bin/fm-usage-ledger-lib.sh): each of the six scripts that had
# no usage trail appends exactly one tab-separated line per run to data/usage-ledger.tsv, a disposable home
# without data/ gets nothing, recording never changes a script's output, and bin/fm-quota-snapshot.sh appends
# one history line per hour, skips inside its gap, and refuses output that is not a quota-axi snapshot.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity

TMP_ROOT=$(fm_test_tmproot fm-usage-ledger)
export HOME="$TMP_ROOT/home" FM_SW_NO_NOTIFY=1
mkdir -p "$HOME"
unset FM_USAGE_LEDGER FM_USAGE_LEDGER_OFF FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE

# new_home <name>: an operational home with data/ and state/; prints it.
new_home() {
  mkdir -p "$TMP_ROOT/$1/data" "$TMP_ROOT/$1/state" "$TMP_ROOT/$1/config"
  printf '%s\n' "$TMP_ROOT/$1"
}

# ledger_line <home> <n>: the n-th ledger line.
ledger_line() { sed -n "${2}p" "$1/data/usage-ledger.tsv"; }

# assert_line <home> <n> <script> <pr> <kind> <outcome>
assert_line() {
  local line
  line=$(ledger_line "$1" "$2")
  case "$line" in [0-9]*) ;; *) fail "ledger line $2 of $1 is not epoch-led: '$line'" ;; esac
  assert_equals "$3"$'\t'"$4"$'\t'"$5"$'\t'"$6" "$(printf '%s' "$line" | cut -f2-)" "ledger line $2 for $3"
}

test_review_rules_and_delta() {
  local h repo out
  h=$(new_home rr)
  out=$(FM_HOME="$h" "$ROOT/bin/fm-review-rules.sh")
  assert_contains "$out" "Reviewer standing rules" "the rules still print"
  assert_equals 1 "$(wc -l < "$h/data/usage-ledger.tsv" | tr -d ' ')" "one line per run"
  assert_line "$h" 1 fm-review-rules - rules printed

  repo="$TMP_ROOT/repo"
  git init -q -b main "$repo"
  printf 'a\n' > "$repo/a.txt"; git -C "$repo" add . && git -C "$repo" commit -qm one
  FM_HOME="$h" "$ROOT/bin/fm-review-delta.sh" --repo "$repo" --reviewed HEAD --base HEAD >/dev/null 2>&1
  assert_line "$h" 2 fm-review-delta - delta DELTA-NONE
  FM_HOME="$h" "$ROOT/bin/fm-review-delta.sh" --repo "$TMP_ROOT/missing" >/dev/null 2>&1
  assert_line "$h" 3 fm-review-delta - delta exit-2
  pass "review rules and delta: one line per run, verdict or exit status"
}

test_pr_merge_main() {
  local h w
  h=$(new_home pm)
  printf 'origin pinned@example.com Pinned\n' > "$h/config/commit-identity"
  w="$TMP_ROOT/pm-world"
  mkdir -p "$w"
  git init -q -b main "$w/seed"
  printf 'a\n' > "$w/seed/a.txt"; git -C "$w/seed" add . && git -C "$w/seed" commit -qm seed
  git clone -q --bare "$w/seed" "$w/origin.git"
  git clone -q "file://$w/origin.git" "$w/pr"
  FM_HOME="$h" "$ROOT/bin/fm-pr-merge-main.sh" --worktree "$w/pr" --slug o/r --pr 7 >/dev/null 2>&1
  assert_line "$h" 1 fm-pr-merge-main 7 merge ALREADY-CURRENT
  FM_HOME="$h" "$ROOT/bin/fm-pr-merge-main.sh" --worktree "$TMP_ROOT/nowhere" >/dev/null 2>&1
  assert_line "$h" 2 fm-pr-merge-main - merge exit-2
  pass "pr-merge-main: result line or exit status, with the PR number"
}

test_guards_and_preaway() {
  local h stub
  h=$(new_home guards)
  FM_HOME="$h" "$ROOT/bin/fm-clean-pr-guard.sh" >/dev/null 2>&1
  assert_line "$h" 1 fm-clean-pr-guard - scan alerts-0
  FM_HOME="$h" FM_SLOT_REQUEST_ROOT="$TMP_ROOT/no-requests" "$ROOT/bin/fm-lane-guard.sh" scan spawn >/dev/null 2>&1
  assert_line "$h" 2 fm-lane-guard - scan-spawn alerts-0
  stub="$TMP_ROOT/stub.sh"
  printf '#!/usr/bin/env bash\necho "$FM_STUB_OUT"\n' > "$stub"; chmod +x "$stub"
  printf '{"claudeAiOauth":{"expiresAt":%s}}\n' $(( ($(date +%s) + 86400) * 1000 )) > "$TMP_ROOT/cred.json"
  FM_HOME="$h" FM_STUB_OUT="balance=-1 spend_per_hr=0 running=0" FM_PREAWAY_POD_BUDGET="$stub" \
    FM_PREAWAY_CAPACITY="$TMP_ROOT/none" FM_PREAWAY_CLAUDE_BUDGET="$TMP_ROOT/none" \
    FM_PREAWAY_CREDENTIALS="$TMP_ROOT/cred.json" FM_PREAWAY_PC_SSH= FM_PREAWAY_MAC_SSH= \
    "$ROOT/bin/fm-preaway-check.sh" >/dev/null 2>&1
  assert_line "$h" 3 fm-preaway-check - checklist MISSING-1
  pass "clean-pr-guard, lane-guard and preaway-check: one line per run with their counts"
}

test_no_data_directory_leaves_nothing() {
  local home="$TMP_ROOT/bare" out
  mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-review-rules.sh")
  assert_contains "$out" "Reviewer standing rules" "the script still works"
  [ ! -e "$home/data" ] || fail "a home without data/ must not grow one"
  out=$(FM_USAGE_LEDGER_OFF=1 FM_HOME="$(new_home off)" "$ROOT/bin/fm-review-rules.sh")
  [ ! -e "$TMP_ROOT/off/data/usage-ledger.tsv" ] || fail "FM_USAGE_LEDGER_OFF=1 must write nothing"
  pass "no data/ directory or the off switch: nothing is written"
}

# A stand-in quota-axi that prints a schema-5 snapshot, or whatever FM_STUB_QUOTA says.
make_quota_stub() {
  local stub="$TMP_ROOT/quota-axi"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
case "${FM_STUB_QUOTA:-ok}" in
  ok) printf '{"generatedAt":"2026-10-29T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","plan":"max","windows":[],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}\n' ;;
  garbage) echo 'not json' ;;
  fail) exit 3 ;;
esac
SH
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

test_quota_snapshot() {
  local h stub hist rc
  h=$(new_home quota)
  stub=$(make_quota_stub)
  hist="$h/state/quota-history.jsonl"
  FM_HOME="$h" FM_QUOTA_AXI="$stub" "$ROOT/bin/fm-quota-snapshot.sh"; rc=$?
  expect_code 0 "$rc" "first snapshot"
  assert_equals 1 "$(wc -l < "$hist" | tr -d ' ')" "one history line"
  assert_equals "claude" "$(jq -r '.snapshot.providers[0].provider' "$hist")" "the snapshot is nested under .snapshot"
  jq -e '.ts | type == "number"' "$hist" >/dev/null || fail "ts is an epoch number"
  FM_HOME="$h" FM_QUOTA_AXI="$stub" "$ROOT/bin/fm-quota-snapshot.sh"; rc=$?
  expect_code 0 "$rc" "a second run inside the gap"
  assert_equals 1 "$(wc -l < "$hist" | tr -d ' ')" "the gap makes it a no-op"
  FM_HOME="$h" FM_QUOTA_AXI="$stub" "$ROOT/bin/fm-quota-snapshot.sh" --min-gap 0; rc=$?
  expect_code 0 "$rc" "--min-gap 0"
  assert_equals 2 "$(wc -l < "$hist" | tr -d ' ')" "a zero gap appends again"
  FM_STUB_QUOTA=garbage FM_HOME="$h" FM_QUOTA_AXI="$stub" "$ROOT/bin/fm-quota-snapshot.sh" --min-gap 0 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "output that is not a snapshot"
  FM_STUB_QUOTA=fail FM_HOME="$h" FM_QUOTA_AXI="$stub" "$ROOT/bin/fm-quota-snapshot.sh" --min-gap 0 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a failing quota-axi"
  FM_HOME="$h" FM_QUOTA_AXI="$TMP_ROOT/absent" "$ROOT/bin/fm-quota-snapshot.sh" --min-gap 0 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "no quota-axi installed"
  assert_equals 2 "$(wc -l < "$hist" | tr -d ' ')" "refused runs write no history"
  assert_equals "appended skipped-gap appended invalid-snapshot quota-failed no-quota-axi" \
    "$(cut -f5 "$h/data/usage-ledger.tsv" | tr '\n' ' ' | sed 's/ $//')" "every run left its own usage line"
  pass "quota snapshot: hourly line, gap no-op, refusals write nothing"
}

test_review_rules_and_delta
test_pr_merge_main
test_guards_and_preaway
test_no_data_directory_leaves_nothing
test_quota_snapshot

echo '# all fm-usage-ledger tests passed'
