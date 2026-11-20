#!/usr/bin/env bash
# tests/fm-cloudroom.test.sh - fake-room-cli unit tests for bin/fm-cloudroom.sh
# (docs/cloudroom-backend.md). The fake logs every call and answers from
# per-subcommand canned files, so spawn metadata, the parent-side status
# return channel (sync), its once-per-reply dedupe, scout report capture, and
# the close refusal are pinned without a Cloudroom account.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by fm-cloudroom.sh)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-cloudroom-tests)
FB="$TMP_ROOT/fakebin"
mkdir -p "$FB" "$TMP_ROOT/resp"
cat > "$FB/room-cli" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_ROOM_LOG"
case "$1 $2" in
  "thread spawn") echo 'Starting a child...'; echo '{"id":"thr_fake1","note":"ok"}' ;;
  "thread output") cat "$FAKE_ROOM_RESP/output.json" ;;
  "thread show") echo '{"id":"thr_fake1","state":"replied","status":"idle","title":"fm-t1"}' ;;
  "thread tell") echo '{"state":"accepted"}' ;;
  "thread archive") echo '{"state":"archived"}' ;;
  "thread stop") echo '{"state":"stopped"}' ;;
  "status ") echo '{}' ;;
  *) echo "{}" ;;
esac
SH
chmod +x "$FB/room-cli"

export PATH="$FB:$PATH"
export FAKE_ROOM_LOG="$TMP_ROOT/room.log" FAKE_ROOM_RESP="$TMP_ROOT/resp"
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME"
CR="$ROOT/bin/fm-cloudroom.sh"
STATE="$FM_HOME/state"
printf 'Fix the flaky login test.\n' > "$TMP_ROOT/task.md"

reply() {  # <state> <reply-text>
  jq -n --arg s "$1" --arg r "$2" '{id:"thr_fake1",state:$s,reply:$r}' > "$TMP_ROOT/resp/output.json"
}

test_spawn_records_meta_and_refuses_duplicate() {
  # spawn records Cloudroom metadata and the dispatch status line.
  out=$("$CR" spawn t1 --repo you/app --task-file "$TMP_ROOT/task.md" --model haiku --effort low 2>&1)
  assert_contains "$out" "spawned: t1 -> thr_fake1" "spawn reports the thread id"
  assert_contains "$(cat "$STATE/t1.meta")" "backend=cloudroom" "meta records backend=cloudroom"
  assert_contains "$(cat "$STATE/t1.meta")" "cloudroom_thread_id=thr_fake1" "meta records the thread id"
  assert_contains "$(cat "$STATE/t1.meta")" "branch=fm/t1" "meta records the ship branch"
  assert_contains "$(cat "$STATE/t1.status")" "working [at=" "spawn appends a working line"
  assert_contains "$(cat "$FAKE_ROOM_LOG")" "--model haiku" "spawn passes the model"
  assert_contains "$(cat "$FAKE_ROOM_LOG")" "--reasoning-level low" "spawn passes the effort"
  assert_contains "$(cat "$FM_HOME/data/t1/cloudroom-prompt.md")" "Fix the flaky login test." "prompt embeds the task"
  assert_contains "$(cat "$FM_HOME/data/t1/cloudroom-prompt.md")" "gh repo clone you/app \$HOME/fm-t1" "prompt clones fresh"

  # A second spawn of the same id refuses.
  if "$CR" spawn t1 --repo you/app --task-file "$TMP_ROOT/task.md" >/dev/null 2>&1; then
    fail "duplicate spawn refuses"
  else
    : "duplicate spawn refuses"
  fi
  pass "test_spawn_records_meta_and_refuses_duplicate"
}

test_sync_appends_once_and_flags_missing_status() {
  # sync copies status lines from a finished reply exactly once.
  reply idle $'Opened the PR.\ndone [at=1700000000]: fixed, PR https://github.com/you/app/pull/7'
  out=$("$CR" sync t1)
  assert_contains "$out" "t1: done [at=1700000000]" "sync prints the new status line"
  assert_contains "$(tail -n 1 "$STATE/t1.status")" "pull/7" "sync appends the status line"
  before=$(wc -l < "$STATE/t1.status")
  "$CR" sync --all >/dev/null
  after=$(wc -l < "$STATE/t1.status")
  [ "$before" = "$after" ] && : "sync does not re-append a seen reply" || fail "sync does not re-append a seen reply"

  # A finished turn with no status line becomes a blocked event.
  reply idle 'I did some stuff.'
  "$CR" sync t1 >/dev/null
  assert_contains "$(tail -n 1 "$STATE/t1.status")" "blocked [at=" "missing status line is surfaced as blocked"
  pass "test_sync_appends_once_and_flags_missing_status"
}

test_close_refuses_until_done() {
  # close refuses while not done, then archives once done.
  if "$CR" close t1 >/dev/null 2>&1; then fail "close refuses a blocked task"; else : "close refuses a blocked task"; fi
  reply idle 'done [at=1700000001]: all good'
  "$CR" sync t1 >/dev/null
  out=$("$CR" close t1)
  assert_contains "$out" "closed: t1" "close archives a done task"
  [ -f "$STATE/closed/t1.meta" ] && : "close moves meta to state/closed" || fail "close moves meta to state/closed"
  assert_contains "$(cat "$FAKE_ROOM_LOG")" "thread archive thr_fake1" "close archives the exact thread"
  pass "test_close_refuses_until_done"
}

test_scout_report_send_peek_and_refusal() {
  # Scout: done reply is saved as the report.
  "$CR" spawn s1 --kind scout --repo you/app --task-file "$TMP_ROOT/task.md" >/dev/null
  assert_contains "$(cat "$FM_HOME/data/s1/cloudroom-prompt.md")" "SCOUT task" "scout prompt forbids PRs"
  reply idle $'# Report\nRoot cause: race.\ndone [at=1700000002]: found the race'
  "$CR" sync s1 >/dev/null
  assert_contains "$(cat "$FM_HOME/data/s1/report.md")" "Root cause: race." "scout done saves report.md"

  # send and peek go to the recorded thread.
  "$CR" send s1 'also check logout' >/dev/null
  assert_contains "$(tail -n 1 "$FAKE_ROOM_LOG")" "thread tell thr_fake1 also check logout" "send tells the recorded thread"
  assert_contains "$("$CR" peek s1)" "state: replied" "peek shows thread state"

  # Non-Cloudroom tasks are refused.
  printf 'backend=tmux\nwindow=fm-x\n' > "$STATE/x.meta"
  if "$CR" send x hi >/dev/null 2>&1; then fail "send refuses a non-Cloudroom task"; else : "send refuses a non-Cloudroom task"; fi
  pass "test_scout_report_send_peek_and_refusal"
}

fm_test_run test_spawn_records_meta_and_refuses_duplicate test_sync_appends_once_and_flags_missing_status test_close_refuses_until_done test_scout_report_send_peek_and_refusal
