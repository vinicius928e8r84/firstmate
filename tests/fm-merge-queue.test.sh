#!/usr/bin/env bash
# Behavioral coverage for bin/fm-merge-queue.sh against a local bare "GitHub": three simulated PRs
# are joined with main one at a time, each CI-waited and merged, with stand-ins for gh, the
# readiness list and fm-merge-pr.sh that read and write the same bare repository. The real
# bin/fm-pr-merge-main.sh runs for every join, so the rules file, the identity and the plain
# (never forced, never rebased) push are exercised for real. Also: a conflict in code stops the
# queue on one line, red CI, a refused merge, an exhausted wait that resumes, a push the remote
# rejects, an ineligible PR skipped, --dry-run, the off switch and the usage errors.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity

TMP_ROOT=$(fm_test_tmproot fm-merge-queue)
QUEUE="$ROOT/bin/fm-merge-queue.sh"

# The stand-ins. MQ_ORIGIN is the bare repo, MQ_DIR the per-world scratch for switches and counters.
cat > "$TMP_ROOT/gh" <<'SH'
#!/usr/bin/env bash
# gh pr view -R <slug> <n> --json ...
[ "$1 $2" = "pr view" ] || exit 2
n=$5
head=$(git -C "$MQ_ORIGIN" rev-parse "refs/heads/pr$n") || exit 1
state=OPEN; git -C "$MQ_ORIGIN" merge-base --is-ancestor "$head" refs/heads/main && state=MERGED
jq -n --arg h "$head" --arg r "pr$n" --arg s "$state" \
  '{headRefOid:$h,headRefName:$r,baseRefName:"main",isCrossRepository:false,state:$s}'
