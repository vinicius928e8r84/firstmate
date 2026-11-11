#!/usr/bin/env bash
# Behavioral coverage for bin/fm-heavy-slot.sh: a heavy job takes one of the
# machine's slots (heavy-slots in config/lane-capacity, default 1) and a second
# one waits or is deferred with 75 instead of running beside it, the slot frees
# when the job ends, is killed, or is signalled, a daemon the job leaves behind
# cannot keep the slot, the waiting job proceeds when the slot frees, status
# names the holder, and a host without flock runs the job unguarded.
# The single-quoted sh -c bodies expand in the child shell on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-heavy-slot)
SLOT="$ROOT/bin/fm-heavy-slot.sh"
export FM_HEAVY_SLOT_DIR="$TMP_ROOT/slots"
export FM_HEAVY_SLOT_POLL=1
unset FM_HEAVY_SLOTS FM_TASK_ID

make_home() {  # <name> [lane-capacity-body]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  [ -z "${2:-}" ] || printf '%b' "$2" > "$home/config/lane-capacity"
  printf '%s\n' "$home"
}

slot() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$SLOT" "$@"
}

wait_for_file() {  # <path>: up to 10 s
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ] || fail "timed out waiting for $1"
}

test_runs_the_command_and_keeps_its_status_and_input() {
  local home out rc=0
  home=$(make_home basic)
  out=$(printf 'from stdin\n' | slot "$home" run -- cat 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "a job in a free slot"
  assert_equals 'from stdin' "$out" "the job must read the caller's stdin and write its stdout"
  rc=0
  slot "$home" run -- sh -c 'exit 7' 2>/dev/null || rc=$?
  expect_code 7 "$rc" "the job's own exit status"
  assert_contains "$(slot "$home" status)" 'slot 1: free' "the slot must be free once the job ended"
  pass "a job runs in a free slot with its own stdin, stdout, and exit status, and frees the slot"
}

test_second_job_is_deferred_while_the_slot_is_held() {
  local home rc=0 out
  home=$(make_home single)
  FM_HOME="$home" "$SLOT" run --label first-suite -- sh -c ': > "$1"; sleep 30' sh "$TMP_ROOT/single.up" 2>/dev/null &
  HOLDER=$!
  wait_for_file "$TMP_ROOT/single.up"
  assert_contains "$(slot "$home" status)" 'slot 1: held by first-suite' "status must name the holder"
  out=$(slot "$home" run --wait 0 -- touch "$TMP_ROOT/single.ran" 2>&1) || rc=$?
  expect_code 75 "$rc" "a second job with every slot held: $out"
  assert_contains "$out" 'deferred: all 1 heavy slot(s)' "the deferral must say why"
  assert_absent "$TMP_ROOT/single.ran" "a deferred job must not run"
  kill "$HOLDER" 2>/dev/null
  wait "$HOLDER" 2>/dev/null
  rc=0
  slot "$home" run --wait 0 -- touch "$TMP_ROOT/single.ran" 2>/dev/null || rc=$?
  expect_code 0 "$rc" "a job once the holder was signalled"
  assert_present "$TMP_ROOT/single.ran" "the job must run once the slot freed"
  pass "with one slot a second heavy job is deferred with 75 without running, and a signalled holder frees the slot"
}

test_heavy_slots_in_config_sets_the_machine_count() {
  local home rc=0 pids='' i
  home=$(make_home two "14\nheavy-slots 2\n")
  for i in 1 2; do
    FM_HOME="$home" "$SLOT" run -- sh -c ': > "$1"; sleep 30' sh "$TMP_ROOT/two.up$i" 2>/dev/null &
    pids="$pids $!"
    wait_for_file "$TMP_ROOT/two.up$i"
  done
  slot "$home" run --wait 0 -- touch "$TMP_ROOT/two.third" 2>/dev/null || rc=$?
  expect_code 75 "$rc" "a third job against two slots"
  assert_absent "$TMP_ROOT/two.third" "the third job must not run"
  assert_equals 2 "$(slot "$home" status | grep -c 'held by')" "status must show both slots held"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null
  # shellcheck disable=SC2086
  wait $pids 2>/dev/null
  pass "heavy-slots 2 admits two heavy jobs at once and defers the third"
}

test_slot_count_is_the_root_homes_for_every_secondmate_home() {
  local root mate pids rc=0
  root=$(make_home rootmachine "14\nheavy-slots 2\n")
  mate=$(make_home mate "14\n")
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$mate/.fm-secondmate-parent"
  FM_HOME="$mate" "$SLOT" run --wait 5 -- sh -c ': > "$1"; sleep 30' sh "$TMP_ROOT/mate.up1" 2>/dev/null &
  pids=$!
  wait_for_file "$TMP_ROOT/mate.up1"
  FM_HOME="$mate" "$SLOT" run --wait 5 -- sh -c ': > "$1"; sleep 30' sh "$TMP_ROOT/mate.up2" 2>/dev/null &
  pids="$pids $!"
  wait_for_file "$TMP_ROOT/mate.up2"
  slot "$mate" run --wait 0 -- true 2>/dev/null || rc=$?
  expect_code 75 "$rc" "a third job from a secondmate home against the root home's two slots"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null
  # shellcheck disable=SC2086
  wait $pids 2>/dev/null
  pass "a secondmate home uses the root home's slot count, so one machine has one count"
}

test_a_waiting_job_proceeds_when_the_slot_frees() {
  local home rc=0
  home=$(make_home waiter)
  FM_HOME="$home" "$SLOT" run -- sleep 2 2>/dev/null &
  HOLDER=$!
  sleep 0.5
  slot "$home" run --wait 20 -- touch "$TMP_ROOT/waiter.ran" 2>/dev/null || rc=$?
  expect_code 0 "$rc" "a waiting job"
  assert_present "$TMP_ROOT/waiter.ran" "the waiting job must run after the holder ended"
  wait "$HOLDER" 2>/dev/null
  pass "a job that waits for the slot runs as soon as the holder ends"
}

test_jobs_never_overlap_in_one_slot() {
  local home log pids='' i
  home=$(make_home serial)
  log="$TMP_ROOT/serial.log"
  : > "$log"
  for i in 1 2 3; do
    FM_HOME="$home" "$SLOT" run --wait 60 -- sh -c 'echo "start $1" >> "$2"; sleep 1; echo "end $1" >> "$2"' sh "$i" "$log" 2>/dev/null &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086
  wait $pids
  assert_equals 6 "$(wc -l < "$log" | tr -d ' ')" "all three jobs must run"
  assert_equals 'start end start end start end' "$(awk '{print $1}' "$log" | tr '\n' ' ' | sed 's/ $//')" "start and end lines must alternate: no two jobs overlapped"
  pass "three simultaneous jobs on one slot run strictly one after another"
}

test_a_killed_holder_or_a_left_daemon_cannot_keep_the_slot() {
  local home holder rc=0 daemon
  home=$(make_home crash)
  FM_HOME="$home" "$SLOT" run -- sh -c 'echo $$ > "$1"; exec sleep 60' sh "$TMP_ROOT/crash.pid" 2>/dev/null &
  holder=$!
  wait_for_file "$TMP_ROOT/crash.pid"
  daemon=$(cat "$TMP_ROOT/crash.pid")
  kill -KILL "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  slot "$home" run --wait 0 -- true 2>/dev/null || rc=$?
  expect_code 0 "$rc" "a job after its holder was killed with SIGKILL, while its child still runs"
  kill "$daemon" 2>/dev/null
  # A job that ends but leaves a background process must release the slot too.
  rc=0
  slot "$home" run -- sh -c 'sleep 60 & echo $! > "$1"' sh "$TMP_ROOT/crash.bg" 2>/dev/null || rc=$?
  expect_code 0 "$rc" "the job that left a daemon"
  slot "$home" run --wait 0 -- true 2>/dev/null || rc=$?
  expect_code 0 "$rc" "a job while the previous job's daemon still runs"
  kill "$(cat "$TMP_ROOT/crash.bg")" 2>/dev/null
  pass "the kernel frees the slot when the holder is killed, and a daemon left behind does not hold it"
}

test_a_terminated_runner_stops_its_job() {
  local home runner job
  home=$(make_home term)
  FM_HOME="$home" "$SLOT" run -- sh -c 'echo $$ > "$1"; exec sleep 60' sh "$TMP_ROOT/term.pid" 2>/dev/null &
  runner=$!
  wait_for_file "$TMP_ROOT/term.pid"
  job=$(cat "$TMP_ROOT/term.pid")
  kill -TERM "$runner" 2>/dev/null
  wait "$runner" 2>/dev/null
  kill -0 "$job" 2>/dev/null && { kill "$job" 2>/dev/null; fail "SIGTERM to the runner left its job running"; }
  assert_contains "$(slot "$home" status)" 'slot 1: free' "the slot must be free after the runner was terminated"
  pass "terminating the runner stops its job and frees the slot"
}

test_unreadable_config_runs_with_one_slot_and_says_so() {
  local home out rc=0
  home=$(make_home badcfg "14\nheavy-slots many\n")
  out=$(slot "$home" run -- echo ran 2>&1) || rc=$?
  expect_code 0 "$rc" "a job under an invalid config: $out"
  assert_contains "$out" 'is unreadable; using 1 heavy slot' "an invalid config must be reported"
  assert_contains "$out" 'ran' "the job must still run"
  pass "an invalid config/lane-capacity runs the job on one slot and says so"
}

test_without_flock_the_job_runs_unguarded() {
  local home path tool out rc=0
  home=$(make_home noflock)
  # Only the tools the runner itself needs, so a host flock cannot leak in.
  path=$(fm_fakebin "$TMP_ROOT/noflock-bin")
  for tool in id dirname date sed tr cut head; do
    ln -s "$(command -v "$tool")" "$path/$tool" 2>/dev/null || true
  done
  out=$(PATH="$path" FM_HOME="$home" "$BASH" "$SLOT" run -- dirname /ran/here 2>&1) || rc=$?
  expect_code 0 "$rc" "a job on a host without flock: $out"
  assert_contains "$out" 'flock is not installed; running without a slot' "the missing tool must be reported"
  assert_contains "$out" '/ran' "the job must still run"
  pass "a host without flock runs the job at once and says so"
}

test_usage_errors() {
  local home rc=0
  home=$(make_home usage)
  slot "$home" run >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "run with no command"
  rc=0
  slot "$home" run --wait soon -- true >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a non-numeric --wait"
  rc=0
  slot "$home" bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown subcommand"
  pass "a malformed command line is a usage error"
}

fm_test_run \
  test_runs_the_command_and_keeps_its_status_and_input \
  test_second_job_is_deferred_while_the_slot_is_held \
  test_heavy_slots_in_config_sets_the_machine_count \
  test_slot_count_is_the_root_homes_for_every_secondmate_home \
  test_a_waiting_job_proceeds_when_the_slot_frees \
  test_jobs_never_overlap_in_one_slot \
  test_a_killed_holder_or_a_left_daemon_cannot_keep_the_slot \
  test_a_terminated_runner_stops_its_job \
  test_unreadable_config_runs_with_one_slot_and_says_so \
  test_without_flock_the_job_runs_unguarded \
  test_usage_errors
