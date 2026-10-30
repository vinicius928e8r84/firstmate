#!/usr/bin/env bash
# Behavior tests for bin/fm-resil.sh, the resilience loops that need a clock:
#   1. an unconfirmed secondmate steer is replayed through the printed
#      correlation-reusing command at 1, 4 and 15 minutes, ends on delivery, and
#      leaves one card after the last try;
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

test_resend_replays_the_printed_command_on_schedule
test_resend_ends_on_delivery_and_passes_the_state_override