SH
cat > "$TMP_ROOT/ready" <<'SH'
#!/usr/bin/env bash
# fm-pr-ready.sh --repo <slug> --json --no-cache: one row per open PR branch pr<N> of the bare repo.
main=$(git -C "$MQ_ORIGIN" rev-parse refs/heads/main)
rows='[]'
for ref in $(git -C "$MQ_ORIGIN" for-each-ref --format='%(refname:short)' 'refs/heads/pr*'); do
  n=${ref#pr}; head=$(git -C "$MQ_ORIGIN" rev-parse "refs/heads/$ref")
  git -C "$MQ_ORIGIN" merge-base --is-ancestor "$head" "$main" && continue
  review=ok; [ -f "$MQ_DIR/review-$n" ] && review=$(cat "$MQ_DIR/review-$n")
  ms=CLEAN; git -C "$MQ_ORIGIN" merge-base --is-ancestor "$main" "$head" || ms=BEHIND
  ci=green
  if ! grep -qx "$head" "$MQ_DIR/initial"; then       # a head the queue pushed: new CI
    if [ -f "$MQ_DIR/red-pr$n" ]; then ci=red
    else
      c=$(cat "$MQ_DIR/polls-$head" 2>/dev/null || echo 0); echo $((c + 1)) > "$MQ_DIR/polls-$head"
      [ "$c" -ge "${MQ_PENDING_POLLS:-1}" ] || ci=pending
    fi
  fi
  rows=$(jq -c --argjson n "$n" --arg h "$head" --arg rv "$review" --arg ms "$ms" --arg ci "$ci" \
    '. + [{pr:$n,head:$h,review:$rv,merge_state:$ms,draft:false,risk:"LOW",url:("https://github.com/acme/widget/pull/"+($n|tostring)),ci:{state:$ci}}]' <<<"$rows")
done
jq -c '{rows:.}' <<<"$rows"
SH
cat > "$TMP_ROOT/merge-pr" <<'SH'
#!/usr/bin/env bash
# fm-merge-pr.sh --by <who> <url>: refuses a PR behind main, else merges it into the bare main.
by=$2; url=$3; n=${url##*/}
echo "$*" >> "$MQ_DIR/merge-pr.calls"
head=$(git -C "$MQ_ORIGIN" rev-parse "refs/heads/pr$n")
if [ -f "$MQ_DIR/refuse-pr$n" ]; then echo "REFUSED widget#$n: $(cat "$MQ_DIR/refuse-pr$n")"; exit 1; fi
if ! git -C "$MQ_ORIGIN" merge-base --is-ancestor refs/heads/main "$head"; then
  echo "REFUSED widget#$n: merge state BEHIND: join main first"; exit 1; fi
d=$(mktemp -d); git clone -q "file://$MQ_ORIGIN" "$d/c"
git -C "$d/c" fetch -q origin "refs/heads/pr$n"
git -C "$d/c" merge -q --no-ff -m "Merge PR $n" FETCH_HEAD && git -C "$d/c" push -q origin HEAD:refs/heads/main
rm -rf "$d"
echo "MERGED widget#$n ${head:0:8} by=$by review=ok post=ok"
SH
chmod +x "$TMP_ROOT/gh" "$TMP_ROOT/ready" "$TMP_ROOT/merge-pr"

# new_world <name> [conflicting-files...]: a bare origin whose main holds VERSION, INDEX.md and code.js, and PR
# branches pr1..pr3, each from the seed, each bumping VERSION, appending to INDEX.md and adding its own file.
# Files named after the name are also changed by pr<N> in code.js when MQ_CODE_PR is set.
new_world() {
  W="$TMP_ROOT/$1"; mkdir -p "$W/seed" "$W/mq" "$W/home/config"
  git init -q -b main "$W/seed"
  printf '0.4.25\n' > "$W/seed/VERSION"; printf '| a |\n' > "$W/seed/INDEX.md"; printf 'c1\nc2\nc3\n' > "$W/seed/code.js"
  git -C "$W/seed" add . && git -C "$W/seed" commit -qm seed
  git clone -q --bare "$W/seed" "$W/origin.git"
  local n
  for n in 1 2 3; do
    git clone -q "file://$W/origin.git" "$W/c$n"
    git -C "$W/c$n" checkout -q -b "pr$n"
    printf '0.4.%s\n' $((25 + n)) > "$W/c$n/VERSION"
    printf '| a |\n| pr%s |\n' "$n" > "$W/c$n/INDEX.md"
    printf 'feature %s\n' "$n" > "$W/c$n/feature$n.txt"
    [ "${MQ_CODE_PR:-}" = "$n" ] && printf 'c1\nPR%s\nc3\n' "$n" > "$W/c$n/code.js"
    git -C "$W/c$n" add -A && git -C "$W/c$n" commit -qm "pr$n"
    git -C "$W/c$n" push -q origin "pr$n"
  done
  for n in 1 2 3; do git -C "$W/origin.git" rev-parse "refs/heads/pr$n"; done > "$W/mq/initial"
  printf '%s\n' '# identity' 'origin pinned@example.com Pinned Author' > "$W/home/config/commit-identity"
  printf '%s\n' 'origin VERSION keep-pr' 'origin INDEX.md union' > "$W/home/config/merge-mechanical"
  export FM_HOME="$W/home" FM_USAGE_LEDGER_OFF=1
  export MQ_ORIGIN="$W/origin.git" MQ_DIR="$W/mq"
  export FM_MQ_GH="$TMP_ROOT/gh" FM_READY_BIN="$TMP_ROOT/ready" FM_MQ_MERGE_PR="$TMP_ROOT/merge-pr"
  export FM_MQ_CLONE_URL="file://$W/origin.git" FM_MQ_WORK="$W/scratch" FM_MQ_POLL=0
  unset MQ_PENDING_POLLS
}
run() { out=$("$QUEUE" "$@" 2>&1); rc=$?; }
refs() { git -C "$W/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads; }
show() { git -C "$W/origin.git" show "$1:$2"; }

test_three_prs_in_turn() {
  new_world three
  local before1 before2 before3
  before1=$(git -C "$W/origin.git" rev-parse pr1); before2=$(git -C "$W/origin.git" rev-parse pr2); before3=$(git -C "$W/origin.git" rev-parse pr3)
  run --slug acme/widget --by yolo --order '1 2 3'
  [ "$rc" = 0 ] || echo "$out" >&2
  expect_code 0 "$rc" "the queue drains"
  printf '%s\n' "$out" > "$W/transcript.txt"
  assert_contains "$out" "DONE merged=3" "all three merged"
  assert_equals "3" "$(printf '%s\n' "$out" | grep -c '^MERGED ')" "three merge lines from fm-merge-pr"
  assert_contains "$out" "JOINED #1 ${before1:0:8} -> ${before1:0:8} (already current)" "the first PR needed no join"
  assert_contains "$out" "JOINED #2 ${before2:0:8} -> " "the second PR is joined to main"
  assert_contains "$out" "VERSION (keep-pr)" "the version conflict is settled by rule"
  assert_contains "$out" "INDEX.md (union)" "the index conflict is settled by rule"
  assert_not_contains "$out" "SKIP" "a merged PR is not reported as skipped"
  assert_contains "$out" "JOINED #3 ${before3:0:8} -> " "the third PR is joined to main"
  assert_contains "$out" "WAITING #2" "the queue waited for CI of the new head"
  # order: each merge line comes after its own join and before the next PR's join
  assert_equals "1 2 3" "$(printf '%s\n' "$out" | sed -n 's/^MERGED widget#\([0-9]\) .*/\1/p' | paste -sd' ')" "merged in the given order"
  git -C "$W/origin.git" merge-base --is-ancestor "$before2" pr2 || fail "the pushed branch is a fast-forward of what it was (no rebase, no force)"
  git -C "$W/origin.git" merge-base --is-ancestor "$before3" pr3 || fail "the third branch is a fast-forward of what it was"
  assert_equals "0.4.28" "$(show main VERSION)" "main carries the last PR's number"
  assert_equals "| a |,| pr1 |,| pr2 |,| pr3 |" "$(show main INDEX.md | sort | paste -sd,)" "index has every row once"
  for n in 1 2 3; do show main "feature$n.txt" >/dev/null || fail "feature $n reached main"; done
  assert_equals "pinned@example.com" "$(git -C "$W/origin.git" log -1 --format=%ae pr3)" "the join commit carries the registered identity"
  assert_equals "3" "$(wc -l < "$W/mq/merge-pr.calls" | tr -d ' ')" "fm-merge-pr was asked once per PR"
  assert_contains "$(cat "$W/mq/merge-pr.calls")" "--by yolo https://github.com/acme/widget/pull/2" "the authority is passed through with the PR url"
  pass "three simulated PRs: joined and merged one at a time, mechanical conflicts settled, no force"
}

test_code_conflict_stops_with_one_line() {
  MQ_CODE_PR=2 new_world code
  git clone -q "file://$W/origin.git" "$W/pusher"
  printf 'c1\nMAIN\nc3\n' > "$W/pusher/code.js"
  git -C "$W/pusher" commit -qam 'main edits code' && git -C "$W/pusher" push -q origin main
  fm_test_remove_tree "$W/pusher"
  local before2 before3
  before2=$(git -C "$W/origin.git" rev-parse pr2); before3=$(git -C "$W/origin.git" rev-parse pr3)
  # pr1 first merges; pr2 then collides with main in code.js
  run --slug acme/widget --by yolo --order '1 2 3'
  expect_code 10 "$rc" "a conflict in code is exit 10"
  assert_equals "1" "$(printf '%s\n' "$out" | grep -c '^STOPPED ')" "exactly one stop line"
  assert_contains "$out" "STOPPED #2: conflict in code (code.js)" "the stop line names the PR and the file"
  assert_contains "$out" "MERGED widget#1" "the PR before it had merged"
  assert_equals "$before2" "$(git -C "$W/origin.git" rev-parse pr2)" "the stopped PR's branch was not touched"
  assert_equals "$before3" "$(git -C "$W/origin.git" rev-parse pr3)" "the PR behind it was not touched"
  assert_equals "" "$(git -C "$W/scratch/acme__widget" status --porcelain --untracked-files=no)" "the scratch clone is left without an open merge"
  pass "a conflict in code: one line, nothing pushed, the queue stops"
}

test_red_ci_refused_merge_and_wait() {
  new_world red
  touch "$W/mq/red-pr2"
  run --slug acme/widget --by yolo --order '1 2 3'
  expect_code 1 "$rc" "red CI stops the queue"
  assert_contains "$out" "STOPPED #2: CI is red on" "red CI is named"
  assert_not_contains "$out" "MERGED widget#2" "a red PR is not merged"
  assert_not_contains "$out" "JOINED #3" "the PR behind a red one is not touched"
  assert_equals "1" "$(wc -l < "$W/mq/merge-pr.calls" | tr -d ' ')" "only the first PR reached fm-merge-pr"

  new_world refused
  printf 'review is of an older head and the pin does not carry it' > "$W/mq/refuse-pr1"
  run --slug acme/widget --by captain --order '1 2'
  expect_code 1 "$rc" "a refused merge stops the queue"
  assert_contains "$out" "REFUSED widget#1: review is of an older head" "fm-merge-pr's line is passed through"
  assert_contains "$out" "STOPPED #1: fm-merge-pr.sh did not merge it" "and the queue stops on it"
  assert_not_contains "$out" "#2" "the next PR is not looked at"

  new_world wait
  export MQ_PENDING_POLLS=1000
  run --slug acme/widget --by yolo --order '1 2' --wait 0
  expect_code 1 "$rc" "an exhausted wait stops the queue"
  assert_contains "$out" "STOPPED #2: CI of" "the wait is named"
  assert_contains "$out" "run the queue again later to resume" "and the stop says how to continue"
  assert_not_contains "$(cat "$W/mq/merge-pr.calls")" "pull/2" "not merged while CI is pending"
  # resume: the head on the branch is the joined one; CI is green now, so the next run only merges it
  git -C "$W/origin.git" rev-parse pr2 >> "$W/mq/initial"
  unset MQ_PENDING_POLLS
  run --slug acme/widget --by yolo --order '2'
  expect_code 0 "$rc" "the second run resumes and finishes"
  assert_contains "$out" "(already current)" "no second join"
  assert_contains "$out" "MERGED widget#2" "merged on resume"
  pass "red CI, a refused merge and an exhausted wait each stop the queue; the wait resumes"
}

test_rejected_push_and_ineligible_pr() {
  new_world push
  cat > "$W/origin.git/hooks/update" <<'SH'
#!/usr/bin/env bash
[ "$1" = refs/heads/pr2 ] && { echo "protected branch" >&2; exit 1; }
exit 0
SH
  chmod +x "$W/origin.git/hooks/update"
  run --slug acme/widget --by yolo --order '1 2 3'
  expect_code 3 "$rc" "a rejected push is an error exit"
  assert_contains "$out" "STOPPED #2: push of the joined head to pr2 was refused" "the refusal is the stop line"
  assert_not_contains "$out" "MERGED widget#2" "nothing merged after a refused push"

  new_world skip
  printf 'none' > "$W/mq/review-1"
  run --slug acme/widget --by yolo --order '1 2'
  expect_code 0 "$rc" "queue with an ineligible first PR"
  assert_contains "$out" "SKIP #1: review is none" "the unreviewed PR is skipped, once"
  assert_equals "1" "$(printf '%s\n' "$out" | grep -c '^SKIP #1')" "one skip line, not one per turn"
  assert_contains "$out" "MERGED widget#2" "the PR behind it still goes"
  assert_not_contains "$(cat "$W/mq/merge-pr.calls")" "pull/1" "the skipped PR is never merged"
  pass "a rejected push stops the queue; an ineligible PR is skipped without blocking the others"
}

test_dry_run_switch_and_usage() {
  new_world dry
  local refs_before
  git clone -q "file://$W/origin.git" "$W/pusher"
  printf '0.4.26\n' > "$W/pusher/VERSION"
  git -C "$W/pusher" commit -qam 'main moves' && git -C "$W/pusher" push -q origin main
  fm_test_remove_tree "$W/pusher"
  refs_before=$(refs)
  run --slug acme/widget --by yolo --order '2 3' --dry-run
  expect_code 0 "$rc" "dry run exit"
  assert_contains "$out" "WOULD-JOIN #2" "the join is planned"
  assert_contains "$out" "VERSION (keep-pr)" "and so is its mechanical settlement"
  assert_contains "$out" "DRY-RUN-OK merged=0 joined=1" "dry run ends on its own line"
  assert_equals "$refs_before" "$(refs)" "nothing was pushed or merged"
  assert_absent "$W/mq/merge-pr.calls" "fm-merge-pr was not called"

  new_world off
  touch "$W/home/config/merge-queue-off"
  run --slug acme/widget --by yolo --order '1'
  expect_code 0 "$rc" "disabled queue exits quietly"
  assert_contains "$out" "DISABLED" "the off switch is reported"
  assert_absent "$W/mq/merge-pr.calls" "nothing ran while disabled"

  run --slug acme/widget --order '1'
  expect_code 2 "$rc" "--by is mandatory"
  run --by yolo --order '1'
  expect_code 2 "$rc" "--slug is mandatory"
  run --slug acme/widget --by nobody --order '1'
  expect_code 2 "$rc" "--by takes captain or yolo only"
  pass "dry run changes nothing, the off switch stops everything, usage is strict"
}

fm_test_run test_three_prs_in_turn test_code_conflict_stops_with_one_line test_red_ci_refused_merge_and_wait \
  test_rejected_push_and_ineligible_pr test_dry_run_switch_and_usage
