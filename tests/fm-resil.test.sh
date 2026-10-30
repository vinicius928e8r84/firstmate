#!/usr/bin/env bash
# Behavior tests for bin/fm-resil.sh, the resilience loops that need a clock:
#   1. an unconfirmed secondmate steer is replayed through the printed
#      correlation-reusing command at 1, 4 and 15 minutes, ends on delivery, and
#      leaves one card after the last try;
#   2. a stopped worker (agent gone, or its session ends in an API error) is
#      relaunched through fm-control after the stop has lasted 10 minutes, up to
#      four times at 2, 4, 8 and 16 minutes, then one card; busy, done, paused,
#      decision-holding and secondmate lanes are never touched; a quiet half
#      hour starts the count over;
# Every acting command is a stub that records its arguments; nothing touches a
# real lane, pane or remote.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESIL="$ROOT/bin/fm-resil.sh"
TMP_ROOT=$(fm_test_tmproot fm-resil)
T0=1800000000

make_home() {  # <name> -> home dir
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/config" "$h/data" "$h/stubs"
  cat > "$h/stubs/send" <<'SH'
#!/usr/bin/env bash
{ printf 'home=%s state=%s corr=%s\n' "${FM_HOME:-}" "${FM_STATE_OVERRIDE:-}" "${FM_PENDING_REPLY_EXISTING_CORR:-}"; printf 'arg=%s\n' "$@"; } >> "$STUB_DIR/send.calls"
exit "$(cat "$STUB_DIR/send.rc" 2>/dev/null || echo 0)"
SH
  cat > "$h/stubs/control" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/control.calls"
exit "$(cat "$STUB_DIR/control.rc" 2>/dev/null || echo 0)"
SH
  cat > "$h/stubs/crew" <<'SH'
#!/usr/bin/env bash
cat "$STUB_DIR/crew.$1" 2>/dev/null || echo "state: unknown · source: none · no stub"
SH
  cat > "$h/stubs/apierr" <<'SH'
#!/usr/bin/env bash
f="$STUB_DIR/apierr.$(basename "$1")"
[ -f "$f" ] && cat "$f" && exit 0
exit 1
SH
  cat > "$h/stubs/close" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/close.calls"
SH
  chmod +x "$h/stubs/"*
  printf '%s\n' "$h"
}

resil() {  # <home> <now> <args...>
  local h=$1 now=$2
  shift 2
  STUB_DIR="$h/stubs" FM_HOME="$h" FM_RESIL_NOW="$now" \
    FM_RESIL_SEND_CMD="$h/stubs/send" FM_RESIL_CONTROL_CMD="$h/stubs/control" \
    FM_RESIL_CREW_STATE_CMD="$h/stubs/crew" FM_RESIL_APIERR_CMD="$h/stubs/apierr" \
    FM_RESIL_CLOSE_CMD="$h/stubs/close" \
    "$RESIL" "$@" 2>&1
}

calls() { grep -c "^$2" "$1" 2>/dev/null || true; }

# --- resend -------------------------------------------------------------------

pending() {  # <home> <corr> <phase> [delivered-epoch]
  mkdir -p "$1/state/pending-replies"
  printf 'schema=fm-pending-reply.v1\ncorr_id=%s\ntask_id=rsm\nphase=%s\ndelivered_epoch=%s\n' "$2" "$3" "${4:-}" \
    > "$1/state/pending-replies/$2"
}

save_resend() {  # <home> <corr> <state-override> <args...>
  local h=$1 corr=$2 so=$3
  shift 3
  bash -c '. "$1/bin/fm-resil-lib.sh"; shift; fm_resil_resend_save "$@"' _ "$ROOT" "$h/state" "$corr" "$h" "$so" "$@"
  printf '0 %s\n' "$T0" > "$h/state/resil/resend/$corr.tries"
}

test_resend_replays_the_printed_command_on_schedule() {
  local h corr=0123456789abcdef
  h=$(make_home resend)
  pending "$h" "$corr" delivery_unknown
  save_resend "$h" "$corr" "" rsm "please rename the metric"
  resil "$h" $((T0 + 30)) resend >/dev/null
  [ ! -e "$h/stubs/send.calls" ] || fail "a resend ran before its first minute passed"
  echo 1 > "$h/stubs/send.rc"
  resil "$h" $((T0 + 61)) resend >/dev/null
  assert_equals 1 "$(calls "$h/stubs/send.calls" home=)" "the first resend did not run at one minute"
  assert_contains "$(cat "$h/stubs/send.calls")" "home=$h state= corr=$corr" "the resend lost the home or the correlation"
  assert_equals "arg=rsm arg=please rename the metric" "$(grep '^arg=' "$h/stubs/send.calls" | paste -sd' ' | sed 's/ arg=/ arg=/')" \
    "the resend did not pass the original arguments"
  resil "$h" $((T0 + 61 + 239)) resend >/dev/null
  assert_equals 1 "$(calls "$h/stubs/send.calls" home=)" "the second resend ran before four minutes after the first"
  resil "$h" $((T0 + 61 + 241)) resend >/dev/null
  assert_equals 2 "$(calls "$h/stubs/send.calls" home=)" "the second resend did not run at four minutes"
  resil "$h" $((T0 + 61 + 241 + 901)) resend >/dev/null
  assert_equals 3 "$(calls "$h/stubs/send.calls" home=)" "the third resend did not run at fifteen minutes"
  assert_absent "$h/state/resil/cards/send-$corr.card" "a card appeared before the tries were used up"
  resil "$h" $((T0 + 100000)) resend >/dev/null
  assert_equals 3 "$(calls "$h/stubs/send.calls" home=)" "a fourth resend ran"
  assert_present "$h/state/resil/cards/send-$corr.card" "no card after the last try"
  assert_contains "$(cat "$h/state/.resil.log")" "task=rsm cause=send-unknown action=resend-1" "the first resend was not logged"
  pass "an unconfirmed steer is replayed at 1, 4 and 15 minutes, then one card"
}

