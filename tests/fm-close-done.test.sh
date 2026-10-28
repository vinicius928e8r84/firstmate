#!/usr/bin/env bash
# tests/fm-close-done.test.sh - bin/fm-close-done.sh lists the workers that
# reported done but still hold an open agent, and closes them one at a time
# after saving the session log and confirming nothing unmerged would be lost.
#
# Real tmux windows on a private socket run a process named like an agent, so
# the endpoint classification and the log capture are the real code. Only the
# two collaborators with their own suites are stubbed in a copy of bin/:
# fm-crew-state.sh (answers from a file) and fm-control.sh (records the call and
# kills the window, as a verified `exit` would).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "ok - fm-close-done: skipped (tmux not installed)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-close-done)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
export TMUX_TMPDIR=$TMP_ROOT/tmux
mkdir -p "$TMUX_TMPDIR"
trap 'tmux kill-server >/dev/null 2>&1; rm -rf "$TMP_ROOT"' EXIT

# An executable whose process name classifies as an agent.
AGENT_BIN=$TMP_ROOT/agentbin/pi
mkdir -p "$TMP_ROOT/agentbin"
cp "$(command -v sleep)" "$AGENT_BIN"

make_fixture() {  # <name>
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/crew"
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
cat "$FM_FIXTURE/crew/$1" 2>/dev/null || echo "state: unknown · source: none · no fixture"
SH
  cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
echo "$1 $2" >> "$FM_FIXTURE/control.log"
[ ! -e "$FM_FIXTURE/control-fails" ] || { echo "control refused" >&2; exit 1; }
tmux kill-window -t "fixture:fm-$1"
SH
  chmod +x "$dir/bin/fm-crew-state.sh" "$dir/bin/fm-control.sh"
  printf '%s\n' "$dir"
}

# add_worker <fixture> <id> <kind> <crew-state-line> [dirty]
add_worker() {
  local dir=$1 id=$2 kind=$3 line=$4 dirty=${5:-}
  local wt=$dir/wt/$id
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  [ -z "$dirty" ] || echo changed > "$wt/leftover.txt"
  tmux has-session -t fixture 2>/dev/null \
    && tmux new-window -d -t fixture: -n "fm-$id" "exec '$AGENT_BIN' 600" \
    || tmux new-session -d -s fixture -n "fm-$id" "exec '$AGENT_BIN' 600"
  printf 'window=fixture:fm-%s\nworktree=%s\nproject=%s\nharness=pi\nkind=%s\nbackend=tmux\n' \
    "$id" "$wt" "$dir/proj" "$kind" > "$dir/home/state/$id.meta"
  printf '%s\n' "$line" > "$dir/crew/$id"
}

run_close() {  # <fixture> <args...>
  local dir=$1; shift
  FM_FIXTURE=$dir FM_HOME=$dir/home HOME=$dir "$dir/bin/fm-close-done.sh" "$@" > "$dir/out" 2>&1
}

