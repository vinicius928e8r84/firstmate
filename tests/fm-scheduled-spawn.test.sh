#!/usr/bin/env bash
# Behavior tests for bin/fm-scheduled-spawn.sh: a scheduled loop's spawn is retried with backoff and alerts after the
# final failure, a transient failure stays quiet, a later success clears the alert, and a wrapper's load refusal is
# re-queued (never lost), retried by the tick only once the load allows, and alerted when the UTC day ends without a
# run. A fake spawn binary, a fake clock (FM_SCHEDULED_NOW), a fake load (FM_SCHEDULED_LOAD1) and a fake asks tool
# stand in for the host; the real bin/fm-lane-guard.sh raises and clears the alerts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCHED="$ROOT/bin/fm-scheduled-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-scheduled-spawn)
LOAD_EXIT=79

# A home with a fake asks tool that logs every call, a fake spawn that exits per a script file, and a fake wrapper.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data/tools" "$home/bin"
  cat > "$home/data/tools/fm-asks.sh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FM_HOME/asks.calls"
SH
  # exits with the first line of $FM_HOME/spawn.script (popped); 0 when the script is empty; logs every argv.
  cat > "$home/bin/fake-spawn" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FM_HOME/spawn.calls"
echo "helper=${FM_SCHEDULED_SPAWN_HELPER:-}" >> "$FM_HOME/spawn.env"
rc=$(head -1 "$FM_HOME/spawn.script" 2>/dev/null); [ -n "$rc" ] || rc=0
sed -i 1d "$FM_HOME/spawn.script" 2>/dev/null
exit "$rc"
SH
  # a wrapper: exits per $FM_HOME/wrap.script; a 79 line carries the load contract line.
  cat > "$home/bin/fake-wrapper" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FM_HOME/wrap.calls"
rc=$(head -1 "$FM_HOME/wrap.script" 2>/dev/null); [ -n "$rc" ] || rc=0
sed -i 1d "$FM_HOME/wrap.script" 2>/dev/null
[ "$rc" != 79 ] || echo "scheduled-load-refused load1=12.5 max=8"
exit "$rc"
SH
  chmod +x "$home/data/tools/fm-asks.sh" "$home/bin/fake-spawn" "$home/bin/fake-wrapper"
  : > "$home/spawn.script"
  : > "$home/wrap.script"
  printf '%s\n' "$home"
}

sched() {  # <home> <args...>: the helper against that home, with a fast backoff and a fake spawn
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SW_NO_NOTIFY=1 HOME="$home" \
    FM_SCHEDULED_SPAWN_BIN="$home/bin/fake-spawn" FM_SCHEDULED_SPAWN_BACKOFF_SEC=0 \
    "$SCHED" "$@" 2>&1
}

calls() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
last() { sed -n "s/^$3=//p" "$1/state/scheduled-loops/$2.last" | head -1; }
alert_count() { if [ -f "$1/state/.lane-guard-alerts" ]; then wc -l < "$1/state/.lane-guard-alerts" | tr -d ' '; else echo 0; fi; }

test_transient_failure_retries_quietly() {
  local home out rc=0
  home=$(make_home transient)
  printf '%s\n' 75 76 > "$home/spawn.script"
  out=$(sched "$home" daily-audit audit-1 /proj --scout) || rc=$?
  expect_code 0 "$rc" "a transient refusal was not retried to success: $out"
  assert_equals 3 "$(calls "$home/spawn.calls")" "the spawn was not tried three times"
  assert_contains "$(head -1 "$home/spawn.calls")" "audit-1 /proj --scout --scheduled-loop daily-audit" \
    "the spawn did not receive the scheduled-loop identity"
  assert_equals "helper=1" "$(head -1 "$home/spawn.env")" "the spawn was not told its helper owns the failure alert"
  assert_equals "ok|3|0" "$(last "$home" daily-audit result)|$(last "$home" daily-audit attempts)|$(last "$home" daily-audit exit)" \
    "the durable record did not show the successful third attempt"
  assert_equals 0 "$(alert_count "$home")" "a transient refusal raised an alert"
  assert_absent "$home/state/scheduled-loops/daily-audit.pending" "a successful run left a pending record"
  pass "a transient refusal is retried and succeeds without an alert"
}

