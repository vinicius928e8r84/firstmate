#!/usr/bin/env bash
# tests/fm-actions.test.sh - behavior tests for bin/fm-actions.sh, the actions
# ledger with proof: add, prove, list, report, the read-only proof guard, the
# proof timeout, and the "no proof" state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTIONS="$ROOT/bin/fm-actions.sh"
TMP_ROOT=$(fm_test_tmproot fm-actions-tests)

actions() {  # <home> args...
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ACTIONS" "$@"
}

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

test_add_prove_report_roundtrip() {
  local home out
  home=$(make_home roundtrip)
  : > "$home/present"
  actions "$home" add --id i1 --source "audit 28/10 item 1" --owner firstmate --proof 'test -e present' >/dev/null || fail "add i1 failed"
  actions "$home" add --id i2 --source "audit 28/10 item 2" --owner firstmate --proof 'test -e missing' >/dev/null || fail "add i2 failed"
  actions "$home" add --id i3 --source "audit 28/10 item 3" --owner captain --proof '' >/dev/null || fail "add i3 failed"
  out=$(actions "$home" report) || fail "report failed"
  assert_contains "$out" "ACTIONS total=3 done=0 not-done=0 no-proof=1 pending=2" "fresh ledger counts"
  [ "$(printf '%s\n' "$out" | sed -n 2p | cut -f1)" = SEM-PROVA ] || fail "an item with no proof must lead the report: $out"
  out=$(actions "$home" prove --all) || fail "prove --all failed"
  assert_contains "$out" "i1: PASS" "present file proves"
  assert_contains "$out" "i2: FAIL(exit 1)" "missing file fails"
  assert_contains "$out" "i3: no-proof" "empty proof stays no-proof"
  out=$(actions "$home" report) || fail "report failed"
  assert_contains "$out" "ACTIONS total=3 done=1 not-done=1 no-proof=1 pending=0" "proved counts"
  printf '%s\n' "$out" | grep -E '^FEITO	i1	firstmate	' >/dev/null || fail "i1 not reported FEITO: $out"
  printf '%s\n' "$out" | grep -E '^NAO	i2	' >/dev/null || fail "i2 not reported NAO: $out"
  [ "$(actions "$home" list "done" | wc -l)" -eq 2 ] || fail "list done should print header plus i1"
  : > "$home/missing"
  actions "$home" prove i2 | grep -F 'i2: PASS' >/dev/null || fail "re-proving after the fix did not flip i2"
  pass "ledger round trip: add, prove, list and report reflect each proof result"
}

test_proof_guard_refuses_writes_and_protected_surfaces() {
  local home p rc
  home=$(make_home guard)
  for p in 'rm -rf data' 'echo x > file' 'git push origin main' 'git -C x commit -m y' 'ssh pc true' 'curl -d a http://x' \
    'runpod pods' 'cat anki.txt' 'gh api -X POST repos/a/b/issues' 'crontab -r' 'sed -i s/a/b/ f'; do
    rc=0
    actions "$home" add --id g --source s --owner o --proof "$p" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "proof was accepted but must be refused: $p"
  done
  for p in 'test -x bin/x 2>/dev/null' 'git merge-base --is-ancestor a b >/dev/null' 'crontab -l | grep -q x' 'gh api repos/a/b --jq .state | grep -qx closed'; do
    actions "$home" add --id "ok$(printf '%s' "$p" | cksum | cut -d' ' -f1)" --source s --owner o --proof "$p" >/dev/null 2>&1 || fail "read-only proof was refused: $p"
  done
  actions "$home" add --id dup --source s --owner o --proof 'true' >/dev/null || fail "add dup failed"
  actions "$home" add --id dup --source s --owner o --proof 'true' >/dev/null 2>&1 && fail "duplicate id was accepted"
  pass "add refuses writing and protected-surface proofs, accepts read-only ones, refuses duplicates"
}

test_prove_never_runs_a_tampered_unsafe_proof() {
  local home out
  home=$(make_home tampered)
  actions "$home" add --id t1 --source s --owner o --proof 'true' >/dev/null || fail "add failed"
  sed -i 's/\ttrue\t/\ttouch pwned\t/' "$home/data/actions.tsv"
  out=$(actions "$home" prove t1) || fail "prove failed"
  assert_contains "$out" "REFUSED" "a hand-edited writing proof must be refused at prove time"
  [ ! -e "$home/pwned" ] || fail "the unsafe proof ran"
  pass "prove re-checks the guard, so a hand-edited ledger cannot run a writing proof"
}

test_proof_timeout_is_recorded() {
  local home out
  home=$(make_home timeout)
  actions "$home" add --id slow --source s --owner o --proof 'sleep 20' >/dev/null || fail "add failed"
  out=$(FM_ACTIONS_PROOF_TIMEOUT=1 FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ACTIONS" prove slow) || fail "prove failed"
  assert_contains "$out" "slow: TIMEOUT(1s)" "a slow proof must time out"
  actions "$home" report | grep -E '^NAO	slow	' >/dev/null || fail "a timed-out proof must read as not done"
  pass "a proof over the bound is stopped and recorded as not done"
}

test_add_prove_report_roundtrip
test_proof_guard_refuses_writes_and_protected_surfaces
test_prove_never_runs_a_tampered_unsafe_proof
test_proof_timeout_is_recorded
