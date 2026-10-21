#!/usr/bin/env bash
# tests/fm-hold.test.sh - state/HOLD, the one file that stops the fleet from starting work.
# bin/fm-hold.sh sets, clears and shows it; fm_hold_refuse (bin/fm-wake-lib.sh) is the single
# check that bin/fm-spawn.sh (fresh and --relaunch), bin/fm-control.sh relaunch and the watcher's
# secondmate auto-relaunch all call. Each refusal must exit 75 and name the file; an absent or
# expired HOLD must leave every path behaving as before.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-hold-tests)
HOLD="$ROOT/bin/fm-hold.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"
WATCH="$ROOT/bin/fm-watch.sh"

make_home() {  # <name> -> prints a scratch FM_HOME with state/ data/ config/
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

in_hold_lib() {  # <home> <shell snippet>: run a snippet with the production wake library loaded
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '. "$1"; shift; eval "$1"' _ "$ROOT/bin/fm-wake-lib.sh" "$2"
}

future() { echo $(( $(date +%s) + 3600 )); }
past() { echo $(( $(date +%s) - 3600 )); }

test_hold_cli_sets_shows_and_clears() {
  local home out rc
  home=$(make_home cli)
  out=$(FM_HOME="$home" "$HOLD" status 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "status with no HOLD should exit 1, got $rc: $out"
  out=$(FM_HOME="$home" "$HOLD" set --reason "captain stop order" --until "$(future)" 2>&1) || fail "set failed: $out"
  [ -f "$home/state/HOLD" ] || fail "set did not create state/HOLD"
  grep -qx 'reason=captain stop order' "$home/state/HOLD" || fail "reason line missing: $(cat "$home/state/HOLD")"
  grep -q '^until=[0-9][0-9]*$' "$home/state/HOLD" || fail "until line missing: $(cat "$home/state/HOLD")"
  out=$(FM_HOME="$home" "$HOLD" status 2>&1) || fail "status with a HOLD should exit 0: $out"
  case "$out" in *"captain stop order"*) ;; *) fail "status did not show the reason: $out" ;; esac
  FM_HOME="$home" "$HOLD" set --until 2099-01-01T00:00Z >/dev/null 2>&1 || fail "ISO until was rejected"
  grep -qx 'until=4070908800' "$home/state/HOLD" || fail "ISO until was not stored as an epoch: $(cat "$home/state/HOLD")"
  FM_HOME="$home" "$HOLD" set --until tomorrow >/dev/null 2>&1 && fail "a malformed until was accepted"
  FM_HOME="$home" "$HOLD" clear >/dev/null 2>&1 || fail "clear failed"
  [ ! -e "$home/state/HOLD" ] || fail "clear left state/HOLD behind"
  FM_HOME="$home" "$HOLD" bogus >/dev/null 2>&1 && fail "an unknown verb was accepted"
  pass "fm-hold.sh sets, shows and clears state/HOLD and rejects bad input"
}

test_hold_check_semantics() {
  local home
  home=$(make_home lib)
  in_hold_lib "$home" 'fm_hold_refuse spawn' 2>/dev/null || fail "no HOLD must not refuse"
  : > "$home/state/HOLD"
  in_hold_lib "$home" 'fm_hold_refuse spawn' 2>/dev/null && fail "an open-ended HOLD must refuse"
  printf 'until=%s\n' "$(future)" > "$home/state/HOLD"
  in_hold_lib "$home" 'fm_hold_refuse spawn' 2>/dev/null && fail "a future epoch until must refuse"
  printf 'until=%s\nreason=r\n' "$(past)" > "$home/state/HOLD"
  in_hold_lib "$home" 'fm_hold_refuse spawn' 2>/dev/null || fail "an expired epoch until must not refuse"
  printf 'until=2099-01-01T00:00:00Z\n' > "$home/state/HOLD"
  in_hold_lib "$home" 'fm_hold_refuse spawn' 2>/dev/null && fail "a future ISO until must refuse"
  printf 'until=2001-01-01T00:00Z\n' > "$home/state/HOLD"
  in_hold_lib "$home" 'fm_hold_refuse spawn' 2>/dev/null || fail "an expired ISO until must not refuse"
  printf 'until=not-a-time\n' > "$home/state/HOLD"
  in_hold_lib "$home" 'fm_hold_refuse spawn' 2>/dev/null && fail "an unparseable until must keep the HOLD in force"
  pass "the HOLD check honours open-ended, future and expired until times in both spellings"
}