test_persistent_failure_alerts_and_a_later_success_clears() {
  local home out rc=0
  home=$(make_home persistent)
  printf '%s\n' 75 75 75 > "$home/spawn.script"
  out=$(sched "$home" daily-audit audit-1 /proj --scout) || rc=$?
  expect_code 75 "$rc" "the final refusal status was not returned: $out"
  assert_equals 3 "$(calls "$home/spawn.calls")" "the retry was not bounded to three attempts"
  assert_equals "deferred-lane|3|75" "$(last "$home" daily-audit result)|$(last "$home" daily-audit attempts)|$(last "$home" daily-audit exit)" \
    "the durable record did not show the failed run"
  assert_equals 1 "$(alert_count "$home")" "the final failure did not raise exactly one alert"
  assert_contains "$(cat "$home/state/.lane-guard-alerts")" "scheduled loop daily-audit did not start" "the alert did not name the loop"
  assert_grep "add --key lane-guard-scheduled-daily-audit" "$home/asks.calls" "the alert was not registered as a captain ask"
  assert_present "$home/state/scheduled-loops/daily-audit.pending" "the failed run was not kept for the retry tick"

  out=$(sched "$home" tick) || true
  assert_equals 4 "$(calls "$home/spawn.calls")" "the tick did not retry the failed spawn once"
  assert_absent "$home/state/scheduled-loops/daily-audit.pending" "a successful retry left its pending record"
  assert_equals ok "$(last "$home" daily-audit result)" "the retry did not record success"
  assert_grep "done lane-guard-scheduled-daily-audit" "$home/asks.calls" "a later success did not clear the alert"
  assert_equals 1 "$(alert_count "$home")" "the retry raised another alert"
  pass "a persistent failure alerts once with a durable record, is retried by the tick, and a later success clears the alert"
}

test_other_failure_codes_are_retried_too() {
  local home rc=0
  home=$(make_home codes)
  printf '%s\n' 1 76 1 > "$home/spawn.script"
  sched "$home" weekly-arch arch-1 /proj --scout >/dev/null || rc=$?
  expect_code 1 "$rc" "the last status was not passed through"
  assert_equals 3 "$(calls "$home/spawn.calls")" "an exit 1 or 76 was not retried"
  assert_equals 1 "$(alert_count "$home")" "a failure with exit 1 or 76 did not alert"
  pass "any non-zero spawn status, including 1 and 76, is retried and then alerted"
}

test_load_refusal_is_requeued_and_run_when_the_load_drops() {
  local home out rc=0
  home=$(make_home load)
  printf '%s\n' "$LOAD_EXIT" > "$home/wrap.script"
  out=$(FM_SCHEDULED_NOW=$(date -u -d '2026-10-30 08:00:00' +%s) sched "$home" wrap weekly-retro -- "$home/bin/fake-wrapper" --apply) || rc=$?
  expect_code "$LOAD_EXIT" "$rc" "a load refusal was not reported as a deferral: $out"
  assert_equals deferred-load "$(last "$home" weekly-retro result)" "the durable record did not show the load deferral"
  assert_equals 0 "$(alert_count "$home")" "a deferral alerted before its day ended"
  assert_contains "$(cat "$home/state/scheduled-loops/weekly-retro.pending")" "max_load=8" "the wrapper's threshold was not kept"
  assert_contains "$(cat "$home/state/scheduled-loops/weekly-retro.pending")" "arg=--apply" "the wrapper's arguments were not kept"

  FM_SCHEDULED_NOW=$(date -u -d '2026-10-30 09:00:00' +%s) FM_SCHEDULED_LOAD1=12.0 sched "$home" tick >/dev/null
  assert_equals 1 "$(calls "$home/wrap.calls")" "the tick re-ran the wrapper while the load was still over its threshold"
  assert_present "$home/state/scheduled-loops/weekly-retro.pending" "a loaded tick dropped the pending run"

  FM_SCHEDULED_NOW=$(date -u -d '2026-10-30 10:00:00' +%s) FM_SCHEDULED_LOAD1=3.5 sched "$home" tick >/dev/null
  assert_equals 2 "$(calls "$home/wrap.calls")" "the tick did not re-run the wrapper once the load dropped"
  assert_absent "$home/state/scheduled-loops/weekly-retro.pending" "a run that happened left its pending record"
  assert_equals ok "$(last "$home" weekly-retro result)" "the retried run was not recorded"
  assert_equals 0 "$(alert_count "$home")" "a run the same day alerted"
  pass "a load refusal is kept pending, left alone while the load is high, and run the same day once it drops"
}