wait_agent_gone() {  # <id>
  local i=0
  while [ "$i" -lt 50 ]; do
    tmux list-windows -t fixture -F '#{window_name}' 2>/dev/null | grep -qx "fm-$1" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_lists_only_done_workers_with_an_open_agent() {
  local dir status
  dir=$(make_fixture list)
  add_worker "$dir" w-done ship "state: done · source: status-log · ready"
  add_worker "$dir" w-busy ship "state: working · source: pane · busy"
  add_worker "$dir" w-mate secondmate "state: done · source: status-log · idle"
  run_close "$dir"
  status=$?
  expect_code 0 "$status" "listing must succeed: $(cat "$dir/out")"
  grep -q '^candidate w-done' "$dir/out" || fail "a done worker with an open agent was not listed: $(cat "$dir/out")"
  ! grep -q 'w-busy\|w-mate' "$dir/out" || fail "a working worker or a secondmate was listed: $(cat "$dir/out")"
  [ ! -e "$dir/control.log" ] || fail "listing must not close anything: $(cat "$dir/control.log")"
  tmux list-windows -t fixture -F '#{window_name}' | grep -qx fm-w-done || fail "listing killed the agent"
  pass "fm-close-done: lists only done workers with an open agent and closes nothing without --close"
}

test_close_saves_the_log_first_and_closes_through_fm_control_without_force() {
  local dir status log
  dir=$(make_fixture close)
  add_worker "$dir" c-one ship "state: done · source: status-log · ready"
  add_worker "$dir" c-two ship "state: done · source: status-log · ready"
  tmux send-keys -t fixture:fm-c-one 'marker' 2>/dev/null || true
  run_close "$dir" --close
  status=$?
  expect_code 0 "$status" "closing two clean done workers must succeed: $(cat "$dir/out")"
  [ "$(cat "$dir/control.log")" = "$(printf 'c-one exit\nc-two exit')" ] || fail "fm-control must be called once per worker, in order, with exit only: $(cat "$dir/control.log")"
  wait_agent_gone c-one || fail "c-one's agent is still open"
  wait_agent_gone c-two || fail "c-two's agent is still open"
  log=$(ls "$dir"/home/data/c-one/session-log-*.txt 2>/dev/null | head -1)
  [ -n "$log" ] && [ -s "$log" ] || fail "no session log was saved for c-one before closing"
  [ "$(stat -c %a "$log")" = 600 ] || fail "the session log must be private (0600), got $(stat -c %a "$log")"
  grep -q '^closed c-one' "$dir/out" && grep -q '^closed c-two' "$dir/out" || fail "closed lines missing: $(cat "$dir/out")"
  [ -d "$dir/wt/c-one" ] && [ -d "$dir/home/state" ] && [ -f "$dir/home/state/c-one.meta" ] || fail "closing must not delete the worktree or the task record"
  pass "fm-close-done: saves each log first, then closes through fm-control exit, one at a time"
}

test_uncommitted_work_is_never_closed() {
  local dir status
  dir=$(make_fixture dirty)
  add_worker "$dir" d-one ship "state: done · source: status-log · ready" dirty
  run_close "$dir" --close
  status=$?
  expect_code 1 "$status" "a worker with unmerged changes must be skipped with a failure status: $(cat "$dir/out")"
  grep -q '^skipped d-one: worktree has uncommitted' "$dir/out" || fail "the skip reason is missing: $(cat "$dir/out")"
  [ ! -e "$dir/control.log" ] || fail "a worker with uncommitted changes was closed"
  tmux list-windows -t fixture -F '#{window_name}' | grep -qx fm-d-one || fail "the dirty worker's agent was killed"
  [ -f "$dir/wt/d-one/leftover.txt" ] || fail "the uncommitted file was lost"
  ls "$dir"/home/data/d-one/session-log-*.txt >/dev/null 2>&1 || fail "the log must be saved before the safety check refuses"
  pass "fm-close-done: a worker with uncommitted or untracked changes is skipped, not closed"
}

test_scout_needs_its_report() {
  local dir status
  dir=$(make_fixture scout)
  add_worker "$dir" s-one scout "state: done · source: status-log · reported"
  run_close "$dir" --close
  status=$?
  expect_code 1 "$status" "a scout without a report must be skipped: $(cat "$dir/out")"
  [ ! -e "$dir/control.log" ] || fail "a scout without a report was closed"
  mkdir -p "$dir/home/data/s-one"
  echo "report" > "$dir/home/data/s-one/report.md"
  run_close "$dir" --close
  status=$?
  expect_code 0 "$status" "a scout with its report must close: $(cat "$dir/out")"
  grep -q 'closed s-one' "$dir/out" || fail "the scout was not closed: $(cat "$dir/out")"
  pass "fm-close-done: a scout is closed only once its report exists"
}

test_a_failed_close_stops_the_run() {
  local dir status
  dir=$(make_fixture fail)
  add_worker "$dir" f-one ship "state: done · source: status-log · ready"
  add_worker "$dir" f-two ship "state: done · source: status-log · ready"
  : > "$dir/control-fails"
  run_close "$dir" --close
  status=$?
  expect_code 1 "$status" "a refused close must fail the run: $(cat "$dir/out")"
  [ "$(wc -l < "$dir/control.log")" = 1 ] || fail "the run continued after a failed close: $(cat "$dir/control.log")"
  grep -q '^failed f-one' "$dir/out" || fail "the failed close was not reported: $(cat "$dir/out")"
  pass "fm-close-done: a failed close stops the run so cleanups stay one at a time"
}

test_requires_an_explicit_home() {
  local dir status
  dir=$(make_fixture nohome)
  env -u FM_HOME FM_FIXTURE="$dir" "$dir/bin/fm-close-done.sh" > "$dir/out" 2>&1
  status=$?
  expect_code 2 "$status" "a missing FM_HOME must be refused: $(cat "$dir/out")"
  pass "fm-close-done: refuses to guess a firstmate home"
}

test_lists_only_done_workers_with_an_open_agent
test_close_saves_the_log_first_and_closes_through_fm_control_without_force
test_uncommitted_work_is_never_closed
test_scout_needs_its_report
test_a_failed_close_stops_the_run
test_requires_an_explicit_home