test_spawn_refuses_under_hold() {
  local home out rc
  home=$(make_home spawn)
  printf 'reason=stop everything\n' > "$home/state/HOLD"
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$home" "$SPAWN" newtask /nonexistent/project brief.md 2>&1); rc=$?
  [ "$rc" -eq 75 ] || fail "a fresh spawn under HOLD should exit 75, got $rc: $out"
  case "$out" in *"$home/state/HOLD"*) ;; *) fail "the refusal did not name the file: $out" ;; esac
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$home" "$SPAWN" newtask --relaunch 2>&1); rc=$?
  [ "$rc" -eq 75 ] || fail "a --relaunch under HOLD should exit 75, got $rc: $out"
  case "$out" in *"$home/state/HOLD"*) ;; *) fail "the relaunch refusal did not name the file: $out" ;; esac
  rm -f "$home/state/HOLD"
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$home" "$SPAWN" newtask --relaunch 2>&1); rc=$?
  [ "$rc" -ne 75 ] || fail "with no HOLD a --relaunch still exited 75: $out"
  case "$out" in *HOLD*) fail "with no HOLD the spawn still mentioned HOLD: $out" ;; esac
  printf 'until=%s\n' "$(past)" > "$home/state/HOLD"
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$home" "$SPAWN" newtask /nonexistent/project brief.md 2>&1); rc=$?
  [ "$rc" -ne 75 ] || fail "with an expired HOLD a fresh spawn still exited 75: $out"
  pass "fm-spawn.sh refuses a fresh launch and --relaunch under HOLD and behaves as before without it"
}

test_control_relaunch_refuses_under_hold() {
  local home out rc
  home=$(make_home control)
  printf 'reason=stop everything\n' > "$home/state/HOLD"
  out=$(FM_HOME="$home" "$CONTROL" ghost relaunch 2>&1); rc=$?
  [ "$rc" -eq 75 ] || fail "relaunch under HOLD should exit 75, got $rc: $out"
  case "$out" in *"$home/state/HOLD"*) ;; *) fail "the refusal did not name the file: $out" ;; esac
  out=$(FM_HOME="$home" "$CONTROL" ghost interrupt 2>&1); rc=$?
  [ "$rc" -ne 75 ] || fail "HOLD must not block the interrupt verb: $out"
  rm -f "$home/state/HOLD"
  out=$(FM_HOME="$home" "$CONTROL" ghost relaunch 2>&1); rc=$?
  [ "$rc" -ne 75 ] || fail "with no HOLD relaunch still exited 75: $out"
  printf 'until=%s\n' "$(past)" > "$home/state/HOLD"
  out=$(FM_HOME="$home" "$CONTROL" ghost relaunch 2>&1); rc=$?
  [ "$rc" -ne 75 ] || fail "with an expired HOLD relaunch still exited 75: $out"
  pass "fm-control.sh relaunch refuses under HOLD, leaves other verbs alone, and behaves as before without it"
}

# A scratch home with one dead secondmate endpoint, a fixture code root whose fm-spawn.sh is a
# logging stub, and a fake tmux that reports an idle shell (a dead agent) in the mate's window.
make_dead_mate_world() {  # <name>
  local w="$TMP_ROOT/$1" mate="$TMP_ROOT/$1/sm1" f
  mkdir -p "$w/home/state" "$w/home/config" "$w/home/data" "$w/root/bin" "$w/fakebin" "$mate/data" "$mate/state" "$mate/config"
  touch "$w/home/state/.last-watcher-beat"
  printf 'claude\n' > "$w/home/config/crew-harness"
  printf 'sm1\n' > "$mate/.fm-secondmate-home"
  git -C "$mate" init -q -b main
  printf 'window=firstmate:fm-sm1\nkind=secondmate\nharness=claude\nhome=%s\n' "$mate" > "$w/home/state/sm1.meta"
  for f in "$ROOT"/bin/*; do
    [ "${f##*/}" = fm-spawn.sh ] || ln -s "$f" "$w/root/bin/${f##*/}"
  done
  cat > "$w/root/bin/fm-spawn.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$w/spawn.calls"
exit 0
SH
  chmod +x "$w/root/bin/fm-spawn.sh"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) for a in "$@"; do case "$a" in *pane_current_command*) echo zsh; exit 0 ;; esac; done ;;
  list-windows) echo fm-sm1; exit 0 ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$w/fakebin/tmux"
  printf '%s\n' "$w"
}