test_unrun_deferral_alerts_at_the_end_of_the_day_once() {
  local home
  home=$(make_home eod)
  printf '%s\n' "$LOAD_EXIT" > "$home/wrap.script"
  FM_SCHEDULED_NOW=$(date -u -d '2026-10-30 08:00:00' +%s) sched "$home" wrap weekly-correct -- "$home/bin/fake-wrapper" >/dev/null
  FM_SCHEDULED_NOW=$(date -u -d '2026-10-30 20:00:00' +%s) FM_SCHEDULED_LOAD1=20 sched "$home" tick >/dev/null
  assert_equals 0 "$(alert_count "$home")" "an unrun deferral alerted hours before its day ended"
  FM_SCHEDULED_NOW=$(date -u -d '2026-10-30 23:15:00' +%s) FM_SCHEDULED_LOAD1=20 sched "$home" tick >/dev/null
  assert_equals 1 "$(alert_count "$home")" "an unrun deferral did not alert at the end of its day"
  assert_contains "$(cat "$home/state/.lane-guard-alerts")" "has not run by the end of 2026-10-30 (UTC)" "the alert did not name the day"
  FM_SCHEDULED_NOW=$(date -u -d '2026-10-31 01:00:00' +%s) FM_SCHEDULED_LOAD1=20 sched "$home" tick >/dev/null
  assert_equals 1 "$(alert_count "$home")" "the end-of-day alert repeated"
  assert_present "$home/state/scheduled-loops/weekly-correct.pending" "the run was dropped at the end of the day"

  FM_SCHEDULED_NOW=$(date -u -d '2026-10-31 02:00:00' +%s) FM_SCHEDULED_LOAD1=1 sched "$home" tick >/dev/null
  assert_absent "$home/state/scheduled-loops/weekly-correct.pending" "the next day's tick did not run the still-pending loop"
  assert_grep "done lane-guard-scheduled-weekly-correct" "$home/asks.calls" "the late run did not clear the alert"
  pass "a deferral still unrun at the end of its UTC day alerts once, keeps retrying, and clears on the late run"
}

test_wrapper_failure_alerts_and_is_bounded() {
  local home
  home=$(make_home wrapfail)
  printf '%s\n' 3 3 3 3 3 3 3 3 > "$home/wrap.script"
  FM_SCHEDULED_NOW=$(date -u -d '2026-10-30 08:00:00' +%s) sched "$home" wrap monthly -- "$home/bin/fake-wrapper" >/dev/null
  assert_equals 1 "$(alert_count "$home")" "a failed wrapper did not alert"
  local i
  for i in 1 2 3 4 5 6 7 8; do
    FM_SCHEDULED_NOW=$(date -u -d "2026-10-30 0$i:30:00" +%s) FM_SCHEDULED_MAX_TRIES=3 sched "$home" tick >/dev/null
  done
  assert_equals 3 "$(calls "$home/wrap.calls")" "the retries of a failing wrapper were not bounded by FM_SCHEDULED_MAX_TRIES"
  assert_equals 1 "$(alert_count "$home")" "a repeated failure alerted again the same day"
  pass "a failing wrapper alerts, is retried by the tick a bounded number of times, and does not re-alert the same day"
}

