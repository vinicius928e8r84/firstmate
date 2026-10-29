#!/usr/bin/env bash
# Behavior tests for bin/fm-overflow.sh: choosing a remote secondmate host with
# room from its published lane facts, and handing work to it as a routed request.
# fm-on.sh and fm-send.sh are replaced by fakes that serve canned lane facts and
# log what would have been sent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OVERFLOW="$ROOT/bin/fm-overflow.sh"
TMP_ROOT=$(fm_test_tmproot fm-overflow)

# make_case <name>: a home with remote secondmate records for creative-aux and
# pc-aux2, plus fake fm-on (serves $dir/facts/<id>.json) and fm-send (logs).
make_case() {
  local dir="$TMP_ROOT/$1" id
  mkdir -p "$dir/home/state" "$dir/facts"
  for id in creative-aux pc-aux2; do
    fm_write_meta "$dir/home/state/$id.meta" "kind=secondmate" "mode=secondmate" "remote_host=$id-host"
  done
  cat > "$dir/on" <<'SH'
#!/usr/bin/env bash
[ "$2 $3 $4" = "fm-remote-file.sh get state/lane-capacity.json" ] || exit 64
cat "$FAKE_FACTS/$1.json" 2>/dev/null || exit 1
SH
  cat > "$dir/send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SEND_LOG"
SH
  chmod +x "$dir/on" "$dir/send"
  printf '%s\n' "$dir"
}

# facts <dir> <id> <target> <lanes> <runq-per-core> [generated-age-s] [level] [reserve]
facts() {
  local age=${6:-5}
  jq -n --argjson gen "$(($(date +%s) - age))" --argjson target "$3" --argjson lanes "$4" \
    --argjson rpc "$5" --arg level "${7:-ok}" --arg reserve "${8:-absent}" '
    {schema: "fm-lane-capacity.v1", generated_epoch: $gen,
     lanes: {count: $lanes}, cap: {target: $target, status: "ok"},
     pressure: {level: $level, runq_per_core: $rpc}, reserve: {flag: $reserve}}' > "$1/facts/$2.json"
}

run() {  # <dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE='' FM_OVERFLOW_ON="$dir/on" FM_OVERFLOW_SEND="$dir/send" \
    FAKE_FACTS="$dir/facts" FAKE_SEND_LOG="$dir/send.log" "$OVERFLOW" "$@" 2>&1
}

test_picks_the_lightest_host_with_a_free_lane() {
  local dir out rc=0
  dir=$(make_case lightest)
  facts "$dir" creative-aux 6 2 1.2
  facts "$dir" pc-aux2 8 1 0.3
  out=$(run "$dir" pick) || rc=$?
  expect_code 0 "$rc" "pick failed with two free hosts: $out"
  assert_contains "$out" "picked: pc-aux2 (7 free of 8 lanes, load 0.3 per core)" "the lighter host was not picked"
  assert_contains "$out" "skipped: creative-aux (free but ranked below pc-aux2)" "the other free host was not reported"
  pass "pick chooses the free host with the lowest load per core and says why"
}

test_skips_hosts_that_are_loaded_full_stale_or_reserved() {
  local dir out rc=0
  dir=$(make_case skips)
  facts "$dir" creative-aux 6 2 3.4
  facts "$dir" pc-aux2 4 4 0.1
  out=$(run "$dir" pick) || rc=$?
  expect_code 1 "$rc" "pick succeeded with no host free: $out"
  assert_contains "$out" "none free" "no free host was not reported"
  assert_contains "$out" "skipped: creative-aux (load 3.4 per core, at or over 3)" "the loaded host was not skipped for its load"
  assert_contains "$out" "skipped: pc-aux2 (no free lane (4 of 4))" "the full host was not skipped for its lanes"

  facts "$dir" creative-aux 6 2 1 900
  facts "$dir" pc-aux2 8 1 0.1 5 ok present
  out=$(run "$dir" pick) || rc=$?
  assert_contains "$out" "skipped: creative-aux (lane facts are stale)" "stale facts were trusted"
  assert_contains "$out" "skipped: pc-aux2 (captain reserve is set)" "a reserved host was used"

  facts "$dir" creative-aux 6 2 1 5 critical
  rm "$dir/facts/pc-aux2.json"
  out=$(run "$dir" pick) || rc=$?
  assert_contains "$out" "skipped: creative-aux (pressure is critical)" "a critical host was used"
  assert_contains "$out" "skipped: pc-aux2 (lane facts unreadable)" "an unreachable host was not skipped"
  pass "hosts that are loaded, full, stale, reserved, critical, or unreachable are skipped with the reason"
}

test_skips_a_host_without_a_remote_secondmate_record() {
  local dir out rc=0
  dir=$(make_case norecord)
  facts "$dir" creative-aux 6 2 1
  facts "$dir" pc-aux2 8 1 0.3
  rm "$dir/home/state/pc-aux2.meta"
  out=$(run "$dir" pick) || rc=$?
  expect_code 0 "$rc" "pick failed: $out"
  assert_contains "$out" "picked: creative-aux" "the host with a record was not picked"
  assert_contains "$out" "skipped: pc-aux2 (no remote secondmate record here)" "an unrecorded host was considered"
  pass "a candidate with no remote secondmate record is never picked"
}

test_json_output() {
  local dir out
  dir=$(make_case json)
  facts "$dir" creative-aux 6 2 1.2
  facts "$dir" pc-aux2 8 8 0.3
  out=$(run "$dir" pick --json) || true
  assert_equals "creative-aux" "$(printf '%s' "$out" | jq -r .picked)" "json did not name the pick"
  assert_equals "pc-aux2" "$(printf '%s' "$out" | jq -r '.skipped[0].id')" "json did not list the skipped host"
  pass "pick --json carries the pick and the skipped hosts"
}

test_send_hands_the_text_to_the_picked_host_only() {
  local dir out rc=0
  dir=$(make_case send)
  facts "$dir" creative-aux 6 2 1.2
  facts "$dir" pc-aux2 8 1 0.3
  out=$(run "$dir" send run the heavy suite) || rc=$?
  expect_code 0 "$rc" "send failed: $out"
  assert_contains "$out" "sent: pc-aux2" "send did not report the host"
  assert_equals "pc-aux2 run the heavy suite" "$(cat "$dir/send.log")" "the text did not go to the picked host"

  rm -f "$dir/send.log"
  facts "$dir" pc-aux2 8 8 0.3
  facts "$dir" creative-aux 6 6 1
  rc=0
  out=$(run "$dir" send run the heavy suite) || rc=$?
  expect_code 1 "$rc" "send succeeded with no host free: $out"
  assert_contains "$out" "none free" "send did not report that no host is free"
  assert_absent "$dir/send.log" "send delivered work although no host was free"
  pass "send routes the text to the picked host and sends nothing when none is free"
}

test_usage() {
  local dir rc=0
  dir=$(make_case usage)
  run "$dir" send >/dev/null || rc=$?
  expect_code 2 "$rc" "send without text was accepted"
  rc=0
  run "$dir" bogus >/dev/null || rc=$?
  expect_code 2 "$rc" "an unknown mode was accepted"
  pass "a missing message or unknown mode is a usage error"
}

test_picks_the_lightest_host_with_a_free_lane
test_skips_hosts_that_are_loaded_full_stale_or_reserved
test_skips_a_host_without_a_remote_secondmate_record
test_json_output
test_send_hands_the_text_to_the_picked_host_only
test_usage
