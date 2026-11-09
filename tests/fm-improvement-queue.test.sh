#!/usr/bin/env bash
# Behavioral coverage for bin/fm-improvement-queue.sh: an improvement gets an id, owner and state when
# it is proposed, a thing that already exists in bin/ is refused instead of proposed again, states only
# append, the latest row per id is what list shows, and --open leaves out what needs nothing more.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-improvement-queue)
QUEUE="$ROOT/bin/fm-improvement-queue.sh"
export FM_HOME="$TMP_ROOT/home"
export FM_AUDIT_QUEUE="$FM_HOME/data/audit-queue.tsv"
mkdir -p "$FM_HOME"

test_add_set_list() {
  local id1 id2 out rc
  id1=$("$QUEUE" add "cap daily spend per lane" --audit 20261029 --owner pc-aux)
  id2=$("$QUEUE" add "second thing" --audit 20261029)
  assert_equals "20261029-1" "$id1" "first id of the audit"
  assert_equals "20261029-2" "$id2" "second id of the audit"
  "$QUEUE" set "$id1" building "worker started"
  "$QUEUE" set "$id1" landed "on main"
  out=$("$QUEUE" list)
  assert_contains "$out" "20261029-1"$'\t'"landed"$'\t'"pc-aux"$'\t'"cap daily spend per lane"$'\t'"on main" "latest row per id carries owner, title and note"
  assert_contains "$out" "20261029-2"$'\t'"proposed"$'\t'"unassigned" "an unowned proposal is explicit"
  assert_equals 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one line per id"
  assert_equals 4 "$("$QUEUE" list --all-history | wc -l | tr -d ' ')" "history keeps every row"
  "$QUEUE" set "$id1" proved "real path checked" >/dev/null 2>&1; rc=$?
  expect_code 5 "$rc" "proved without a passing proof is refused"
  "$QUEUE" set "$id1" landed "on main" --proof 'true' >/dev/null
  "$QUEUE" prove "$id1" >/dev/null
  out=$("$QUEUE" list --open)
  assert_not_contains "$out" "20261029-1" "a proved improvement is not open"
  assert_contains "$out" "20261029-2" "a proposed one stays open"
  "$QUEUE" set "$id2" nonsense >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "unknown state"
  "$QUEUE" set 20261029-9 landed >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "unknown id"
  pass "add, set, list: ids, owners, appended states, open filter"
}

test_existing_thing_is_not_proposed_again() {
  local before out rc
  before=$(wc -l < "$FM_AUDIT_QUEUE")
  out=$("$QUEUE" add "daily Claude budget in fm-claude-budget.sh" --audit 20261029 2>&1); rc=$?
  expect_code 3 "$rc" "a title naming an existing script is refused"
  assert_contains "$out" "EXISTS fm-claude-budget.sh: bin/fm-claude-budget.sh" "the existing path is named"
  out=$("$QUEUE" add "something" --probe fm-lane-guard --audit 20261029 2>&1); rc=$?
  expect_code 3 "$rc" "an explicit probe is refused"
  assert_equals "$before" "$(wc -l < "$FM_AUDIT_QUEUE")" "nothing was recorded"
  out=$("$QUEUE" add "fm-claude-budget ten point cap" --even-if-present --audit 20261029 2>&1); rc=$?
  expect_code 0 "$rc" "--even-if-present records it anyway"
  out=$("$QUEUE" add "fm-no-such-script-xyz" --audit 20261029 2>&1); rc=$?
  expect_code 0 "$rc" "a name nothing matches is a new idea"
  pass "an improvement that already exists in bin/ is refused unless forced"
}

test_fields_cannot_break_the_ledger() {
  local id
  id=$("$QUEUE" add $'tab\there' --audit 20261030)
  "$QUEUE" set "$id" building $'two\nlines'
  assert_equals 0 "$(awk -F'\t' 'NF != 8 { bad++ } END { print bad + 0 }' "$FM_AUDIT_QUEUE")" "every ledger row keeps eight fields"
  pass "tabs and newlines in a field cannot add fields or rows"
}

test_wip_cap_and_the_24h_worker_deadline() {
  local i id out rc base=1800000000
  export FM_AUDIT_QUEUE="$FM_HOME/data/audit-queue-wip.tsv"
  rm -f "$FM_AUDIT_QUEUE"
  for i in 1 2 3 4 5 6; do "$QUEUE" add "work item $i" --audit 20261101 >/dev/null; done
  for i in 1 2 3 4 5; do FM_IMPROVEMENT_NOW=$base "$QUEUE" set "20261101-$i" approved "captain said yes" >/dev/null; done
  assert_equals 5 "$("$QUEUE" wip)" "five approved ids are in flight"
  out=$(FM_IMPROVEMENT_NOW=$base "$QUEUE" set 20261101-6 approved 2>&1); rc=$?
  expect_code 4 "$rc" "a sixth approved id is refused: $out"
  assert_contains "$out" "cap of 5" "the refusal names the cap"
  assert_contains "$("$QUEUE" list | grep '^20261101-6')" "proposed" "the refused id stays proposed"
  "$QUEUE" set 20261101-1 building "worker started" >/dev/null
  assert_equals 5 "$("$QUEUE" wip)" "building still counts as in flight"
  "$QUEUE" set 20261101-2 dropped "no longer wanted" >/dev/null
  assert_equals 4 "$("$QUEUE" wip)" "a dropped id frees its slot"
  FM_IMPROVEMENT_NOW=$base "$QUEUE" set 20261101-6 approved >/dev/null; rc=$?
  expect_code 0 "$rc" "the freed slot takes the sixth id"
  # approved at $base: due 24 h later; not stale before, stale after; a started worker ends the wait.
  assert_equals "" "$(FM_IMPROVEMENT_NOW=$((base + 3600 * 23)) "$QUEUE" stale)" "nothing is stale inside 24 h"
  out=$(FM_IMPROVEMENT_NOW=$((base + 3600 * 25)) "$QUEUE" stale)
  assert_contains "$out" "20261101-3"$'\t'"$((base + 86400))"$'\t'"unassigned"$'\t'"work item 3" "an approved id with no worker is stale after 24 h"
  assert_not_contains "$out" "20261101-1" "a building id is not stale"
  assert_not_contains "$out" "20261101-2" "a dropped id is not stale"
  id=$("$QUEUE" add "with a due time" --audit 20261102 --due +48h)
  assert_equals 8 "$(awk -F'\t' -v id="$id" '$2 == id { print NF }' "$FM_AUDIT_QUEUE")" "a row keeps eight fields with a due time"
  "$QUEUE" add "bad" --audit 20261102 --due soon >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a due time that is not an epoch or +Nh"
  export FM_AUDIT_QUEUE="$FM_HOME/data/audit-queue.tsv"
  pass "the work-in-flight cap, the freed slot and the 24 h worker deadline"
}