test_queue_requeues_a_lost_run_and_stale_ones_expire() {
  local home
  home=$(make_home queue)
  FM_SCHEDULED_NOW=$(date -u -d '2026-10-30 08:00:00' +%s) sched "$home" queue weekly-retro -- "$home/bin/fake-wrapper" --apply >/dev/null
  assert_equals queued "$(last "$home" weekly-retro result)" "a hand-queued run was not recorded"
  FM_SCHEDULED_NOW=$(date -u -d '2026-10-30 09:00:00' +%s) FM_SCHEDULED_LOAD1=9 sched "$home" tick >/dev/null
  assert_equals 0 "$(calls "$home/wrap.calls")" "a queued run started while the load was over the default threshold"
  FM_SCHEDULED_NOW=$(date -u -d '2026-10-30 10:00:00' +%s) FM_SCHEDULED_LOAD1=2 sched "$home" tick >/dev/null
  assert_equals 1 "$(calls "$home/wrap.calls")" "a queued run did not start once there was room"
  assert_absent "$home/state/scheduled-loops/weekly-retro.pending" "a queued run that ran stayed pending"

  FM_SCHEDULED_NOW=$(date -u -d '2026-10-01 08:00:00' +%s) sched "$home" queue old-loop -- "$home/bin/fake-wrapper" >/dev/null
  FM_SCHEDULED_NOW=$(date -u -d '2026-10-30 10:00:00' +%s) FM_SCHEDULED_LOAD1=20 sched "$home" tick >/dev/null
  assert_absent "$home/state/scheduled-loops/old-loop.pending" "a month-old pending run was not dropped"
  assert_equals expired "$(last "$home" old-loop result)" "the dropped run was not recorded as expired"
  assert_contains "$(cat "$home/state/.lane-guard-alerts")" "scheduled loop old-loop never ran" "the dropped run did not alert"
  pass "a lost run can be queued by hand and runs when there is room, and a stale pending run is dropped with an alert"
}

test_usage_and_loop_names() {
  local home rc=0
  home=$(make_home usage)
  sched "$home" >/dev/null || rc=$?
  expect_code 64 "$rc" "no arguments were not a usage error"
  rc=0
  sched "$home" tick audit-1 >/dev/null || rc=$?
  expect_code 64 "$rc" "tick with arguments was not a usage error"
  rc=0
  sched "$home" 'bad name' audit-1 /proj >/dev/null || rc=$?
  expect_code 64 "$rc" "an invalid loop name was accepted"
  rc=0
  sched "$home" wrap daily-audit "$home/bin/fake-wrapper" >/dev/null || rc=$?
  expect_code 64 "$rc" "wrap without -- was accepted"
  assert_equals 0 "$(calls "$home/spawn.calls")" "a refused invocation reached the spawn"
  pass "usage errors and invalid loop names are refused before anything runs"
}

test_status_lists_each_loop() {
  local home out
  home=$(make_home status)
  printf '%s\n' 1 1 1 > "$home/spawn.script"
  sched "$home" daily-audit audit-1 /proj --scout >/dev/null || true
  out=$(sched "$home" status)
  assert_contains "$out" "daily-audit: failed" "status did not show the failed loop"
  assert_contains "$out" "pending=spawn-failed" "status did not show the pending retry"
  assert_contains "$out" "last_success=never" "status did not show that the loop never succeeded"
  pass "status shows each loop's last result and any pending run"
}

