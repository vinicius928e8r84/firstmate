#!/usr/bin/env bash
# Behavior tests for bin/fm-stall-guard.sh, the front-stall guard.
#
# Covers the three stalls (coordinator with open work and no status for 2 h,
# risk-ALTA item with no live session for 1 h, watcher down), the idempotence
# contract (one warning per stall, silence when movement returns, a new stall
# alarms again), the silence when everything moves, the durable wake from
# `scan`, and arm/disarm. Time is driven by FM_STALL_NOW; agent liveness by
# FM_STALL_AGENT_CMD. No case touches a real endpoint, project, or process.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-stall-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-stall-guard)
T0=1800000000
AGENT_FILE="$TMP_ROOT/agent-state"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$AGENT_FILE" > "$TMP_ROOT/agent-cmd"
chmod +x "$TMP_ROOT/agent-cmd"

# make_home <name>: scratch home with a live-looking watcher (this shell's pid).
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state/.watch.lock" "$home/data" "$home/mate/data"
  printf '%s\n' $$ > "$home/state/.watch.lock/pid"
  touch -d "@$T0" "$home/state/.last-watcher-beat"
  printf '## In flight\n\n## Queued\n' > "$home/data/backlog.md"
  printf '## In flight\n\n## Queued\n' > "$home/mate/data/backlog.md"
  printf '%s\n' "$home"
}

# guard <home> <now> <mode>
guard() {
  local home=$1 now=$2 mode=${3:-check}
  FM_HOME="$home" FM_STALL_NOW="$now" FM_STALL_AGENT_CMD="$TMP_ROOT/agent-cmd" \
    "$GUARD" "$mode" 2>&1
}

beat() { touch -d "@$2" "$1/state/.last-watcher-beat"; }

add_mate() {  # <home> <id> <open-items> <status-epoch>
  local home=$1 id=$2 n=$3 at=$4 i
  printf 'kind=secondmate\nhome=%s/mate\nbackend=herdr\nwindow=s:p1\n' "$home" > "$home/state/$id.meta"
  { printf '## In flight\n'; for ((i = 0; i < n; i++)); do printf -- '- [ ] w%s - work\n' "$i"; done; printf '\n## Queued\n'; } > "$home/mate/data/backlog.md"
  printf 'done [at=%s]: routed reply\n' "$at" > "$home/state/$id.status"
}

add_alta() {  # <home> <id> <status-line>
  local home=$1 id=$2
  printf '## In flight\n- [ ] %s - prova real (risco ALTA) (repo: x)\n\n## Queued\n' "$id" > "$home/data/backlog.md"
  printf 'kind=ship\nbackend=herdr\nwindow=s:p2\n' > "$home/state/$id.meta"
  printf '%s\n' "$3" > "$home/state/$id.status"
}

