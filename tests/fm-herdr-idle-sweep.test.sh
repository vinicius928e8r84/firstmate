#!/usr/bin/env bash
# Behavior tests for `bin/fm-herdr-session-cleanup.sh --sweep-idle`, the periodic idle-terminal sweep bin/fm-host-sweep.sh runs.
# Herdr itself is a set of function stand-ins over a JSON fixture; nothing here talks to a real Herdr.
# Pins: a terminal goes only after being seen idle on every pass for the whole window, never while it holds an agent or a live
# task, never the focused or last pane, never on a failed proof; a simulation closes nothing; the close is confirmed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-idle-sweep)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$FM_HOME/state"
export FM_CONFIG_OVERRIDE="$FM_HOME/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
printf '%s\n' herdr > "$FM_CONFIG_OVERRIDE/backend"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_fake_exit0 "$FAKEBIN" herdr
export PATH="$FAKEBIN:$PATH"
export FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-session-cleanup.sh"
unset FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY

FIX="$TMP_ROOT/fixture"; mkdir -p "$FIX"
CLOSES="$FIX/closes.log"; : > "$CLOSES"
S="$FM_STATE_OVERRIDE"
# panes: p1 live task, p2 holds an agent, p3 idle orphan terminal, p4 busy shell, p5 focused idle shell, p6 pane of a finished task
printf '%s\n' w2:p1 w2:p2 w2:p3 w2:p4 w2:p5 w2:p6 > "$FIX/panes"
printf 'kind=ship\nherdr_session=sw\nherdr_pane_id=w2:p1\n' > "$S/live.meta"; echo "working [at=1]: x" > "$S/live.status"
printf 'kind=ship\nherdr_session=sw\nherdr_pane_id=w2:p6\n' > "$S/gone.meta"; echo "done [at=1]: x" > "$S/gone.status"

# shellcheck disable=SC2329 # invoked indirectly by the sweep
fm_backend_herdr_cli() {  # <session> pane list
  local panes
  panes=$(while IFS= read -r p; do
    [ -s "$FIX/closed-$p" ] && continue
    printf '{"pane_id":"%s","focused":%s%s}\n' "$p" "$([ "$p" = w2:p5 ] && echo true || echo false)" "$([ "$p" = w2:p2 ] && echo ',"agent":"claude"' || true)"
  done < "$FIX/panes" | paste -sd, -)
  printf '{"id":"x","result":{"type":"pane_list","panes":[%s]}}\n' "$panes"
}
# shellcheck disable=SC2329 # invoked indirectly by the sweep
fm_backend_herdr_pane_agent_state() { [ "$2" = w2:p2 ] && printf agent || printf no-agent; }
# shellcheck disable=SC2329 # invoked indirectly by the sweep
fm_backend_herdr_pane_idle_shell_pid() { [ "$2" = w2:p4 ] && return 1; printf '4%s\n' "${2##*p}"; }
# shellcheck disable=SC2329 # invoked indirectly by the sweep
fm_backend_herdr_projection_close_pane_focus_preserving() { echo "$2" >> "$CLOSES"; echo gone > "$FIX/closed-$2"; }
# shellcheck disable=SC2329 # invoked indirectly by the sweep
fm_backend_herdr_pane_presence_state() { [ -s "$FIX/closed-$2" ] && printf dead || printf present; }

T0=1000000
sweep() {  # now args...
  local now=$1; shift
  FM_HERDR_SWEEP_NOW=$now HERDR_SESSION='' fm_herdr_idle_sweep --session sw --meta-dir "$S" "$@"
}

# 1. first sighting: nothing closes, markers appear only for panes that qualify
OUT=$(sweep "$T0" --apply)
assert_not_contains "$OUT" "removed" "the first sighting closes nothing"
assert_contains "$OUT" "panes	kept	sw:w2:p3	0	idle shell first seen now" "an idle terminal starts its observation window"
assert_contains "$OUT" "pane of a live task" "a live task's pane is kept"
assert_contains "$OUT" "holds an agent" "a pane with an agent is kept"
assert_equals "" "$(cat "$CLOSES")" "nothing closed"
assert_present "$S/.sweep-idle-pane-sw@w2_p3" "the marker is written"
assert_absent "$S/.sweep-idle-pane-sw@w2_p1" "no marker for a live task's pane"
assert_absent "$S/.sweep-idle-pane-sw@w2_p4" "no marker for a busy shell"

# 2. inside the window: still kept
OUT=$(sweep $((T0 + 3600)) --apply)
assert_contains "$OUT" "idle for 60 min of 120" "the window has not elapsed"
assert_equals "" "$(cat "$CLOSES")" "nothing closed inside the window"

# 3. past the window, simulation: would, and nothing closes
OUT=$(sweep $((T0 + 3 * 3600)))
assert_contains "$OUT" "panes	would	sw:w2:p3" "an old idle terminal would close"
assert_contains "$OUT" "panes	would	sw:w2:p6" "the pane of a finished task would close"
assert_contains "$OUT" "the focused pane" "the focused pane is never closed"
assert_not_contains "$OUT" "would	sw:w2:p1" "a live task's pane is never offered"
assert_not_contains "$OUT" "would	sw:w2:p2" "an agent's pane is never offered"
assert_equals "" "$(cat "$CLOSES")" "a simulation closes nothing"

# 4. apply: exactly the proved panes close
OUT=$(sweep $((T0 + 3 * 3600)) --apply)
assert_contains "$OUT" "panes	removed	sw:w2:p3" "the idle terminal closes"
assert_equals "w2:p3
w2:p6" "$(sort "$CLOSES")" "only the two proved panes were closed"
assert_absent "$S/.sweep-idle-pane-sw@w2_p3" "the marker of a closed pane is dropped"

# 5. a shell that turns busy resets the clock
# shellcheck disable=SC2329 # invoked indirectly by the sweep
fm_backend_herdr_pane_idle_shell_pid() { printf '4%s\n' "${2##*p}"; }
sweep $((T0 + 4 * 3600)) --apply >/dev/null    # p4 is first seen idle now
# shellcheck disable=SC2329 # invoked indirectly by the sweep
fm_backend_herdr_pane_idle_shell_pid() { [ "$2" = w2:p4 ] && return 1; printf '4%s\n' "${2##*p}"; }
sweep $((T0 + 5 * 3600)) --apply >/dev/null    # busy again: the marker goes
assert_absent "$S/.sweep-idle-pane-sw@w2_p4" "a busy shell resets its observation"

# 6. an unreadable pane list closes nothing; bad usage is refused
# shellcheck disable=SC2329 # invoked indirectly by the sweep
fm_backend_herdr_cli() { return 1; }
OUT=$(sweep $((T0 + 9 * 3600)) --apply)
assert_contains "$OUT" "unreadable" "an unreadable list is reported"
assert_equals 2 "$(grep -c . "$CLOSES")" "nothing more closed"
fm_herdr_idle_sweep --bogus >/dev/null 2>&1; expect_code 64 "$?" "an unknown flag is a usage error"
pass "idle-terminal sweep: window, live-task, agent, focus and proof guards"