test_capacity_deferral_is_never_lost_and_does_not_use_up_the_tries() {
  local home i rc=0
  home=$(make_home capacity)
  printf '%s\n' 75 75 75 > "$home/spawn.script"
  FM_SCHEDULED_NOW=$(date -u -d '2026-11-09 08:00:00' +%s) sched "$home" daily-audit audit-1 /proj --scout >/dev/null || rc=$?
  expect_code 75 "$rc" "the capacity refusal status was not returned"
  assert_equals deferred-lane "$(last "$home" daily-audit result)" "a capacity refusal was recorded as a failure"
  assert_contains "$(cat "$home/state/scheduled-loops/daily-audit.pending")" "reason=lane-deferred" "the run was not kept as a capacity deferral"
  # Ten hourly ticks that all meet a full lane: a failure would stop after FM_SCHEDULED_MAX_TRIES (6), a deferral never does.
  printf '%s\n' 75 75 75 75 75 75 75 75 75 75 > "$home/spawn.script"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    FM_SCHEDULED_NOW=$(date -u -d "2026-11-09 08:00:00 + $i hour" +%s) sched "$home" tick >/dev/null
  done
  assert_equals 13 "$(calls "$home/spawn.calls")" "the tick stopped retrying a capacity deferral"
  assert_contains "$(cat "$home/state/scheduled-loops/daily-audit.pending")" "tries=0" "a capacity deferral used up a retry"
  : > "$home/spawn.script"
  FM_SCHEDULED_NOW=$(date -u -d '2026-11-09 19:00:00' +%s) sched "$home" tick >/dev/null
  assert_absent "$home/state/scheduled-loops/daily-audit.pending" "the run did not complete once the lane freed"
  assert_equals ok "$(last "$home" daily-audit result)" "the late run was not recorded"
  pass "a capacity refusal is retried every tick without using up the bounded tries, and the run lands when the lane frees"
}

test_last_success_survives_a_later_failure() {
  local home out
  home=$(make_home success)
  : > "$home/spawn.script"
  FM_SCHEDULED_NOW=$(date -u -d '2026-11-08 08:00:00' +%s) sched "$home" weekly-arch arch-1 /proj --scout >/dev/null
  assert_equals 2026-11-08T08:00:00Z "$(sed -n 's/^at_utc=//p' "$home/state/scheduled-loops/weekly-arch.success")" "the success time was not recorded"
  printf '%s\n' 1 1 1 > "$home/spawn.script"
  FM_SCHEDULED_NOW=$(date -u -d '2026-11-09 08:00:00' +%s) sched "$home" weekly-arch arch-2 /proj --scout >/dev/null || true
  assert_equals failed "$(last "$home" weekly-arch result)" "the second run did not fail"
  assert_equals 2026-11-08T08:00:00Z "$(sed -n 's/^at_utc=//p' "$home/state/scheduled-loops/weekly-arch.success")" "a failure overwrote the last success"
  out=$(sched "$home" status)
  assert_contains "$out" "last_success=2026-11-08T08:00:00Z" "status did not show the last success"
  pass "the last success is recorded per loop and a later failure does not overwrite it"
}

test_wrapper_deferral_exit_is_queued_without_using_tries() {
  local home i rc=0
  home=$(make_home wrapdefer)
  printf '%s\n' 78 > "$home/wrap.script"
  cat > "$home/bin/hold-wrapper" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FM_HOME/wrap.calls"
echo "wrapflag=${FM_SCHEDULED_WRAP:-}" >> "$FM_HOME/wrap.env"
rc=$(head -1 "$FM_HOME/wrap.script" 2>/dev/null); [ -n "$rc" ] || rc=0
sed -i 1d "$FM_HOME/wrap.script" 2>/dev/null
[ "$rc" != 78 ] || echo "scheduled-deferred reason=state/HOLD exists"
exit "$rc"
SH
  chmod +x "$home/bin/hold-wrapper"
  FM_SCHEDULED_NOW=$(date -u -d '2026-11-09 11:07:00' +%s) sched "$home" wrap weekly-retro -- "$home/bin/hold-wrapper" --apply >/dev/null || rc=$?
  expect_code 78 "$rc" "a wrapper deferral was not passed through"
  assert_equals deferred "$(last "$home" weekly-retro result)" "the durable record did not show the deferral"
  assert_contains "$(sed -n 's/^detail=//p' "$home/state/scheduled-loops/weekly-retro.last")" "state/HOLD" "the deferral reason was lost"
  assert_equals wrapflag=1 "$(head -1 "$home/wrap.env")" "the wrapper was not told it runs under the scheduler"
  printf '%s\n' 78 78 78 78 78 78 78 > "$home/wrap.script"
  for i in 1 2 3 4 5 6 7; do
    FM_SCHEDULED_NOW=$(date -u -d "2026-11-09 11:07:00 + $i hour" +%s) sched "$home" tick >/dev/null
  done
  assert_equals 8 "$(calls "$home/wrap.calls")" "the tick stopped retrying a deferred wrapper"
  : > "$home/wrap.script"
  FM_SCHEDULED_NOW=$(date -u -d '2026-11-09 20:00:00' +%s) sched "$home" tick >/dev/null
  assert_absent "$home/state/scheduled-loops/weekly-retro.pending" "the deferred wrapper never completed"
  assert_equals ok "$(last "$home" weekly-retro result)" "the late wrapper run was not recorded"
  pass "a wrapper deferral (78) is queued, retried every tick without limit, and completes when it can"
}

