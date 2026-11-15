#!/usr/bin/env bash
# Behavioral coverage for bin/fm-ci-wait.sh over a fake gh that serves one checks JSON per call
# ($W/seq/1, 2, ...; the last one repeats): it blocks through pending checks and exits 0 when all
# passed, 1 as soon as one failed, 3 when the bound ran out with checks pending or none reported,
# 2 when the forge never answered, and issues exactly one gh call per interval.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ci-wait)
WAIT="$ROOT/bin/fm-ci-wait.sh"

# make_world <name> <json>...: the fake gh prints the Nth json on its Nth call (last repeats).
make_world() {
  W="$TMP_ROOT/$1"; shift
  mkdir -p "$W/seq"
  local n=0 j
  for j in "$@"; do n=$((n + 1)); printf '%s\n' "$j" > "$W/seq/$n"; done
  echo 0 > "$W/calls"
  cat > "$W/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$W/argv"
n=\$(( \$(cat "$W/calls") + 1 )); echo \$n > "$W/calls"
f="$W/seq/\$n"; [ -f "\$f" ] || f="$W/seq/\$(ls "$W/seq" | sort -n | tail -1)"
cat "\$f"; case "\$(head -c 20 "\$f")" in "["*) exit 0 ;; *) exit 1 ;; esac
SH
  chmod +x "$W/gh"
}

run_wait() { FM_CI_WAIT_GH="$W/gh" bash "$WAIT" "$@" 2>&1; }

P='{"name":"unit","bucket":"pending","link":"http://x/1"}'
G='{"name":"unit","bucket":"pass","link":"http://x/1"}'
S='{"name":"lint","bucket":"skipping","link":"http://x/2"}'
F='{"name":"e2e","bucket":"fail","link":"http://x/3"}'

test_blocks_until_checks_pass_in_one_command() {
  make_world pass "[$P]" "[$P]" "[$G,$S]"
  out=$(run_wait https://github.com/o/r/pull/9 --interval 1 --timeout 30); rc=$?
  assert_equals 0 "$rc" "all checks passed exits 0"
  assert_contains "$out" "ci: PASSED on https://github.com/o/r/pull/9 (2 checks)" "result line"
  assert_equals 3 "$(cat "$W/calls")" "one gh read per interval until settled, inside one command"
  pass "blocks through pending checks and exits 0 when they pass"
}

test_failure_returns_at_once_and_names_the_check() {
  make_world fail "[$P,$F]"
  out=$(run_wait 9 --repo o/r --interval 1 --timeout 30); rc=$?
  assert_equals 1 "$rc" "a failed check exits 1 without waiting for the pending one"
  assert_contains "$out" "failed: e2e http://x/3" "the failing check is named"
  assert_contains "$(cat "$W/argv")" "-R o/r" "the repo flag reaches gh"
  assert_equals 1 "$(cat "$W/calls")" "no further polling after a failure"
  pass "a failure returns at once and names the check"
}

test_timeout_is_3_and_tells_to_rerun() {
  make_world pend "[$P]"
  out=$(run_wait 9 --interval 1 --timeout 2); rc=$?
  assert_equals 3 "$rc" "still pending at the bound exits 3"
  assert_contains "$out" "run the same command again" "the caller is told to re-run, not to poll"
  make_world none "no checks reported on the 'x' branch"
  out=$(run_wait 9 --interval 1 --timeout 2); rc=$?
  assert_equals 3 "$rc" "no checks reported yet exits 3, not 0"
  assert_contains "$out" "no checks reported yet" "says nothing reported"
  pass "bound reached with pending or no checks exits 3"
}

test_unreadable_forge_is_2() {
  make_world bad "HTTP 502: bad gateway"
  out=$(run_wait 9 --interval 1 --timeout 2); rc=$?
  assert_equals 2 "$rc" "an unreadable forge for the whole wait exits 2"
  assert_contains "$out" "could not read the checks" "says it could not read"
  make_world blip "HTTP 502: bad gateway" "[$G]"
  out=$(run_wait 9 --interval 1 --timeout 30); rc=$?
  assert_equals 0 "$rc" "one transient read failure does not end the wait"
  pass "an unreadable forge exits 2 only when it never answers"
}

test_usage() {
  make_world usage "[$G]"
  run_wait >/dev/null; assert_equals 2 "$?" "no PR is a usage error"
  run_wait 9 --timeout x >/dev/null; assert_equals 2 "$?" "bad timeout is a usage error"
  run_wait 9 --bogus >/dev/null; assert_equals 2 "$?" "unknown flag is a usage error"
  pass "usage errors exit 2"
}

test_blocks_until_checks_pass_in_one_command
test_failure_returns_at_once_and_names_the_check
test_timeout_is_3_and_tells_to_rerun
test_unreadable_forge_is_2
test_usage

echo '# all fm-ci-wait tests passed'