test_help_and_usage() {
  local out rc=0
  out=$("$GUARD" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help exits 0"
  assert_contains "$out" "Reasons" "--help documents the reasons"
  assert_contains "$out" "Undo:" "--help documents the undo"
  rc=0; out=$("$GUARD" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action exits 2"
  pass "fm-stall-guard: help and usage"
}

test_quiet_when_everything_moves() {
  local home out
  home=$(make_home quiet)
  add_mate "$home" mate1 2 $((T0 + 7200 - 600))
  add_alta "$home" shipx "working [at=$T0]: moving"
  echo alive > "$AGENT_FILE"
  beat "$home" $((T0 + 7200 - 30))
  out=$(guard "$home" $((T0 + 7200)))
  assert_equals "" "$out" "a moving fleet prints nothing"
  assert_equals "stall-guard: no stalls" "$(guard "$home" $((T0 + 7200)) status)" "status reports no stalls"
  pass "fm-stall-guard: silent when there is movement"
}

test_idle_coordinator_without_open_work_is_not_a_stall() {
  local home out
  home=$(make_home idlemate)
  add_mate "$home" mate1 0 "$T0"
  beat "$home" $((T0 + 90000))
  out=$(guard "$home" $((T0 + 90000)))
  assert_equals "" "$out" "an idle coordinator with no open work stays silent"
  pass "fm-stall-guard: idle coordinator is healthy"
}

test_coordinator_stall_alarms_once_and_clears_on_movement() {
  local home out
  home=$(make_home coord)
  add_mate "$home" mate1 2 "$T0"
  beat "$home" $((T0 + 7100)); out=$(guard "$home" $((T0 + 7100)))
  assert_equals "" "$out" "just under 2 h stays silent"
  beat "$home" $((T0 + 7300)); out=$(guard "$home" $((T0 + 7300)))
  assert_contains "$out" "coord mate1" "over 2 h names the reason and id"
  assert_contains "$out" "no status for 2h01m" "evidence carries the age"
  assert_contains "$out" "2 open items" "evidence carries the open work"
  beat "$home" $((T0 + 7600)); out=$(guard "$home" $((T0 + 7600)))
  assert_equals "" "$out" "the next pass does not repeat the warning"
  assert_contains "$(guard "$home" $((T0 + 7600)) status)" "already alarmed" "status still shows it as alarmed"
  # movement returns: a new status line
  printf 'working [at=%s]: back\n' $((T0 + 7700)) >> "$home/state/mate1.status"
  beat "$home" $((T0 + 7800)); out=$(guard "$home" $((T0 + 7800)))
  assert_equals "" "$out" "movement keeps it quiet"
  assert_absent "$home/state/.stall-guard/coord__mate1" "the record is cleared when movement returns"
  # a later new stall alarms again
  beat "$home" $((T0 + 7700 + 7300)); out=$(guard "$home" $((T0 + 7700 + 7300)))
  assert_contains "$out" "coord mate1" "a new stall alarms again"
  pass "fm-stall-guard: coordinator stall: one warning, silence on movement, re-alarm on a new stall"
}

test_alta_without_session_needs_an_hour_then_alarms_once() {
  local home out
  home=$(make_home alta)
  add_alta "$home" shipx "working [at=$T0]: x"
  echo dead > "$AGENT_FILE"
  beat "$home" "$T0"; out=$(guard "$home" "$T0")
  assert_equals "" "$out" "first sight of a dead session starts the clock, no alarm"
  beat "$home" $((T0 + 3500)); out=$(guard "$home" $((T0 + 3500)))
  assert_equals "" "$out" "under 1 h stays silent"
  beat "$home" $((T0 + 3700)); out=$(guard "$home" $((T0 + 3700)))
  assert_contains "$out" "alta shipx" "over 1 h alarms with the id"
  assert_contains "$out" "no live agent (dead on herdr s:p2)" "evidence names the endpoint state"
  beat "$home" $((T0 + 4000)); out=$(guard "$home" $((T0 + 4000)))
  assert_equals "" "$out" "no repeat"
  echo alive > "$AGENT_FILE"
  beat "$home" $((T0 + 4300)); out=$(guard "$home" $((T0 + 4300)))
  assert_equals "" "$out" "a live session keeps it quiet"
  assert_absent "$home/state/.stall-guard/alta__shipx" "the record is cleared when the session returns"
  pass "fm-stall-guard: ALTA item without a session: 1 h, one warning, cleared on return"
}

test_alta_ignores_unproven_done_and_non_alta() {
  local home out
  home=$(make_home altaquiet)
  add_alta "$home" shipx "working [at=$T0]: x"
  echo unreadable > "$AGENT_FILE"
  beat "$home" "$T0"; guard "$home" "$T0" >/dev/null
  beat "$home" $((T0 + 9000)); out=$(guard "$home" $((T0 + 9000)))
  assert_equals "" "$out" "an unreadable probe is not proof of death"
  echo dead > "$AGENT_FILE"
  printf 'done [at=%s]: ready\n' "$T0" > "$home/state/shipx.status"
  beat "$home" "$T0"; guard "$home" "$T0" >/dev/null
  beat "$home" $((T0 + 9000)); out=$(guard "$home" $((T0 + 9000)))
  assert_equals "" "$out" "a done item needs no session"
  printf '## In flight\n- [ ] shipx - plain item (repo: x)\n\n## Queued\n' > "$home/data/backlog.md"
  printf 'working [at=%s]: x\n' "$T0" > "$home/state/shipx.status"
  beat "$home" "$T0"; guard "$home" "$T0" >/dev/null
  beat "$home" $((T0 + 9000)); out=$(guard "$home" $((T0 + 9000)))
  assert_equals "" "$out" "a non-ALTA item is not this guard's concern"
  pass "fm-stall-guard: unproven, done, and non-ALTA items stay quiet"
}

test_alta_via_meta_risk_without_meta_session_record() {
  local home out
  home=$(make_home altameta)
  printf 'kind=ship\nbackend=herdr\nwindow=s:p3\nrisk=alta\n' > "$home/state/shipm.meta"
  echo missing > "$AGENT_FILE"
  beat "$home" "$T0"; guard "$home" "$T0" >/dev/null
  beat "$home" $((T0 + 3700)); out=$(guard "$home" $((T0 + 3700)))
  assert_contains "$out" "alta shipm" "meta risk=alta marks the item"
  pass "fm-stall-guard: risk=alta in meta is honored"
}

test_watcher_down_alarms_once_and_clears() {
  local home out
  home=$(make_home watcher)
  printf '99999999\n' > "$home/state/.watch.lock/pid"
  beat "$home" "$T0"
  out=$(guard "$home" $((T0 + 300)))
  assert_equals "" "$out" "a short gap (hand-off) does not alarm"
  out=$(guard "$home" $((T0 + 700)))
  assert_contains "$out" "watcher watcher" "a dead watcher alarms"
  assert_contains "$out" "pid 99999999 is gone" "evidence names the dead holder"
  out=$(guard "$home" $((T0 + 900)))
  assert_equals "" "$out" "no repeat"
  printf '%s\n' $$ > "$home/state/.watch.lock/pid"; beat "$home" $((T0 + 950))
  out=$(guard "$home" $((T0 + 1000)))
  assert_equals "" "$out" "a beating watcher keeps it quiet"
  assert_absent "$home/state/.stall-guard/watcher__watcher" "record cleared on recovery"
  # alive pid but stale beacon
  out=$(guard "$home" $((T0 + 950 + 1000)))
  assert_contains "$out" "beacon is stale" "a live holder with a stale beacon alarms"
  # a held fleet is quiet
  : > "$home/state/HOLD"
  rm -rf "$home/state/.stall-guard"
  out=$(guard "$home" $((T0 + 99999)))
  assert_equals "" "$out" "a held fleet is expected to be quiet"
  pass "fm-stall-guard: watcher down: debounced, one warning, cleared on recovery"
}

test_scan_queues_one_durable_wake_per_stall() {
  local home out rows
  home=$(make_home scan)
  add_mate "$home" mate1 1 "$T0"
  beat "$home" $((T0 + 8000))
  out=$(guard "$home" $((T0 + 8000)) scan)
  assert_contains "$out" "coord mate1" "scan prints the line"
  rows=$(grep -c "stall:coord:mate1" "$home/state/.wake-queue" 2>/dev/null || true)
  assert_equals "1" "$rows" "scan queued one wake row"
  assert_contains "$(cat "$home/state/.wake-queue")" "check: stall-guard: coord mate1" "the wake carries id and evidence"
  guard "$home" $((T0 + 8300)) scan >/dev/null
  rows=$(grep -c "stall:coord:mate1" "$home/state/.wake-queue" 2>/dev/null || true)
  assert_equals "1" "$rows" "a second scan does not queue again"
  pass "fm-stall-guard: scan queues one durable wake per stall"
}

test_arm_registers_and_disarm_removes() {
  local home out
  home=$(make_home arm)
  out=$(FM_HOME="$home" "$GUARD" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/stall-guard.check.sh" "arm names the shim"
  assert_present "$home/state/stall-guard.check-trust" "arm binds the shim"
  assert_contains "$(cat "$home/state/stall-guard.check.sh")" "fm-stall-guard.sh" "shim runs the guard"
  FM_HOME="$home" "$GUARD" arm >/dev/null 2>&1 || fail "re-arm must succeed"
  out=$(FM_HOME="$home" "$GUARD" disarm 2>&1) || fail "disarm must succeed"
  assert_absent "$home/state/stall-guard.check.sh" "disarm removes the shim"
  assert_absent "$home/state/stall-guard.check-trust" "disarm removes the trust"
  pass "fm-stall-guard: arm registers, disarm removes"
}

test_help_and_usage
test_quiet_when_everything_moves
test_idle_coordinator_without_open_work_is_not_a_stall
test_coordinator_stall_alarms_once_and_clears_on_movement
test_alta_without_session_needs_an_hour_then_alarms_once
test_alta_ignores_unproven_done_and_non_alta
test_alta_via_meta_risk_without_meta_session_record
test_watcher_down_alarms_once_and_clears
test_scan_queues_one_durable_wake_per_stall
test_arm_registers_and_disarm_removes
