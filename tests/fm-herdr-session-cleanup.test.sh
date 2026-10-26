#!/usr/bin/env bash
# Focused safety tests for bin/fm-herdr-session-cleanup.sh.
# Covers one exact cleanup, every title/journal/topology/agent/process refusal,
# locked revalidation races, focus refusal, read errors, and repeat idempotence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-session-cleanup)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$FM_HOME/state"
export FM_CONFIG_OVERRIDE="$FM_HOME/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
touch "$FM_CONFIG_OVERRIDE/herdr-presentation-spaces"
printf '%s\n' herdr > "$FM_CONFIG_OVERRIDE/backend"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_fake_exit0 "$FAKEBIN" herdr
export PATH="$FAKEBIN:$PATH"
export FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-session-cleanup.sh"
unset FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY

# The idle-shell proof now lives in the backend as
# fm_backend_herdr_pane_idle_shell_pid; prove it still reads Linux argv
# arrays (no argv0 field) and rejects malformed executable identities.
FAKE_PS="$TMP_ROOT/fake-ps"
cat > "$FAKE_PS" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-axo pid=,ppid=") printf '1 0\n67 1\n' ;;
  "-p 67 -o stat=") printf 'Ss\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKE_PS"
LINUX_PROCESS_INFO='{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p1","shell_pid":67,"foreground_process_group_id":67,"foreground_processes":[{"argv":["/bin/sh"],"name":"sh","pid":67}]}}}'
argv_pid=$(
  # shellcheck disable=SC2329 # invoked indirectly by the idle-shell proof.
  fm_backend_herdr_cli() { printf '%s\n' "$LINUX_PROCESS_INFO"; }
  FM_HERDR_PS_BIN="$FAKE_PS" fm_backend_herdr_pane_idle_shell_pid test w2:p1
) || fail "Linux Herdr process argv array was not accepted"
[ "$argv_pid" = 67 ] || fail "idle-shell proof printed the wrong shell pid: $argv_pid"
if (
  # shellcheck disable=SC2329 # invoked indirectly by the idle-shell proof.
  fm_backend_herdr_cli() { printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p1","shell_pid":67,"foreground_process_group_id":67,"foreground_processes":[{"argv":[67],"name":"sh","pid":67}]}}}'; }
  FM_HERDR_PS_BIN="$FAKE_PS" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    fm_backend_herdr_pane_idle_shell_pid test w2:p1
) >/dev/null 2>&1; then
  fail "non-string Herdr process argv was accepted"
fi
pass "process proof reads Linux Herdr argv arrays and rejects malformed executable identities"

TOKEN=AbCdEfGhIjKlMnOpQrStUv
ID=task
WS=w2
TAB=w2:t1
PANE=w2:p1
TITLE="└ task · p:$TOKEN"
FIXTURE_DIR="$TMP_ROOT/fixture"
LOCK_LOG="$TMP_ROOT/locks.log"
CLOSE_LOG="$TMP_ROOT/closes.log"
mkdir -p "$FIXTURE_DIR"

fm_backend_name() { printf herdr; }
fm_backend_herdr_session() { printf test; }
fm_backend_herdr_presentation_session_lock_path() { printf '%s/presentation.lock' "$TMP_ROOT"; }
fm_lock_try_acquire() {
  printf '%s\n' "$1" >> "$LOCK_LOG"
  mkdir "$1" 2>/dev/null
}
fm_lock_release() { rm -rf -- "$1"; }
fm_backend_herdr_pane_idle_shell_pid() { [ ! -e "$FIXTURE_DIR/process-unsafe" ] && printf '67\n'; }
fm_backend_herdr_projection_focus_snapshot() {
  [ ! -e "$FIXTURE_DIR/focus-unreadable" ] || return 1
  printf 'w1\t%s' "$(cat "$FIXTURE_DIR/active-tab")"
}

fixture_workspace_json() {
  local title=$1 tabs=$2 panes=$3 focused=false active=$TAB
  [ "$(cat "$FIXTURE_DIR/active-tab")" = "$TAB" ] && focused=true
  printf '{"workspace_id":"%s","label":"%s","focused":%s,"active_tab_id":"%s","tab_count":%s,"pane_count":%s}' \
    "$WS" "$title" "$focused" "$active" "$tabs" "$panes"
}

fixture_workspaces() {
  local title tabs panes
  title=$(cat "$FIXTURE_DIR/title")
  tabs=$(cat "$FIXTURE_DIR/tabs")
  panes=$(cat "$FIXTURE_DIR/panes")
  printf '[{"workspace_id":"w1","label":"firstmate","focused":%s,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1},' \
    "$( [ "$(cat "$FIXTURE_DIR/active-tab")" = w1:t1 ] && printf true || printf false )"
  fixture_workspace_json "$title" "$tabs" "$panes"
  if [ -e "$FIXTURE_DIR/duplicate-token" ]; then
    printf ',{"workspace_id":"w3","label":"└ copy · p:%s","focused":false,"active_tab_id":"w3:t1","tab_count":1,"pane_count":1}' "$TOKEN"
  fi
  printf ']'
}

fixture_tabs() {
  local count i
  count=$(cat "$FIXTURE_DIR/tabs")
  printf '['
  i=1
  while [ "$i" -le "$count" ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"tab_id":"%s:t%s","workspace_id":"%s","focused":false,"label":"fm-task"}' "$WS" "$i" "$WS"
    i=$((i + 1))
  done
  printf ']'
}

fixture_panes() {
  local count i
  count=$(cat "$FIXTURE_DIR/panes")
  printf '['
  i=1
  while [ "$i" -le "$count" ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"pane_id":"%s:p%s","tab_id":"%s:t%s","workspace_id":"%s","agent_status":"unknown"}' \
      "$WS" "$i" "$WS" "$i" "$WS"
    i=$((i + 1))
  done
  printf ']'
}

fm_backend_herdr_cli() {
  local _session=$1 first=${2:-} second=${3:-} title tabs panes
  shift
  [ ! -e "$FIXTURE_DIR/api-calls" ] || printf '%s %s\n' "$first" "$second" >> "$FIXTURE_DIR/api-calls"
  if [ -e "$FIXTURE_DIR/bulk" ]; then
    case "$first $second" in
      "workspace list") printf '{"result":{"workspaces":%s}}\n' "$(cat "$FIXTURE_DIR/bulk-workspaces")"; return 0 ;;
      "api snapshot")
        printf '{"result":{"snapshot":{"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":%s,"tabs":[],"panes":[]}}}\n' \
          "$(cat "$FIXTURE_DIR/bulk-workspaces")"
        return 0
        ;;
    esac
    return 1
  fi
  [ ! -e "$FIXTURE_DIR/error-${first}-${second}" ] || return 1
  if [ -e "$FIXTURE_DIR/closed" ]; then
    case "$first $second" in
      "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2; return 1 ;;
      "workspace list") printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1}]}}'; return 0 ;;
    esac
  fi
  if [ -e "$FIXTURE_DIR/race" ] && [ -e "$FIXTURE_DIR/snapshotted" ] && [ "$first $second" = "workspace list" ]; then
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1},{"workspace_id":"w2","label":"renamed","focused":false,"active_tab_id":"w2:t1","tab_count":1,"pane_count":1}]}}'
    return 0
  fi
  title=$(cat "$FIXTURE_DIR/title")
  tabs=$(cat "$FIXTURE_DIR/tabs")
  panes=$(cat "$FIXTURE_DIR/panes")
  case "$first $second" in
    "workspace list")
      printf '{"result":{"workspaces":'; fixture_workspaces; printf '}}\n'
      ;;
    "workspace get")
      printf '{"result":{"workspace":'; fixture_workspace_json "$title" "$tabs" "$panes"; printf '}}\n'
      ;;
    "tab list")
      printf '{"result":{"tabs":'; fixture_tabs; printf '}}\n'
      ;;
    "pane list")
      printf '{"result":{"panes":'; fixture_panes; printf '}}\n'
      ;;
    "pane get")
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"}}}\n' "$PANE" "$TAB" "$WS"
      ;;
    "agent get")
      case "$(cat "$FIXTURE_DIR/agent")" in
        absent) printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2; return 1 ;;
        live) printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' ;;
        unknown) printf '%s\n' '{"error":{"code":"internal_error"}}' >&2; return 1 ;;
      esac
      ;;
    "api snapshot")
      : > "$FIXTURE_DIR/snapshotted"
      printf '{"result":{"snapshot":{"focused_workspace_id":"w1","focused_tab_id":"%s","focused_pane_id":"w1:p1","workspaces":' "$(cat "$FIXTURE_DIR/active-tab")"
      fixture_workspaces
      printf ',"tabs":'; fixture_tabs
      printf ',"panes":'; fixture_panes
      printf '}}}\n'
      ;;
    "session list")
      printf '%s\n' '{"sessions":[{"name":"test","running":true,"socket_path":"/tmp/fake.sock"}]}'
      ;;
    "pane close")
      : > "$FIXTURE_DIR/closed"
      ;;
    *) return 1 ;;
  esac
}

