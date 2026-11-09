#!/usr/bin/env bash
# Behavioral coverage for bin/fm-merge-pr.sh with stand-in gh and private tools: the one result line,
# every refusal that must stop before any merge (behind main, draft, yolo without registry, yolo on a
# HIGH PR, a review of another head that the pin does not carry), the stand-in record that exists only
# while the gate runs, the pin refreshing a stale review, and the post-merge step.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-pr)
MERGE_PR="$ROOT/bin/fm-merge-pr.sh"
URL=https://github.com/acme/widget/pull/7
HEAD=0123456789abcdef0123456789abcdef01234567

# new_home <name>: a home with state/, stand-ins for every tool, and an openable PR.
new_home() {
  H="$TMP_ROOT/$1"; mkdir -p "$H/state" "$H/data/reviews" "$H/bin"
  export FM_HOME="$H" FM_PM_AUDIT="$H/audit.tsv" FM_MERGE_PR_NOW=2026-11-09T00:00:00Z
  export FM_MERGE_PR_GH="$H/gh" FM_READY_BIN="$H/ready" FM_REVIEW_PIN="$H/pin" FM_REVIEW_RECORD="$H/record"
  export FM_MERGE_GATE="$H/gate" FM_POST_MERGE="$H/post" FM_PROJECT_MODE="$H/mode"
  printf '%s\n' '#!/usr/bin/env bash' "cat '$H/pr.json'" > "$H/gh"
  printf '{"state":"OPEN","isDraft":false,"headRefOid":"%s","headRefName":"fm/x","mergeStateStatus":"CLEAN"}\n' "$HEAD" > "$H/pr.json"
  set_ready ok LOW
  printf '%s\n' '#!/usr/bin/env bash' 'echo "PIN-VALID acme/widget#7 own change identical"' > "$H/pin"
  printf '%s\n' '#!/usr/bin/env bash' "echo \"\$*\" >> '$H/record.calls'" > "$H/record"
  printf '%s\n' '#!/usr/bin/env bash' "echo \"\$*\" >> '$H/post.calls'" "exit \${POST_RC:-0}" > "$H/post"
  # shellcheck disable=SC2016 # the stand-in expands YOLO when it runs
  printf '%s\n' '#!/usr/bin/env bash' 'echo "direct-PR ${YOLO:-on}"' > "$H/mode"
  # the gate proves what it was given: the task's record exists with pr= while it runs, and the extra args arrive
  cat > "$H/gate" <<G
#!/usr/bin/env bash
echo "\$*" >> '$H/gate.calls'
t=; while [ \$# -gt 0 ]; do [ "\$1" = --task ] && t=\$2; shift; done
grep -qx 'pr=$URL' '$H/state/'"\$t".meta && echo present >> '$H/gate.meta' || echo absent >> '$H/gate.meta'
[ -n "\${GATE_REFUSE:-}" ] && { echo "REFUSED: \$GATE_REFUSE"; exit 1; }
echo "GATE OK"; exit 0
G
  chmod +x "$H"/gh "$H"/ready "$H"/pin "$H"/record "$H"/post "$H"/mode "$H"/gate 2>/dev/null
}
chmod_all() { chmod +x "$H"/*; }
# set_ready <review> <risk>: the fm-pr-ready row for PR 7
set_ready() {
  printf '%s\n' '#!/usr/bin/env bash' "cat <<'J'" \
    "{\"rows\":[{\"pr\":7,\"head\":\"$HEAD\",\"review\":\"$1\",\"risk\":\"$2\",\"verdict\":\"READY\"}]}" J > "$H/ready"
  chmod +x "$H/ready"
}
write_review() { # <verdict> <open>
  printf '{"reviewed_head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","verdict":"%s","open_findings":%s,"report":"/r.md"}\n' "$1" "$2" > "$H/data/reviews/acme-widget-7.json"
}
run() { out=$("$MERGE_PR" "$@" 2>&1); rc=$?; }
lines() { printf '%s\n' "$out" | grep -c .; }

test_merged_one_line() {
  new_home merged; chmod_all
  run --by captain "$URL"
  expect_code 0 "$rc" "merge exit"
  assert_equals 1 "$(lines)" "exactly one output line"
  assert_contains "$out" "MERGED widget#7 01234567 by=captain review=ok post=ok" "result line"
  assert_contains "$(cat "$H/gate.calls")" "--task widget-pr7-standin $URL" "gate gets the stand-in task"
  assert_equals present "$(cat "$H/gate.meta")" "stand-in record carries pr= while the gate runs"
  assert_absent "$H/state/widget-pr7-standin.meta" "stand-in no longer live after the merge"
  assert_present "$H/state/parked-$(date -u +%Y%m%d)/widget-pr7-standin.meta" "stand-in is parked"
  assert_contains "$(cat "$H/post.calls")" "$URL" "post-merge ran for the PR"
  assert_grep 'authority=captain' "$H/audit.tsv" "audit row names the authority"
  pass "merge: one line, stand-in during the gate only, post-merge and audit row"
}

test_owner_task_used() {
  new_home owner; chmod_all
  printf 'kind=ship\npr=%s\n' "$URL" > "$H/state/real-task.meta"
  run --by captain "$URL" -- --squash
  expect_code 0 "$rc" "merge with an owning task"
  assert_contains "$(cat "$H/gate.calls")" "--task real-task $URL -- --squash" "owner task and extra args reach the gate"
  assert_present "$H/state/real-task.meta" "the real task record is left alone"
  assert_absent "$H/state/widget-pr7-standin.meta" "no stand-in written"
  pass "merge: owning task is used, extra args pass through"
}

test_refusals_merge_nothing() {
  new_home behind; chmod_all
  sed -i 's/CLEAN/BEHIND/' "$H/pr.json"
  run --by captain "$URL"; expect_code 1 "$rc" "behind exit"
  assert_contains "$out" "REFUSED widget#7: merge state BEHIND" "behind is refused"
  assert_contains "$out" "fm-pr-merge-main.sh" "behind names the way to join main"
  assert_absent "$H/gate.calls" "gate never ran"
  new_home draft; chmod_all
  sed -i 's/"isDraft":false/"isDraft":true/' "$H/pr.json"
  run --by captain "$URL"; expect_code 1 "$rc" "draft exit"
  assert_contains "$out" "the PR is a draft" "draft is refused"
  new_home red; chmod_all
  sed -i 's/CLEAN/UNSTABLE/' "$H/pr.json"
  run --by captain "$URL"; expect_code 1 "$rc" "red check exit"
  assert_contains "$out" "merge state UNSTABLE" "a red or pending check is refused"
  assert_absent "$H/gate.calls" "gate never ran on a red check"
  assert_equals 1 "$(lines)" "a refusal is one line"
  pass "refusals: behind main, draft and red check stop before the gate"
}

test_yolo_guards() {
  new_home yolo; chmod_all
  run --by yolo "$URL"; expect_code 0 "$rc" "yolo on a registered yolo project"
  assert_contains "$out" "by=yolo" "yolo recorded"
  new_home yolooff; chmod_all
  YOLO=off run --by yolo "$URL"; expect_code 1 "$rc" "yolo off exit"
  assert_contains "$out" "not registered with yolo on" "yolo without a registered posture is refused"
  assert_absent "$H/gate.calls" "gate never ran"
  new_home yolohigh; set_ready ok HIGH; chmod_all
  run --by yolo "$URL"; expect_code 1 "$rc" "yolo on HIGH exit"
  assert_contains "$out" "HIGH merges only on the captain's word" "HIGH needs the captain"
  run --by captain "$URL"; expect_code 0 "$rc" "the captain may merge a HIGH PR that the gate passes"
  run "$URL"; expect_code 2 "$rc" "authority is mandatory"
  pass "yolo: needs the registered posture and refuses HIGH; --by is mandatory"
}

test_gate_refusal_is_reported() {
  new_home gate; chmod_all
  GATE_REFUSE="not up to date with main" run --by captain "$URL"
  expect_code 1 "$rc" "gate refusal exit"
  assert_contains "$out" "REFUSED widget#7: not up to date with main" "the gate's reason is the result"
  assert_absent "$H/post.calls" "no post-merge after a refusal"
  assert_absent "$H/state/widget-pr7-standin.meta" "stand-in parked after a refusal too"
  assert_equals 1 "$(lines)" "one line"
  pass "gate: its refusal becomes the one result line, stand-in parked, no post-merge"
}

test_stale_review_pin() {
  new_home pin; set_ready stale MEDIUM; write_review clean 0; chmod_all
  run --by captain "$URL"; expect_code 0 "$rc" "pinned review merges"
  assert_contains "$out" "review=pinned" "result says the review was carried by the pin"
  assert_contains "$(cat "$H/record.calls")" "write acme/widget 7 --head $HEAD --verdict clean --open-findings 0" "clean review re-recorded for this head"
  run --by captain --dry-run "$URL"; expect_code 0 "$rc" "dry run"
  assert_contains "$out" "DRY-RUN-OK widget#7 01234567 by=captain review=pinned" "dry run result"
  assert_equals 1 "$(wc -l < "$H/record.calls" | tr -d ' ')" "dry run does not re-record"
  new_home pininvalid; set_ready stale MEDIUM; write_review clean 0
  printf '%s\n' '#!/usr/bin/env bash' 'echo "PIN-INVALID acme/widget#7 the PRs own change differs"; exit 1' > "$H/pin"; chmod_all
  run --by captain "$URL"; expect_code 1 "$rc" "invalid pin exit"
  assert_contains "$out" "the pin does not carry it" "invalid pin is refused"
  assert_absent "$H/record.calls" "nothing re-recorded"
  new_home pinfindings; set_ready stale MEDIUM; write_review findings 2; chmod_all
  run --by captain "$URL"; expect_code 1 "$rc" "a review with findings is never carried"
  assert_absent "$H/gate.calls" "gate never ran"
  pass "pin: valid pin re-records a clean review, invalid pin or findings refuse"
}

test_dry_run_and_post_refusal() {
  new_home dry; chmod_all
  run --by captain --dry-run "$URL"; expect_code 0 "$rc" "dry run exit"
  assert_contains "$out" "DRY-RUN-OK widget#7" "dry run result"
  assert_contains "$(cat "$H/gate.calls")" "--dry-run" "gate in dry-run mode"
  assert_absent "$H/post.calls" "dry run never runs post-merge"
  assert_absent "$H/state/widget-pr7-standin.meta" "dry run leaves no stand-in"
  new_home postfail; chmod_all
  POST_RC=5 run --by captain "$URL"; expect_code 5 "$rc" "post-merge refusal exit"
  assert_contains "$out" "MERGED widget#7" "the merge itself is still reported"
  assert_contains "$out" "post=exit-5" "post-merge refusal is visible"
  pass "dry run changes nothing; a refused post-merge step is visible"
}

test_missing_tool_refuses() {
  new_home missing; chmod_all
  rm "$H/gate"
  run --by captain "$URL"; expect_code 1 "$rc" "missing gate exit"
  assert_contains "$out" "fm-merge-gate is missing" "a missing guard stops the merge"
  pass "a missing private tool refuses instead of skipping its guard"
}

test_merged_one_line
test_owner_task_used
test_refusals_merge_nothing
test_yolo_guards
test_gate_refusal_is_reported
test_stale_review_pin
test_dry_run_and_post_refusal
test_missing_tool_refuses

echo '# all fm-merge-pr tests passed'