test_resend_ends_on_delivery_and_passes_the_state_override() {
  local h corr=fedcba9876543210
  h=$(make_home resend-ok)
  pending "$h" "$corr" escalated
  save_resend "$h" "$corr" "$h/alt-state" rsm "hello"
  echo 0 > "$h/stubs/send.rc"
  resil "$h" $((T0 + 61)) resend >/dev/null
  assert_contains "$(cat "$h/stubs/send.calls")" "state=$h/alt-state" "the state override was not passed to the resend"
  assert_absent "$h/state/resil/resend/$corr.args" "a delivered resend kept its saved arguments"
  assert_contains "$(cat "$h/state/.resil.log")" "outcome=delivered" "the delivery was not logged"
  # a record the watcher found delivered ends the loop without a send
  corr=00112233445566ff
  pending "$h" "$corr" awaiting_report 1799999999
  save_resend "$h" "$corr" "" rsm "again"
  resil "$h" $((T0 + 100000)) resend >/dev/null
  assert_equals 1 "$(calls "$h/stubs/send.calls" home=)" "a delivered record was resent"
  assert_absent "$h/state/resil/resend/$corr.args" "a delivered record kept its saved arguments"
  pass "a delivered steer ends the loop and a state override is honored"
}

# --- relaunch -----------------------------------------------------------------

lane() {  # <home> <id> <kind> <status-line>
  local h=$1 id=$2 kind=$3
  fm_write_meta "$h/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$h/wt-$id" \
    "project=$h/proj" "harness=claude" "kind=$kind" "mode=local-only" "yolo=off"
  mkdir -p "$h/wt-$id"
  printf '%s\n' "$4" > "$h/state/$id.status"
}

DEAD="state: unknown · source: none · backend target gone: firstmate:fm-x (agent gone, pane shell remains)"

test_stopped_worker_is_relaunched_four_times_then_one_card() {
  local h
  h=$(make_home relaunch)
  lane "$h" w1 ship "working [at=$T0]: reading the sources"
  echo "$DEAD" > "$h/stubs/crew.w1"
  resil "$h" "$T0" relaunch >/dev/null
  assert_present "$h/state/resil/stopped/w1" "a worker with no agent was not noticed"
  resil "$h" $((T0 + 719)) relaunch >/dev/null
  [ ! -e "$h/stubs/control.calls" ] || fail "a worker was relaunched before it was stopped for twelve minutes"
  resil "$h" $((T0 + 721)) relaunch >/dev/null
  assert_equals 1 "$(calls "$h/stubs/control.calls" 'w1 relaunch --note')" "the first relaunch did not use the normal control path"
  assert_contains "$(cat "$h/stubs/control.calls")" "Automatic relaunch 1 of 4" "the relaunch note does not say why"
  resil "$h" $((T0 + 721 + 239)) relaunch >/dev/null
  assert_equals 1 "$(calls "$h/stubs/control.calls" w1)" "the second relaunch came before four minutes"
  resil "$h" $((T0 + 721 + 241)) relaunch >/dev/null
  resil "$h" $((T0 + 721 + 241 + 481)) relaunch >/dev/null
  resil "$h" $((T0 + 721 + 241 + 481 + 961)) relaunch >/dev/null
  assert_equals 4 "$(calls "$h/stubs/control.calls" w1)" "four relaunches were expected"
  resil "$h" $((T0 + 721 + 241 + 481 + 961 + 500)) relaunch >/dev/null
  assert_equals 4 "$(calls "$h/stubs/control.calls" w1)" "a fifth relaunch ran"
  assert_absent "$h/state/resil/cards/stopped-w1.card" "the card came before the last wait passed"
  resil "$h" $((T0 + 721 + 241 + 481 + 961 + 961)) relaunch >/dev/null
  assert_equals 4 "$(calls "$h/stubs/control.calls" w1)" "a fifth relaunch ran at the card"
  assert_present "$h/state/resil/cards/stopped-w1.card" "no card after four relaunches"
  assert_contains "$(cat "$h/state/.resil.log")" "task=w1 cause=stopped-agent-gone action=relaunch-1 outcome=ok" "the relaunch was not logged"
  assert_absent "$h/state/w1.status.bak" "unexpected file"
  pass "a stopped worker is relaunched at 2, 4, 8 and 16 minutes, then one card"
}

