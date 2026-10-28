#!/usr/bin/env bash
# tests/fm-memory-floor.test.sh - bin/fm-spawn.sh refuses to open a new agent
# session when the host has less than 2048 MB of available memory (captain's
# fleet rule 3; bin/fm-memory-floor-lib.sh owns the probe and the override).
#
# These drive the real fm-spawn.sh with a faked /proc/meminfo (FM_MEMINFO_OVERRIDE)
# and assert the observable contract: a distinct exit code, a clear refusal
# line, and nothing created before the refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory-floor)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_fixture() {  # <name> <MemAvailable-kB>
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/proj"
  git -C "$dir/proj" init -q
  printf 'MemTotal: 16000000 kB\nMemAvailable: %s kB\n' "$2" > "$dir/meminfo"
  printf '%s\n' "$dir"
}

# Run a spawn; the floor is whatever the environment says.
run_spawn() {  # <fixture> <env assignments...> -- <spawn args...>
  local dir=$1; shift
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env FM_HOME="$dir/home" HOME="$dir" FM_SPAWN_NO_GUARD=1 FM_MEMINFO_OVERRIDE="$dir/meminfo" "${envs[@]}" \
    "$SPAWN" "$@" > "$dir/out" 2>&1
}

test_below_two_gb_is_refused_with_a_distinct_exit_and_creates_nothing() {
  local dir status
  dir=$(make_fixture low 1500000)
  run_spawn "$dir" FM_SPAWN_MIN_FREE_MB= -- t1 "$dir/proj" --mode local-only --yolo off
  status=$?
  expect_code 76 "$status" "1464 MB available must be refused by default: $(cat "$dir/out")"
  grep -q 'spawn refused: only 1464 MB of memory is available' "$dir/out" || fail "refusal line missing the available figure: $(cat "$dir/out")"
  grep -q 'at least 2048 MB' "$dir/out" || fail "refusal line missing the 2048 MB floor: $(cat "$dir/out")"
  [ -z "$(find "$dir/home/state" "$dir/home/data" -mindepth 1)" ] || fail "a refused spawn left state behind"
  pass "fm-spawn: 1464 MB available is refused with exit 76 before anything is created"
}

test_just_at_the_floor_is_not_refused() {
  local dir status
  dir=$(make_fixture at-floor 2097152)
  run_spawn "$dir" FM_SPAWN_MIN_FREE_MB= -- t1 "$dir/proj" --mode local-only --yolo off
  status=$?
  [ "$status" -ne 76 ] || fail "exactly 2048 MB available must pass the memory floor: $(cat "$dir/out")"
  ! grep -q 'spawn refused: only' "$dir/out" || fail "the floor refused at exactly 2048 MB: $(cat "$dir/out")"
  pass "fm-spawn: 2048 MB available passes the memory floor"
}

test_override_changes_or_disables_the_floor() {
  local dir status
  dir=$(make_fixture override 1500000)
  run_spawn "$dir" FM_SPAWN_MIN_FREE_MB=0 -- t1 "$dir/proj" --mode local-only --yolo off
  status=$?
  [ "$status" -ne 76 ] || fail "FM_SPAWN_MIN_FREE_MB=0 must disable the floor: $(cat "$dir/out")"
  run_spawn "$dir" FM_SPAWN_MIN_FREE_MB=1000 -- t1 "$dir/proj" --mode local-only --yolo off
  status=$?
  [ "$status" -ne 76 ] || fail "a 1000 MB floor must admit 1464 MB: $(cat "$dir/out")"
  run_spawn "$dir" FM_SPAWN_MIN_FREE_MB=1500 -- t1 "$dir/proj" --mode local-only --yolo off
  status=$?
  expect_code 76 "$status" "a 1500 MB floor must refuse 1464 MB: $(cat "$dir/out")"
  pass "fm-spawn: FM_SPAWN_MIN_FREE_MB raises, lowers, or disables the floor"
}

test_every_launch_kind_is_refused() {
  local dir status
  dir=$(make_fixture kinds 1000000)
  run_spawn "$dir" FM_SPAWN_MIN_FREE_MB= -- t1 "$dir/proj" --scout
  status=$?
  expect_code 76 "$status" "a scout spawn must be refused: $(cat "$dir/out")"
  run_spawn "$dir" FM_SPAWN_MIN_FREE_MB= -- sm1 "$dir/proj" --secondmate
  status=$?
  expect_code 76 "$status" "a secondmate spawn must be refused: $(cat "$dir/out")"
  run_spawn "$dir" FM_SPAWN_MIN_FREE_MB= -- t1 --relaunch
  status=$?
  expect_code 76 "$status" "a relaunch must be refused: $(cat "$dir/out")"
  run_spawn "$dir" FM_SPAWN_MIN_FREE_MB= -- t1="$dir/proj" t2="$dir/proj" --mode local-only --yolo off
  status=$?
  expect_code 76 "$status" "a batch whose every pair is below the floor must exit 76: $(cat "$dir/out")"
  grep -q 'batch: DEFERRED t1' "$dir/out" || fail "the batch did not report the deferral: $(cat "$dir/out")"
  pass "fm-spawn: scout, secondmate, relaunch and batch launches are all held at the floor"
}

test_a_remote_secondmate_is_not_held_by_this_hosts_memory() {
  local dir status
  dir=$(make_fixture remote-mate 1000000)
  printf -- '- rsm - a mate on another host (host: remote-mac; root: /nonexistent/root; home: /nonexistent/home; scope: anything; projects: none; added 2026-10-28)\n' \
    > "$dir/home/data/secondmates.md"
  run_spawn "$dir" FM_SPAWN_MIN_FREE_MB= -- rsm "$dir/proj" --secondmate
  status=$?
  [ "$status" -ne 76 ] || fail "a secondmate that runs on another host was held by this host's memory: $(cat "$dir/out")"
  ! grep -q 'spawn refused: only' "$dir/out" || fail "the remote secondmate hit the local memory floor: $(cat "$dir/out")"
  pass "fm-spawn: a remote secondmate is not held by this host's memory floor"
}

test_unreadable_memory_figure_does_not_block() {
  local dir status
  dir=$(make_fixture unreadable 1500000)
  : > "$dir/meminfo"
  run_spawn "$dir" FM_SPAWN_MIN_FREE_MB= -- t1 "$dir/proj" --mode local-only --yolo off
  status=$?
  [ "$status" -ne 76 ] || fail "a host whose memory cannot be read must not be blocked: $(cat "$dir/out")"
  pass "fm-spawn: an unreadable memory figure does not block a spawn"
}

test_below_two_gb_is_refused_with_a_distinct_exit_and_creates_nothing
test_just_at_the_floor_is_not_refused
test_override_changes_or_disables_the_floor
test_every_launch_kind_is_refused
test_unreadable_memory_figure_does_not_block
test_a_remote_secondmate_is_not_held_by_this_hosts_memory
