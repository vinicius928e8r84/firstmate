#!/usr/bin/env bash
# tests/fm-wake-inline.test.sh - bin/fm-wake-inline.sh, the inline drain and
# turn-end acknowledgement of the main actor. The equivalence claim is that the
# text the model reads and the acknowledgement it would have run are exactly
# what the plain drain presents, so each case drives the real fm-wake-drain.sh
# over the same queue twice (plain, then inline) and compares.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

INLINE="$ROOT/bin/fm-wake-inline.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-inline-tests)

# The drain's BRANCH OUTCOMES section is off on a home without the supervision
# host; pin that posture so the case does not read the code root's config.
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

seed_queue() {  # <state>
  local state=$1
  printf 'window=fm:one\nkind=ship\n' > "$state/one.meta"
  printf 'working: starting\n' > "$state/one.status"
  prime_status_seen "$state" "$state/one.status"
  printf 'done: PR https://example.test/pull/1\n' >> "$state/one.status"
  append_wake "$state" signal one "one done: PR https://example.test/pull/1"
  append_wake "$state" stale two "two idle for 12m"
  append_wake "$state" check poll "check: merged"
}

# Reproduce one queue twice: <dir>/state is the case, <dir>/state.snap its pristine copy.
snapshot() {  # <dir>
  cp -a "$1/state" "$1/state.snap"
}

restore() {  # <dir>
  rm -rf "$1/state"
  cp -a "$1/state.snap" "$1/state"
}

test_inline_text_and_ack_args_match_the_plain_drain() {
  local dir state plain inline ack_out plain_seq inline_seq
  dir=$(make_case inline-equivalence)
  state="$dir/state"
  seed_queue "$state"
  snapshot "$dir"
  plain="$dir/plain.out"
  inline="$dir/inline.out"
  ack_out="$dir/ack.args"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$plain" 2>&1 || fail "plain drain failed: $(cat "$plain")"
  restore "$dir"
  FM_STATE_OVERRIDE="$state" "$INLINE" drain --ack-out "$ack_out" > "$inline" 2>"$dir/inline.err" \
    || fail "inline drain failed: $(cat "$inline" "$dir/inline.err")"

  plain_seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) .*$/\1/p' "$plain")
  [ -n "$plain_seq" ] || fail "setup error: the plain drain printed no acknowledgement line: $(cat "$plain")"
  grep -v '^WAKE_ACK_REQUIRED: ' "$plain" > "$dir/plain.filtered"
  cmp -s "$dir/plain.filtered" "$inline" \
    || fail "inline text differs from the plain drain minus its ack line: $(diff "$dir/plain.filtered" "$inline")"
  grep -q 'WAKE_ACK_REQUIRED' "$inline" && fail "the ack line leaked into the text the model reads"
  inline_seq=$(cut -d' ' -f1 "$ack_out")
  [ "$inline_seq" = "$plain_seq" ] || fail "inline ack sequence $inline_seq differs from the plain drain's $plain_seq"
  [ "$(wc -w < "$ack_out")" -eq 2 ] || fail "ack args must be 'SEQUENCE GENERATION': $(cat "$ack_out")"
  [ "$(wc -l < "$inline")" -gt 0 ] || fail "inline drain presented nothing for a three-row queue"
  pass "inline drain text and acknowledgement arguments equal the plain drain's"
}

test_inline_ack_consumes_exactly_the_drained_rows() {
  local dir state ack_out seq gen later_seq rows
  dir=$(make_case inline-ack)
  state="$dir/state"
  seed_queue "$state"
  ack_out="$dir/ack.args"

  FM_STATE_OVERRIDE="$state" "$INLINE" drain --ack-out "$ack_out" > "$dir/out" 2>&1 || fail "inline drain failed"
  read -r seq gen < "$ack_out"
  append_wake "$state" signal late "late arrival after the drain"

  FM_STATE_OVERRIDE="$state" "$INLINE" ack "$seq" "$gen" > "$dir/ack.out" 2>&1 \
    || fail "inline ack failed: $(cat "$dir/ack.out")"
  rows=$(awk -F '\t' 'NF >= 5' "$state/.wake-queue" 2>/dev/null | wc -l)
  [ "$rows" -eq 1 ] || fail "ack must leave only the row that arrived after the drain, found $rows: $(cat "$state/.wake-queue" 2>/dev/null)"
  later_seq=$(awk -F '\t' 'NF >= 5 { print $2 }' "$state/.wake-queue")
  [ "$later_seq" -gt "$seq" ] || fail "the surviving row $later_seq is not newer than the acknowledged cutoff $seq"

  FM_STATE_OVERRIDE="$state" "$INLINE" ack "$seq" "$gen" > "$dir/ack2.out" 2>&1 \
    || fail "a repeated ack must be a harmless no-op: $(cat "$dir/ack2.out")"
  rows=$(awk -F '\t' 'NF >= 5' "$state/.wake-queue" | wc -l)
  [ "$rows" -eq 1 ] || fail "a repeated ack removed or added rows, found $rows"
  pass "the turn-end ack consumes the drained rows, keeps a later row, and is idempotent"
}

test_unacknowledged_wake_stays_durable() {
  local dir state ack_out
  dir=$(make_case inline-unacked)
  state="$dir/state"
  seed_queue "$state"
  ack_out="$dir/ack.args"
  FM_STATE_OVERRIDE="$state" "$INLINE" drain --ack-out "$ack_out" > "$dir/first.out" 2>&1 || fail "first inline drain failed"
  # An aborted turn never acknowledges: the next drain must present the same rows again.
  FM_STATE_OVERRIDE="$state" "$INLINE" drain --ack-out "$dir/ack2.args" > "$dir/second.out" 2>&1 || fail "second inline drain failed"
  grep -q 'one done: PR https://example.test/pull/1' "$dir/second.out" \
    || fail "a wake that was never acknowledged was not presented again: $(cat "$dir/second.out")"
  [ "$(cut -d' ' -f1 "$ack_out")" = "$(cut -d' ' -f1 "$dir/ack2.args")" ] \
    || fail "the re-presented wake carries a different ack cutoff"
  pass "a wake that is never acknowledged stays durable and is presented again"
}

test_drain_failure_writes_no_ack_and_reports_status() {
  local dir stub status
  dir="$TMP_ROOT/inline-drain-failure"
  mkdir -p "$dir"
  stub="$dir/drain-stub.sh"
  printf '#!/usr/bin/env bash\necho "wake drain: boom" >&2\nexit 1\n' > "$stub"
  chmod +x "$stub"
  FM_WAKE_INLINE_DRAIN="$stub" "$INLINE" drain --ack-out "$dir/ack.args" > "$dir/out" 2>&1
  status=$?
  expect_code 1 "$status" "a failing drain must report its own status so the caller falls back"
  [ ! -e "$dir/ack.args" ] || fail "a failed drain must not publish acknowledgement arguments"
  pass "a failing drain reports its status and publishes no acknowledgement"
}

test_ack_validates_its_arguments() {
  local status
  "$INLINE" ack 5x gen1 > /dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a non-numeric sequence must be refused"
  "$INLINE" ack 5 'bad gen' > /dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a generation with a space must be refused"
  "$INLINE" drain > /dev/null 2>&1
  status=$?
  expect_code 2 "$status" "drain without --ack-out must be refused"
  pass "ack and drain refuse malformed arguments"
}

test_inline_text_and_ack_args_match_the_plain_drain
test_inline_ack_consumes_exactly_the_drained_rows
test_unacknowledged_wake_stays_durable
test_drain_failure_writes_no_ack_and_reports_status
test_ack_validates_its_arguments