fm_backend_herdr_projection_close_pane_focus_preserving() {
  [ ! -e "$FIXTURE_DIR/focus-refuse" ] || return 1
  [ "${3:-}" = no-agent ] || return 1
  printf '%s\n' "$*" >> "$CLOSE_LOG"
  : > "$FIXTURE_DIR/closed"
}

write_v1() { # <id> [token]
  local id=$1 token=${2:-$TOKEN}
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
  } > "$FM_STATE_OVERRIDE/$id.herdr-presentation"
}

write_v2() { # <home> <workspace> <tab> <pane>
  local home=$1 workspace=$2 tab=$3 pane=$4
  {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$ID"
    printf 'projection_id=%s\n' "$TOKEN"
    printf 'home=%s\n' "$home"
    printf 'session=test\nworkspace_id=%s\ntab_id=%s\npane_id=%s\n' "$workspace" "$tab" "$pane"
    printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=%s\ntask_label=fm-%s\n' "$TITLE" "$ID"
  } > "$FM_STATE_OVERRIDE/$ID.herdr-presentation"
}

write_cross_home_v2() {
  mkdir -p "$TMP_ROOT/other-home"
  write_v2 "$TMP_ROOT/other-home" "$WS" "$TAB" "$PANE"
}

reset_fixture() {
  rm -rf "$FIXTURE_DIR" "$TMP_ROOT"/*.lock "${FM_STATE_OVERRIDE:?}/"*
  mkdir -p "$FIXTURE_DIR"
  : > "$LOCK_LOG"; : > "$CLOSE_LOG"
  printf '%s\n' "$TITLE" > "$FIXTURE_DIR/title"
  printf '1\n' > "$FIXTURE_DIR/tabs"
  printf '1\n' > "$FIXTURE_DIR/panes"
  printf 'w1:t1\n' > "$FIXTURE_DIR/active-tab"
  printf 'absent\n' > "$FIXTURE_DIR/agent"
  write_v1 "$ID"
}

assert_preserved() { # <case>
  local name=$1 had_journal=0
  [ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] && had_journal=1
  fm_herdr_session_cleanup >/dev/null 2>&1
  if [ "$had_journal" -eq 1 ]; then
    [ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "$name retired the journal"
  fi
  [ ! -s "$CLOSE_LOG" ] || fail "$name closed the pane"
  pass "$name preserves the candidate"
}

reset_fixture
fm_herdr_session_cleanup >/dev/null 2>&1
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "positive cleanup kept the journal"
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "positive cleanup did not close exactly once"
[ "$(sed -n '1p' "$LOCK_LOG")" = "$FM_STATE_OVERRIDE/.spawn-$ID.lock" ] || fail "task lock was not acquired first"
[ "$(sed -n '2p' "$LOCK_LOG")" = "$TMP_ROOT/presentation.lock" ] || fail "presentation lock was not acquired second"
pass "exact stale projection closes one exact pane under task then presentation locks"
fm_herdr_session_cleanup >/dev/null 2>&1
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "repeat cleanup closed again"
pass "successful cleanup is idempotent on repeat"

reset_fixture; printf '%s\n' '└ malformed p:AbCdEfGhIjKlMnOpQrStUv' > "$FIXTURE_DIR/title"; assert_preserved "malformed title"
reset_fixture; printf '%s\n' '└ missing-token' > "$FIXTURE_DIR/title"; assert_preserved "missing token"
reset_fixture; printf 'version=1\ntask_id=%s\nprojection_id=short\n' "$ID" > "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; assert_preserved "malformed journal"
reset_fixture; : > "$FIXTURE_DIR/duplicate-token"; assert_preserved "duplicate token"
reset_fixture; printf '%s\n' "└ task · p:$TOKEN p:$TOKEN" > "$FIXTURE_DIR/title"; assert_preserved "duplicate title token"
reset_fixture; rm -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; assert_preserved "zero journal match"
reset_fixture; write_v1 fm-task; assert_preserved "multiple journal matches"
reset_fixture; rm -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; write_cross_home_v2; assert_preserved "cross-home journal"
reset_fixture; write_v2 "$FM_HOME" w9 "$TAB" "$PANE"; assert_preserved "v2 workspace binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" w9:t1 "$PANE"; assert_preserved "v2 tab binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" "$TAB" w9:p1; assert_preserved "v2 pane binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" "$TAB" "$PANE"
fm_herdr_session_cleanup >/dev/null 2>&1
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "matching v2 cleanup kept the journal"
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "matching v2 cleanup did not close exactly once"
pass "v2 cleanup requires and accepts the exact journal endpoint binding"
reset_fixture; : > "$FM_STATE_OVERRIDE/$ID.meta"; assert_preserved "current task metadata"
reset_fixture; printf 'live\n' > "$FIXTURE_DIR/agent"; assert_preserved "registered agent"
reset_fixture; printf 'unknown\n' > "$FIXTURE_DIR/agent"; assert_preserved "unknown agent"
reset_fixture; printf '2\n' > "$FIXTURE_DIR/tabs"; printf '2\n' > "$FIXTURE_DIR/panes"; assert_preserved "multiple tabs"
reset_fixture; printf '2\n' > "$FIXTURE_DIR/panes"; assert_preserved "multiple panes"
reset_fixture; : > "$FIXTURE_DIR/process-unsafe"; assert_preserved "non-idle shell"
reset_fixture; : > "$FIXTURE_DIR/process-unsafe"; assert_preserved "child process or shell job"
reset_fixture; : > "$FIXTURE_DIR/error-api-snapshot"; assert_preserved "unreadable snapshot"
reset_fixture; : > "$FIXTURE_DIR/error-workspace-get"; assert_preserved "unreadable topology check"
reset_fixture; : > "$FIXTURE_DIR/race"; assert_preserved "revalidation race"
reset_fixture; printf '%s\n' "$TAB" > "$FIXTURE_DIR/active-tab"; assert_preserved "active target"
reset_fixture; : > "$FIXTURE_DIR/focus-refuse"; assert_preserved "focus refusal"


# --- cost: parsing and API calls must not scale with journals x candidates ----
# The journal parse and the candidate loop once forked about forty processes per
# journal for every candidate and took a locked API snapshot per candidate,
# minutes of wall time at 66 journals on a CPU-contended host. The checks below
# count real subprocesses and API calls, which is load-independent.

# The earlier grep/cut/wc journal reader, kept as the oracle the one-pass reader
# must agree with on every shape of journal, valid or not.
oracle_journal_field() { # <journal> <key>
  local journal=$1 key=$2 count
  count=$(grep -c "^${key}=" "$journal" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$journal" 2>/dev/null | cut -d= -f2-
}

oracle_journal_snapshot() { # <journal> <task-id>
  local journal=$1 id=$2 lines expected_label expected_task_label exact
  FM_BACKEND_HERDR_JOURNAL_VERSION="" FM_BACKEND_HERDR_JOURNAL_TASK_ID=""
  FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID="" FM_BACKEND_HERDR_JOURNAL_HOME=""
  FM_BACKEND_HERDR_JOURNAL_SESSION="" FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID=""
  FM_BACKEND_HERDR_JOURNAL_TAB_ID="" FM_BACKEND_HERDR_JOURNAL_PANE_ID=""
  FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID="" FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL=""
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL="" FM_BACKEND_HERDR_JOURNAL_TASK_LABEL=""
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  lines=$(wc -l < "$journal" 2>/dev/null | tr -d '[:space:]')
  FM_BACKEND_HERDR_JOURNAL_VERSION=$(oracle_journal_field "$journal" version) || return 1
  FM_BACKEND_HERDR_JOURNAL_TASK_ID=$(oracle_journal_field "$journal" task_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID=$(oracle_journal_field "$journal" projection_id) || return 1
  [ "$FM_BACKEND_HERDR_JOURNAL_TASK_ID" = "$id" ] || return 1
  [ "${#FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID}" -eq 22 ] || return 1
  case "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$FM_BACKEND_HERDR_JOURNAL_VERSION:$lines" in
    1:3) return 0 ;;
    2:12) ;;
    *) return 1 ;;
  esac
  FM_BACKEND_HERDR_JOURNAL_HOME=$(oracle_journal_field "$journal" home) || return 1
  FM_BACKEND_HERDR_JOURNAL_SESSION=$(oracle_journal_field "$journal" session) || return 1
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID=$(oracle_journal_field "$journal" workspace_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_TAB_ID=$(oracle_journal_field "$journal" tab_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PANE_ID=$(oracle_journal_field "$journal" pane_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID=$(oracle_journal_field "$journal" parent_workspace_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL=$(oracle_journal_field "$journal" parent_label) || return 1
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL=$(oracle_journal_field "$journal" workspace_label) || return 1
  FM_BACKEND_HERDR_JOURNAL_TASK_LABEL=$(oracle_journal_field "$journal" task_label) || return 1
  case "$FM_BACKEND_HERDR_JOURNAL_HOME" in /*) ;; *) return 1 ;; esac
  for exact in "$FM_BACKEND_HERDR_JOURNAL_SESSION" "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID"; do
    case "$exact" in ''|*[[:space:]]*) return 1 ;; esac
  done
  [ -n "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL" ] \
    && [ -n "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" ] \
    && [ -n "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" ] || return 1
  expected_label=$(fm_backend_herdr_projection_workspace_label "$id" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID")
  expected_task_label="fm-$id"
  [ "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" = "$expected_label" ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" = "$expected_task_label" ]
}

journal_globals() {
  printf '%s|' "$FM_BACKEND_HERDR_JOURNAL_VERSION" "$FM_BACKEND_HERDR_JOURNAL_TASK_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" "$FM_BACKEND_HERDR_JOURNAL_HOME" \
    "$FM_BACKEND_HERDR_JOURNAL_SESSION" "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL"
}

compare_journal_readers() { # <case> <journal> <task-id>
  local name=$1 journal=$2 id=$3 want_rc got_rc want_globals got_globals
  oracle_journal_snapshot "$journal" "$id"; want_rc=$?
  want_globals=$(journal_globals)
  fm_backend_herdr_projection_journal_snapshot "$journal" "$id"; got_rc=$?
  got_globals=$(journal_globals)
  [ "$got_rc" = "$want_rc" ] || fail "journal reader disagrees on status for $name: oracle=$want_rc one-pass=$got_rc"
  [ "$got_globals" = "$want_globals" ] || fail "journal reader disagrees on fields for $name: oracle=$want_globals one-pass=$got_globals"
}

JOURNAL_CASES="$TMP_ROOT/journal-cases"
mkdir -p "$JOURNAL_CASES"
case_journal() { # <name> <task-id> then journal text on stdin
  cat > "$JOURNAL_CASES/$1"
  compare_journal_readers "$1" "$JOURNAL_CASES/$1" "$2"
}
V2_LINES=$(printf 'version=2\ntask_id=%s\nprojection_id=%s\nhome=%s\nsession=test\nworkspace_id=w2\ntab_id=w2:t1\npane_id=w2:p1\nparent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=%s\ntask_label=fm-%s\n' \
  "$ID" "$TOKEN" "$FM_HOME" "$TITLE" "$ID")
case_journal v1-valid "$ID" <<EOF
version=1
task_id=$ID
projection_id=$TOKEN
EOF
case_journal v2-valid "$ID" <<EOF
$V2_LINES
EOF
case_journal v1-wrong-id other <<EOF
version=1
task_id=$ID
projection_id=$TOKEN
EOF
case_journal v1-extra-line "$ID" <<EOF
version=1
task_id=$ID
projection_id=$TOKEN
note=x
EOF
case_journal v1-duplicate-key "$ID" <<EOF
version=1
task_id=$ID
task_id=$ID
projection_id=$TOKEN
EOF
case_journal v1-missing-key "$ID" <<EOF
version=1
projection_id=$TOKEN
EOF
case_journal v1-short-token "$ID" <<EOF
version=1
task_id=$ID
projection_id=short
EOF
case_journal v1-bad-token-char "$ID" <<EOF
version=1
task_id=$ID
projection_id=AbCdEfGhIjKlMnOpQrSt!!
EOF
case_journal v1-empty-value "$ID" <<EOF
version=1
task_id=
projection_id=$TOKEN
EOF
case_journal v1-value-with-equals "$ID" <<EOF
version=1
task_id=$ID
projection_id=$TOKEN=
EOF
printf 'version=1\ntask_id=%s\nprojection_id=%s' "$ID" "$TOKEN" > "$JOURNAL_CASES/v1-no-final-newline"
compare_journal_readers v1-no-final-newline "$JOURNAL_CASES/v1-no-final-newline" "$ID"
printf 'version=1\r\ntask_id=%s\r\nprojection_id=%s\r\n' "$ID" "$TOKEN" > "$JOURNAL_CASES/v1-crlf"
compare_journal_readers v1-crlf "$JOURNAL_CASES/v1-crlf" "$ID"
: > "$JOURNAL_CASES/empty"
compare_journal_readers empty "$JOURNAL_CASES/empty" "$ID"
compare_journal_readers absent "$JOURNAL_CASES/absent" "$ID"
ln -sf "$JOURNAL_CASES/v1-valid" "$JOURNAL_CASES/symlink"
compare_journal_readers symlink "$JOURNAL_CASES/symlink" "$ID"
printf '%s\n' "$V2_LINES" | sed 's/^session=test$/session=te st/' > "$JOURNAL_CASES/v2-space-in-session"
compare_journal_readers v2-space-in-session "$JOURNAL_CASES/v2-space-in-session" "$ID"
printf '%s\n' "$V2_LINES" | sed 's#^home=.*#home=relative/home#' > "$JOURNAL_CASES/v2-relative-home"
compare_journal_readers v2-relative-home "$JOURNAL_CASES/v2-relative-home" "$ID"
printf '%s\n' "$V2_LINES" | sed 's/^task_label=.*/task_label=fm-wrong/' > "$JOURNAL_CASES/v2-wrong-task-label"
compare_journal_readers v2-wrong-task-label "$JOURNAL_CASES/v2-wrong-task-label" "$ID"
printf '%s\n' "$V2_LINES" | sed 's/^parent_label=.*/parent_label=/' > "$JOURNAL_CASES/v2-empty-parent-label"
compare_journal_readers v2-empty-parent-label "$JOURNAL_CASES/v2-empty-parent-label" "$ID"
printf '%s\n' "$V2_LINES" | sed '/^pane_id=/d' > "$JOURNAL_CASES/v2-missing-pane"
compare_journal_readers v2-missing-pane "$JOURNAL_CASES/v2-missing-pane" "$ID"
pass "the one-pass journal reader agrees with the grep/cut oracle on every journal shape"

# Many stale journals, every candidate's topology ambiguous: nothing may be
# closed, the API is read once, and no journal costs a grep/cut/wc/basename.
COST_N=${FM_TEST_COST_JOURNALS:-30}
COST_REAL_HOME=$(cd "$FM_HOME" && pwd -P)
reset_fixture
rm -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation"
: > "$FIXTURE_DIR/bulk"
COST_WORKSPACES='{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1}'
i=1
while [ "$i" -le "$COST_N" ]; do
  cost_id="bulk-$i"
  cost_token=$(printf 'Bulk%018d' "$i")
  cost_title="└ $cost_id · p:$cost_token"
  {
    printf 'version=2\ntask_id=%s\nprojection_id=%s\nhome=%s\nsession=test\n' "$cost_id" "$cost_token" "$COST_REAL_HOME"
    printf 'workspace_id=wb%s\ntab_id=wb%s:t1\npane_id=wb%s:p1\n' "$i" "$i" "$i"
    printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=%s\ntask_label=fm-%s\n' "$cost_title" "$cost_id"
  } > "$FM_STATE_OVERRIDE/$cost_id.herdr-presentation"
  COST_WORKSPACES="$COST_WORKSPACES,{\"workspace_id\":\"wb$i\",\"label\":\"$cost_title\",\"focused\":false,\"active_tab_id\":\"wb$i:t1\",\"tab_count\":2,\"pane_count\":2}"
  i=$((i + 1))
done
printf '[%s]' "$COST_WORKSPACES" > "$FIXTURE_DIR/bulk-workspaces"
: > "$FIXTURE_DIR/api-calls"

COUNTBIN="$TMP_ROOT/countbin"
mkdir -p "$COUNTBIN"
FORK_LOG="$TMP_ROOT/forks.log"
: > "$FORK_LOG"
for tool in grep cut wc basename; do
  real_tool=$(command -v "$tool")
  printf '#!/bin/sh\necho %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$FORK_LOG" "$real_tool" > "$COUNTBIN/$tool"
  chmod +x "$COUNTBIN/$tool"
done
SAVED_PATH=$PATH
PATH="$COUNTBIN:$PATH"
cost_out=$(fm_herdr_session_cleanup 2>&1)
PATH=$SAVED_PATH

snapshot_calls=$(grep -c '^api snapshot$' "$FIXTURE_DIR/api-calls" || true)
total_calls=$(grep -c . "$FIXTURE_DIR/api-calls" || true)
journal_forks=$(grep -c . "$FORK_LOG" || true)
journals_left=$(find "$FM_STATE_OVERRIDE" -name 'bulk-*.herdr-presentation' | grep -c . || true)
printf '# cost: %s journals, %s api snapshot call(s), %s api call(s) in all, %s grep/cut/wc/basename process(es)\n' \
  "$COST_N" "$snapshot_calls" "$total_calls" "$journal_forks"
[ "$snapshot_calls" -eq 1 ] || fail "cleanup took $snapshot_calls API snapshots for $COST_N candidates instead of one"
[ "$total_calls" -le 2 ] || fail "cleanup made $total_calls API calls for candidates its one snapshot already ruled out"
[ "$journal_forks" -lt "$COST_N" ] || fail "journal parsing forked $journal_forks processes for $COST_N journals"
[ "$journals_left" -eq "$COST_N" ] || fail "cleanup retired journals of workspaces it never closed"
[ ! -s "$CLOSE_LOG" ] || fail "cleanup closed a pane whose topology was ambiguous"
assert_contains "$cost_out" "bulk-1 preserved because its candidate snapshot was ambiguous" \
  "a ruled-out candidate was not reported as preserved"
pass "cleanup reads the API once and forks nothing per journal for $COST_N ambiguous candidates"

# A spent budget defers a candidate that passed the prefilter on one reported
# line and closes nothing; the next start retries it.
reset_fixture
cost_out=$(FM_HERDR_CLEANUP_BUDGET=0 fm_herdr_session_cleanup 2>&1)
assert_contains "$cost_out" "deferred:" "a spent cleanup budget was not reported as deferred"
assert_contains "$cost_out" "1 candidate(s) not examined" "the deferred line did not count the unexamined candidate"
[ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "a deferred cleanup retired the journal"
[ ! -s "$CLOSE_LOG" ] || fail "a deferred cleanup closed a pane"
fm_herdr_session_cleanup >/dev/null 2>&1
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "the next cleanup did not finish the deferred candidate"
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "the deferred candidate was not closed exactly once by the next cleanup"
pass "a spent cleanup budget defers the candidate loudly and the next cleanup finishes it"

INTEGRATION_ROOT="$TMP_ROOT/bootstrap-integration"
mkdir -p "$INTEGRATION_ROOT/home/state" "$INTEGRATION_ROOT/home/data" "$INTEGRATION_ROOT/home/config"
cp -R "$ROOT/bin" "$INTEGRATION_ROOT/bin"
TRACE="$INTEGRATION_ROOT/cleanup.trace"
cat > "$INTEGRATION_ROOT/bin/fm-herdr-session-cleanup.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_HOME:?}" >> "${FM_HERDR_CLEANUP_TRACE:?}"
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-herdr-session-cleanup.sh"
printf '%s\n' manual > "$INTEGRATION_ROOT/home/config/backlog-backend"
FM_HOME="$INTEGRATION_ROOT/home" FM_HERDR_CLEANUP_TRACE="$TRACE" FM_BOOTSTRAP_DETECT_ONLY=1 \
  "$INTEGRATION_ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
[ ! -e "$TRACE" ] || fail "detect-only bootstrap ran stale projection cleanup"
FM_HOME="$INTEGRATION_ROOT/home" FM_HERDR_CLEANUP_TRACE="$TRACE" \
  "$INTEGRATION_ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
[ ! -e "$TRACE" ] || fail "standalone bootstrap ran lock-owned stale projection cleanup"
pass "standalone bootstrap cannot run lock-owned stale projection cleanup"

cat > "$INTEGRATION_ROOT/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'lock acquired'
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-lock.sh"
FM_HOME="$INTEGRATION_ROOT/home" FM_ROOT_OVERRIDE="$INTEGRATION_ROOT" \
  FM_HERDR_CLEANUP_TRACE="$TRACE" \
  "$INTEGRATION_ROOT/bin/fm-session-start.sh" >/dev/null 2>&1 \
  || fail "lock-owning session start failed"
[ "$(cat "$TRACE")" = "$INTEGRATION_ROOT/home" ] \
  || fail "lock-owning session start did not run cleanup for its exact home"

: > "$TRACE"
cat > "$INTEGRATION_ROOT/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'error: another live firstmate session holds the lock' >&2
exit 1
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-lock.sh"
FM_HOME="$INTEGRATION_ROOT/home" FM_ROOT_OVERRIDE="$INTEGRATION_ROOT" \
  FM_HERDR_CLEANUP_TRACE="$TRACE" \
  "$INTEGRATION_ROOT/bin/fm-session-start.sh" >/dev/null 2>&1 \
  || fail "read-only session start failed"
[ ! -s "$TRACE" ] || fail "read-only session start ran stale projection cleanup"
pass "session start runs cleanup only after acquiring its home lock"

printf 'all fm-herdr-session-cleanup tests passed\n'