run_tick() {  # <world> -> runs the watcher until it wakes or logs a held relaunch; prints nothing
  local w=$1 pid i=0 settle_from=''
  PATH="$w/fakebin:$PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" \
    FM_ROOT_OVERRIDE="$w/root" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=1 FM_SECONDMATE_LIVENESS_TIMEOUT=20 \
    "$WATCH" > "$w/watch.out" 2> "$w/watch.err" &
  pid=$!
  while [ "$i" -lt 900 ]; do
    kill -0 "$pid" 2>/dev/null || break
    grep -q 'relaunch held by' "$w/home/state/.watch-triage.log" 2>/dev/null && break
    # the tick marker is touched first; a tick that neither held nor woke is done a while later
    if [ -e "$w/home/state/.secondmate-liveness-tick" ]; then
      [ -n "${settle_from:-}" ] || settle_from=$i
      [ $((i - settle_from)) -lt 100 ] || break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 0
}

test_watcher_auto_relaunch_refuses_under_hold() {
  local w
  w=$(make_dead_mate_world tick-hold)
  printf 'reason=stop everything\n' > "$w/home/state/HOLD"
  run_tick "$w"
  grep -q 'relaunch held by' "$w/home/state/.watch-triage.log" 2>/dev/null \
    || fail "the watcher did not log the held relaunch: $(cat "$w/watch.out" "$w/watch.err" 2>/dev/null)"
  [ ! -e "$w/spawn.calls" ] || fail "the watcher relaunched a secondmate under HOLD: $(cat "$w/spawn.calls")"
  [ ! -e "$w/home/state/.secondmate-relaunch-sm1" ] || fail "the held relaunch still wrote an attempt row"
  [ ! -s "$w/watch.out" ] || fail "the held relaunch woke the model: $(cat "$w/watch.out")"
  pass "the watcher's secondmate auto-relaunch makes no attempt and no wake under HOLD"
}

test_watcher_auto_relaunch_runs_without_hold() {
  local w
  w=$(make_dead_mate_world tick-free)
  run_tick "$w"
  [ -s "$w/spawn.calls" ] || fail "with no HOLD the watcher did not relaunch the dead secondmate: $(cat "$w/watch.out" "$w/watch.err" 2>/dev/null)"
  grep -q 'sm1 --secondmate' "$w/spawn.calls" || fail "unexpected relaunch command: $(cat "$w/spawn.calls")"
  rm -rf "$TMP_ROOT/tick-expired"
  w=$(make_dead_mate_world tick-expired)
  printf 'until=%s\n' "$(past)" > "$w/home/state/HOLD"
  run_tick "$w"
  [ -s "$w/spawn.calls" ] || fail "with an expired HOLD the watcher did not relaunch the dead secondmate"
  pass "the watcher's secondmate auto-relaunch behaves as before with no HOLD or an expired one"
}

test_existing_relaunch_bound_marker_still_parks() {
  local w
  w=$(make_dead_mate_world tick-bound)
  printf '1\tdead\n' > "$w/home/state/.secondmate-relaunch-bound-sm1"
  run_tick "$w"
  [ ! -e "$w/spawn.calls" ] || fail "a parked mate was relaunched despite its bound marker"
  pass "an existing .secondmate-relaunch-bound marker keeps parking auto-relaunch"
}

test_hold_cli_sets_shows_and_clears
test_hold_check_semantics
test_spawn_refuses_under_hold
test_control_relaunch_refuses_under_hold
test_watcher_auto_relaunch_refuses_under_hold
test_watcher_auto_relaunch_runs_without_hold
test_existing_relaunch_bound_marker_still_parks
