#!/usr/bin/env bash
# Behavioral coverage for data/tools/fm-remote-login-test.sh (a home script, not tracked here):
# a fake ssh host that answers is recorded alive, a mute host is marked dead with exit code and
# evidence, a failing host keeps its stderr, the TSV is durable, and only a state CHANGE notifies.
# Set FM_REMOTE_LOGIN_SCRIPT to point at the script; the test skips when it is absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT=${FM_REMOTE_LOGIN_SCRIPT:-/home/factory/firstmate/data/tools/fm-remote-login-test.sh}
if [ ! -x "$SCRIPT" ]; then
  echo "1..0 # SKIP $SCRIPT not present"
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-remote-login)

# Fake ssh: the last two args are "<host>" "<remote command>".
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/fake-ssh" <<'SH'
#!/usr/bin/env bash
host=${@: -2:1}
case $host in
  alive-host) echo pong ;;
  mute-host) sleep 30 ;;
  broken-host) echo "Invalid API key" >&2; exit 1 ;;
  flip-host) if [ -e "$FAKE_FLIP" ]; then echo pong; else echo "not logged in" >&2; exit 1; fi ;;
esac
SH
chmod +x "$TMP_ROOT/bin/fake-ssh"

new_home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/config"
  printf '# comment\n\n%s\n' "$2" > "$h/config/remote-login-hosts"
  echo "$h"
}
run() { # run <home> -> sets OUT RC
  OUT=$(FM_HOME="$1" FM_REMOTE_LOGIN_SSH="$TMP_ROOT/bin/fake-ssh" FAKE_FLIP="$TMP_ROOT/flip.marker" \
    FM_REMOTE_LOGIN_DEADLINE=2 "$SCRIPT" 2>&1); RC=$?
}
tsv() { cat "$1"/data/remote-login/*.tsv; }

test_help_has_contract() {
  local out; out=$("$SCRIPT" --help 2>&1) || fail "--help exited non-zero"
  assert_contains "$out" "Usage:" "help shows usage"
  assert_contains "$out" "Undo:" "help shows undo"
  pass "--help prints usage, contract and undo"
}

test_alive_and_mute() {
  local h; h=$(new_home both "$(printf 'alive-host\nmute-host')")
  run "$h"
  expect_code 1 "$RC" "a mute host makes the run exit 1"
  assert_contains "$(tsv "$h")" "$(printf 'alive-host\talive\t0')" "responding host is alive"
  assert_contains "$(tsv "$h")" "$(printf 'mute-host\tdead\t124')" "mute host is dead with timeout code"
  assert_contains "$(tsv "$h")" "no response within 2s" "dead evidence says why"
  assert_contains "$OUT" "DEAD on mute-host" "dead host gets a notice"
  assert_not_contains "$OUT" "alive-host" "alive first sighting is silent"
  pass "answering host alive, mute host dead with evidence"
}

test_stderr_evidence() {
  local h; h=$(new_home broken broken-host)
  run "$h"
  expect_code 1 "$RC" "failing host exits 1"
  assert_contains "$(tsv "$h")" "Invalid API key" "stderr kept as evidence"
  assert_contains "$(tsv "$h")" "$(printf 'broken-host\tdead\t1')" "exit code recorded"
  pass "failing host keeps stderr and exit code"
}

test_notice_only_on_change() {
  local h; h=$(new_home flip flip-host)
  rm -f "$TMP_ROOT/flip.marker"
  run "$h"; assert_contains "$OUT" "DEAD on flip-host" "first dead notifies"
  run "$h"; assert_not_contains "$OUT" "DEAD" "repeat dead stays silent"
  touch "$TMP_ROOT/flip.marker"
  run "$h"; expect_code 0 "$RC" "recovered run exits 0"
  assert_contains "$OUT" "RECOVERED on flip-host" "recovery notifies once"
  run "$h"; assert_equals "" "$OUT" "steady alive is silent"
  assert_equals 5 "$(tsv "$h" | wc -l)" "header plus four rows kept durably"
  pass "notice only when state changes"
}

test_bad_config() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT/nohome" "$SCRIPT" 2>&1); rc=$?
  expect_code 2 "$rc" "missing hosts file is a config error"
  pass "missing hosts file refused"
}

test_help_has_contract
test_alive_and_mute
test_stderr_evidence
test_notice_only_on_change
test_bad_config
echo '# all fm-remote-login-test tests passed'