test_prove_records_the_result_and_only_a_pass_proves() {
  local home out id rc
  home="$TMP_ROOT/prove"; mkdir -p "$home"; : > "$home/present"
  export FM_AUDIT_QUEUE="$home/q.tsv"
  export FM_HOME="$home"
  rm -f "$FM_AUDIT_QUEUE"
  id=$("$QUEUE" add "thing one" --audit 20261105 --proof 'test -e present')
  local id2 id3 id4
  id2=$("$QUEUE" add "thing two" --audit 20261105 --proof 'test -e missing')
  id3=$("$QUEUE" add "thing three" --audit 20261105)
  "$QUEUE" set "$id" landed "on main" >/dev/null
  assert_contains "$("$QUEUE" list | grep thing)" "test -e present" "the proof is carried forward on a later row"
  out=$("$QUEUE" prove --all)
  assert_contains "$out" "$id: PASS" "a present file proves"
  assert_contains "$out" "$id2: FAIL(exit 1)" "a missing file fails"
  assert_not_contains "$out" "$id3" "an item with no proof is not run by --all"
  assert_contains "$("$QUEUE" list | grep "^$id")" "proved" "a passing proof makes the id proved"
  assert_contains "$("$QUEUE" list | grep "^$id2")" "proposed" "a failing proof leaves the state"
  assert_contains "$("$QUEUE" list | grep "^$id2")" "proof FAIL(exit 1)" "and records why"
  assert_not_contains "$("$QUEUE" list --open)" "$id	" "a proved id is no longer open"
  assert_contains "$("$QUEUE" prove "$id3")" "$id3: no-proof" "a single id without a proof says so"
  : > "$home/missing"
  assert_contains "$("$QUEUE" prove "$id2")" "$id2: PASS" "re-proving after the fix flips it"
  rc=0; "$QUEUE" prove nope >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "an unknown id"
  # the guard: writing proofs and protected surfaces are refused at add time and at prove time
  for p in 'rm -rf data' 'echo x > file' 'git push origin main' 'git -C x commit -m y' 'ssh pc true' 'curl -d a http://x' \
    'runpod pods' 'cat anki.txt' 'gh api -X POST repos/a/b/issues' 'crontab -r' 'sed -i s/a/b/ f'; do
    rc=0; "$QUEUE" add "bad $p" --audit 20261106 --proof "$p" >/dev/null 2>&1 || rc=$?
    expect_code 5 "$rc" "proof was accepted but must be refused: $p"
  done
  for p in 'test -x bin/x 2>/dev/null' 'git merge-base --is-ancestor a b >/dev/null' 'crontab -l | grep -q x' 'gh api repos/a/b --jq .state | grep -qx closed'; do
    rc=0; "$QUEUE" add "ok $p" --audit 20261106 --proof "$p" >/dev/null 2>&1 || rc=$?
    expect_code 0 "$rc" "read-only proof was refused: $p"
  done
  id4=$("$QUEUE" add "tampered" --audit 20261107 --proof 'true')
  sed -i 's/\ttrue$/\ttouch pwned/' "$FM_AUDIT_QUEUE"
  out=$("$QUEUE" prove "$id4")
  assert_contains "$out" "REFUSED" "a hand-edited writing proof is refused at prove time"
  assert_absent "$home/pwned" "the unsafe proof did not run"
  id4=$("$QUEUE" add "slow" --audit 20261108 --proof 'sleep 20')
  out=$(FM_ACTIONS_PROOF_TIMEOUT=1 "$QUEUE" prove "$id4")
  assert_contains "$out" "$id4: TIMEOUT(1s)" "a proof over the bound is stopped"
  assert_contains "$("$QUEUE" list | grep "^$id4")" "proposed" "a timed-out proof does not prove"
  export FM_HOME="$TMP_ROOT/home" FM_AUDIT_QUEUE="$TMP_ROOT/home/data/audit-queue.tsv"
  pass "prove runs the stored read-only proof, only a pass makes an id proved, unsafe and slow proofs are stopped"
}

test_add_set_list
test_existing_thing_is_not_proposed_again
test_fields_cannot_break_the_ledger
test_wip_cap_and_the_24h_worker_deadline
test_prove_records_the_result_and_only_a_pass_proves

echo '# all fm-improvement-queue tests passed'