test_refused_relaunch_counts_and_is_logged() {
  local h
  h=$(make_home relaunch-refused)
  lane "$h" w2 scout "working [at=$T0]: x"
  echo "$DEAD" > "$h/stubs/crew.w2"
  echo 1 > "$h/stubs/control.rc"
  resil "$h" "$T0" relaunch >/dev/null
  resil "$h" $((T0 + 721)) relaunch >/dev/null
  assert_contains "$(cat "$h/state/.resil.log")" "action=relaunch-1 outcome=rc=1" "a refused relaunch was not logged with its status"
  assert_equals 1 "$(sed -n 's/^attempts=//p' "$h/state/resil/stopped/w2")" "a refused relaunch was not counted"
  pass "a refused relaunch is counted and logged, never repeated blindly"
}

test_api_error_stop_counts_from_the_error() {
  local h
  h=$(make_home relaunch-api)
  lane "$h" w3 ship "working [at=$T0]: x"
  echo "state: working · source: status-log · working" > "$h/stubs/crew.w3"
  echo $((T0 - 900)) > "$h/stubs/apierr.wt-w3"
  resil "$h" "$T0" relaunch >/dev/null
  assert_equals 1 "$(calls "$h/stubs/control.calls" 'w3 relaunch')" "a worker whose session ended in an API error 15 minutes ago was not relaunched"
  assert_contains "$(cat "$h/state/.resil.log")" "cause=stopped-api-error" "the cause was not logged"
  pass "an API-error stop counts from the error, not from the first look"
}

test_lanes_that_must_not_be_relaunched() {
  local h id
  h=$(make_home relaunch-skip)
  lane "$h" busy ship "working [at=$T0]: x"; echo "state: working · source: pane · harness busy (spinner)" > "$h/stubs/crew.busy"
  lane "$h" piped ship "working [at=$T0]: x"; echo "state: working · source: run-step · pipeline running" > "$h/stubs/crew.piped"
  lane "$h" fin ship "done [at=$T0]: ready"; echo "$DEAD" > "$h/stubs/crew.fin"
  lane "$h" par ship "paused [at=$T0]: waiting for ci"; echo "$DEAD" > "$h/stubs/crew.par"
  lane "$h" ask ship "needs-decision [at=$T0]: pick"; echo "$DEAD" > "$h/stubs/crew.ask"
  lane "$h" blk ship "blocked [at=$T0]: stuck"; echo "$DEAD" > "$h/stubs/crew.blk"
  lane "$h" sm secondmate "working [at=$T0]: idle"; echo "$DEAD" > "$h/stubs/crew.sm"
  lane "$h" idle ship "working [at=$T0]: thinking"; echo "state: working · source: status-log · working" > "$h/stubs/crew.idle"
  resil "$h" "$T0" relaunch >/dev/null
  resil "$h" $((T0 + 100000)) relaunch >/dev/null
  [ ! -e "$h/stubs/control.calls" ] || fail "a lane that must be left alone was relaunched: $(cat "$h/stubs/control.calls")"
  for id in busy piped fin par ask blk sm idle; do
    assert_absent "$h/state/resil/stopped/$id" "$id was treated as stopped"
  done
  lane "$h" held ship "working [at=$T0]: x"; echo "$DEAD" > "$h/stubs/crew.held"
  printf 'reason=test\n' > "$h/state/HOLD"
  resil "$h" "$T0" relaunch >/dev/null
  resil "$h" $((T0 + 100000)) relaunch >/dev/null
  [ ! -e "$h/stubs/control.calls" ] || fail "a worker was relaunched while state/HOLD was in force"
  pass "busy, pipeline-owned, finished, waiting, decision-holding, secondmate, merely idle lanes and a HOLD are left alone"
}

test_a_quiet_half_hour_starts_over() {
  local h
  h=$(make_home relaunch-recover)
  lane "$h" w4 ship "working [at=$T0]: x"
  echo "$DEAD" > "$h/stubs/crew.w4"
  resil "$h" "$T0" relaunch >/dev/null
  resil "$h" $((T0 + 721)) relaunch >/dev/null
  echo "state: working · source: pane · harness busy (spinner)" > "$h/stubs/crew.w4"
  resil "$h" $((T0 + 800)) relaunch >/dev/null
  assert_present "$h/state/resil/stopped/w4" "the record vanished at the first healthy look"
  resil "$h" $((T0 + 800 + 1801)) relaunch >/dev/null
  assert_absent "$h/state/resil/stopped/w4" "a worker working again for half an hour kept its relaunch count"
  assert_contains "$(cat "$h/state/.resil.log")" "action=recovered" "the recovery was not logged"
  pass "a worker seen working for half an hour starts its count over"
}

test_resend_replays_the_printed_command_on_schedule
test_resend_ends_on_delivery_and_passes_the_state_override
test_stopped_worker_is_relaunched_four_times_then_one_card
test_refused_relaunch_counts_and_is_logged
test_api_error_stop_counts_from_the_error
test_lanes_that_must_not_be_relaunched
test_a_quiet_half_hour_starts_over