test_usage_limit_hold_queues_a_run_and_the_tick_waits_for_the_end() {
  local home rc=0 until_epoch
  home=$(make_home quota)
  until_epoch=$(date -u -d '2026-11-09 15:00:00' +%s)
  printf 'until=%s\nchecked=%s\n' "$until_epoch" "$until_epoch" > "$home/state/.quota-silence"
  FM_SCHEDULED_NOW=$(date -u -d '2026-11-09 08:00:00' +%s) sched "$home" daily-audit audit-1 /proj --scout >/dev/null || rc=$?
  expect_code 78 "$rc" "a run during a usage-limit hold was not deferred"
  assert_equals 0 "$(calls "$home/spawn.calls")" "a run during a usage-limit hold reached the spawn"
  assert_equals deferred-quota "$(last "$home" daily-audit result)" "the hold deferral was not recorded"
  assert_contains "$(cat "$home/state/scheduled-loops/daily-audit.pending")" "reason=quota-hold" "the run was not kept for the tick"
  FM_SCHEDULED_NOW=$(date -u -d '2026-11-09 15:03:00' +%s) sched "$home" tick >/dev/null
  assert_equals 0 "$(calls "$home/spawn.calls")" "the tick retried inside the grace after the hold ended"
  FM_SCHEDULED_NOW=$(date -u -d '2026-11-09 15:10:00' +%s) sched "$home" tick >/dev/null
  assert_equals 1 "$(calls "$home/spawn.calls")" "the tick did not retry once the hold and its grace were over"
  assert_absent "$home/state/scheduled-loops/daily-audit.pending" "the run left a pending record after it ran"
  assert_present "$home/state/scheduled-loops/daily-audit.success" "the late run recorded no success"
  pass "a usage-limit hold queues the run, and the tick starts it only after the hold plus its grace"
}

test_a_lane_started_by_the_wrapper_does_not_keep_the_loop_lock() {
  local home rc=0
  home=$(make_home lockfd)
  cat > "$home/bin/lane-wrapper" <<'SH'
#!/usr/bin/env bash
# stands in for a wrapper whose spawn leaves a long-lived lane behind
setsid -f sleep 4 </dev/null >/dev/null 2>&1
exit 0
SH
  chmod +x "$home/bin/lane-wrapper"
  sched "$home" wrap weekly-bench -- "$home/bin/lane-wrapper" >/dev/null || rc=$?
  expect_code 0 "$rc" "the first wrapper run failed"
  sched "$home" wrap weekly-bench -- "$home/bin/lane-wrapper" >/dev/null || rc=$?
  expect_code 0 "$rc" "a lane left behind by the first run kept the loop lock (exit 75)"
  pass "a lane started by a wrapper does not inherit and hold the loop lock"
}

test_transient_failure_retries_quietly
test_persistent_failure_alerts_and_a_later_success_clears
test_other_failure_codes_are_retried_too
test_load_refusal_is_requeued_and_run_when_the_load_drops
test_unrun_deferral_alerts_at_the_end_of_the_day_once
test_wrapper_failure_alerts_and_is_bounded
test_queue_requeues_a_lost_run_and_stale_ones_expire
test_usage_and_loop_names
test_status_lists_each_loop
test_capacity_deferral_is_never_lost_and_does_not_use_up_the_tries
test_last_success_survives_a_later_failure
test_wrapper_deferral_exit_is_queued_without_using_tries
test_usage_limit_hold_queues_a_run_and_the_tick_waits_for_the_end
test_a_lane_started_by_the_wrapper_does_not_keep_the_loop_lock

echo '# all fm-scheduled-spawn tests passed'
