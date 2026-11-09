#!/usr/bin/env bash
# Behavioral coverage for bin/fm-steer.sh with stand-in lease and fm-say tools: the lease is claimed before and
# released after the send, a lease main already held is left alone, a lease the other supervisor holds stops the
# steer before anything is sent, the message reaches fm-say whole, and fm-say's final line and exit status are the result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-steer)
STEER="$ROOT/bin/fm-steer.sh"

new_home() {
  H="$TMP_ROOT/$1"; mkdir -p "$H"
  export FM_HOME="$H" FM_STEER_SAY="$H/say" FM_STEER_LEASE="$H/lease"
  cat > "$H/lease" <<S
#!/usr/bin/env bash
echo "lease \$*" >> '$H/calls'
case "\$1" in
  check) [ -n "\${HELD_BY_MAIN:-}" ] && echo "main 1 2 live"; exit 0 ;;
  claim) [ -z "\${LEASE_FAIL:-}" ] ;;
  release) exit 0 ;;
esac
S
  cat > "$H/say" <<S
#!/usr/bin/env bash
echo "say \$*" >> '$H/calls'
printf '%s' "\$*" > '$H/say.text'
echo "note: supervisor warning hidden" >&2
echo "\${SAY_OUT-DELIVERED pm-1 record=/x/1.msg}"
exit "\${SAY_RC:-0}"
S
  chmod +x "$H/lease" "$H/say"
  printf 'line one\nline two\n' > "$H/msg.txt"
}
run() { out=$("$STEER" "$@" 2>&1); rc=$?; }

test_delivered() {
  new_home ok
  run pm-1 --file "$H/msg.txt" --resolve-key k1
  expect_code 0 "$rc" "delivered exit"
  assert_equals "DELIVERED pm-1 record=/x/1.msg" "$out" "fm-say's final line is the only output"
  assert_equals "lease check pm-1
lease claim pm-1 --actor main
say pm-1 --resolve-key k1 line one
line two
lease release pm-1 --actor main" "$(cat "$H/calls")" "claim, send whole text, release, in order"
  pass "steer: lease around the send, whole message, one line"
}

test_lease_rules() {
  new_home held; LEASE_FAIL=1 run pm-1 --file "$H/msg.txt"
  expect_code 6 "$rc" "other supervisor holds the lease"
  assert_contains "$out" "LEASE-HELD pm-1" "named"
  assert_no_grep "say " "$H/calls" "nothing sent while the lease is held elsewhere"
  new_home mine; HELD_BY_MAIN=1 run pm-1 --file "$H/msg.txt"
  expect_code 0 "$rc" "send with a lease main already holds"
  assert_no_grep "lease release" "$H/calls" "a lease main already held is left held"
  pass "lease: held elsewhere refuses before sending; one already held by main is not released"
}

test_results_and_usage() {
  new_home unknown; SAY_OUT="UNKNOWN pm-1: no inbox record" SAY_RC=3 run pm-1 --file "$H/msg.txt" --again
  expect_code 3 "$rc" "unknown passes through"
  assert_contains "$out" "UNKNOWN pm-1" "unknown is the result"
  assert_contains "$(cat "$H/calls")" "say --again pm-1" "--again reaches fm-say"
  assert_contains "$(cat "$H/calls")" "lease release" "the lease taken here is released even on a bad result"
  new_home dup; SAY_OUT="DUPLICATE-REFUSED pm-1: same message" SAY_RC=4 run pm-1 --file "$H/msg.txt"
  expect_code 4 "$rc" "duplicate passes through"
  new_home quiet; SAY_OUT="" SAY_RC=1 run pm-1 --file "$H/msg.txt"
  assert_contains "$out" "FAILED pm-1: fm-say printed no result" "a silent fm-say is a failure, not a success"
  new_home empty; : > "$H/e.txt"; run pm-1 --file "$H/e.txt"
  expect_code 2 "$rc" "empty message"
  assert_absent "$H/calls" "nothing touched for an empty message"
  out=$(printf 'from stdin\n' | "$STEER" pm-1 --file -); rc=$?
  expect_code 0 "$rc" "stdin message"
  assert_equals "say pm-1 from stdin" "$(grep '^say' "$H/calls")" "stdin text sent"
  run; expect_code 2 "$rc" "no target"
  out=$(env -u FM_HOME "$STEER" pm-1 --file "$H/msg.txt" 2>&1); rc=$?
  expect_code 1 "$rc" "FM_HOME must be explicit"
  pass "results: fm-say's status and line pass through, empty and silent cases refuse, stdin works, FM_HOME explicit"
}

test_delivered
test_lease_rules
test_results_and_usage

echo '# all fm-steer tests passed'
