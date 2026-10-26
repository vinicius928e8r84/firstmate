#!/usr/bin/env bash
# tests/fm-test-wait-helpers.test.sh - the exit-wait budget in tests/wake-helpers.sh.
# Budgets there are written in 0.1s ticks for an idle host. A suite that runs on a
# CPU-saturated machine sets FM_TEST_WAIT_SCALE to stretch every wait_for_exit
# budget by that factor, while the default of 1 leaves every other suite exactly
# as it was. A process that really hangs must still be stopped and reported (124).
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

test_default_budget_is_unchanged() {
  local pid rc=0 out value
  sleep 3 &
  pid=$!
  FM_TEST_WAIT_SCALE='' wait_for_exit "$pid" 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 124 ] || fail "an unscaled one-tick budget did not stop a 3s process (rc=$rc)"
  # The budget a hung process is reported against is printed, so the default is
  # pinned without depending on how fast the host runs: unset, empty, zero and
  # non-numeric scales must all leave a 5-tick budget at 5 ticks, never stretch it.
  for value in UNSET '' 0 x 1; do
    sleep 30 &
    pid=$!
    if [ "$value" = UNSET ]; then
      out=$(unset FM_TEST_WAIT_SCALE; wait_for_exit "$pid" 5 2>&1 >/dev/null)
    else
      out=$(FM_TEST_WAIT_SCALE=$value wait_for_exit "$pid" 5 2>&1 >/dev/null)
    fi
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    printf '%s' "$out" | grep -F 'exceeded 5 polls' >/dev/null \
      || fail "scale '$value' did not leave a 5-tick budget at 5 ticks: $out"
  done
  pass "without a scale the exit budget is the written tick count"
}

test_scale_stretches_the_budget() {
  local pid rc=0
  sleep 3 &
  pid=$!
  FM_TEST_WAIT_SCALE=60 wait_for_exit "$pid" 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a 60x scale did not let a 3s process finish inside a one-tick budget (rc=$rc)"
  pass "a scale stretches the exit budget so a slow exit is waited for"
}

test_scaled_budget_still_stops_a_hung_process() {
  local pid rc=0
  sleep 30 &
  pid=$!
  FM_TEST_WAIT_SCALE=4 wait_for_exit "$pid" 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 124 ] || fail "a scaled budget did not stop and report a hung process (rc=$rc)"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "the hung process survived the scaled wait"
  fi
  pass "a hung process is still stopped and reported after the scaled budget"
}

test_default_budget_is_unchanged
test_scale_stretches_the_budget
test_scaled_budget_still_stops_a_hung_process
