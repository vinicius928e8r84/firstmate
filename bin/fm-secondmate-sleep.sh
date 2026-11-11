#!/usr/bin/env bash
# fm-secondmate-sleep.sh - let a persistent LOCAL secondmate close while it has
# no work, and reopen it when work arrives.
#
# An idle secondmate still costs tokens: every keepalive and every supervision
# notice wakes the model with its whole context. A mate that is asleep has no
# process at all; its home (backlog, charter, records) stays on disk, so
# reopening costs a fresh context instead of a long one.
#
# Usage:
#   fm-secondmate-sleep.sh sleep <id>   close <id> if it is provably idle, then mark it asleep
#   fm-secondmate-sleep.sh wake <id>    reopen <id> (first launch for a seeded mate never launched) and clear the mark
#   fm-secondmate-sleep.sh sweep        sleep every idle opted-in mate; wake every sleeping mate that has work
#   fm-secondmate-sleep.sh status [id]  one line per marked or opted-in mate: <id> asleep|awake|never-launched [opted-in]
#
# Opt-in (config/secondmate-sleep, gitignored): one mate id per line, or `*`
# for every local secondmate; # starts a comment. An absent file means no mate
# is slept by the sweep. `sleep <id>` and `wake <id>` work on any local mate.
# Undo: delete the file (nothing is slept any more) and run `wake <id>` for
# each mate still marked asleep; or retire the mate (bin/fm-teardown.sh).
#
# The mark is state/<id>.asleep (one epoch line). While it exists and the mate's
# endpoint is dead or gone, the liveness probe reports `asleep` and neither the
# session-start sweep nor the watcher tick relaunches it
# (bin/fm-secondmate-liveness-lib.sh). A mate that is alive despite the mark is
# treated as awake and the sweep clears the mark.
#
# A mate is idle, and only then slept, when ALL hold:
#   - its home holds no state/*.meta (no crewmate of its own is in flight)
#   - its backlog has no queued or in-flight item that is not held for the captain
#   - no parent request to it is unresolved and its steering inbox holds no message
#   - its recorded busy state reads `idle` (anything else, including unknown, refuses)
#   - nothing it owns changed in the last FM_SECONDMATE_SLEEP_IDLE_SECS (default 1800)
# The agent is stopped with bin/fm-control.sh exit, which verifies the stop.
# Routing wakes it: bin/fm-send.sh calls `wake` before it delivers to a marked
# mate, so a steer or a backlog handoff reopens it with nothing else to do.
# The sweep is the backstop for work that arrived without a send (a backlog
# item written into a marked mate's home, an unread inbox message).
#
# Exit: 0 ok, 1 error, 2 usage, 3 refused (not idle / not a local secondmate).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
fm_sm_live_require_locks || exit 1

CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
OPT_IN_FILE="$CONFIG_DIR/secondmate-sleep"
IDLE_SECS=${FM_SECONDMATE_SLEEP_IDLE_SECS:-}
case "$IDLE_SECS" in ''|*[!0-9]*) IDLE_SECS=1800 ;; esac

usage() {
  echo "usage: fm-secondmate-sleep.sh sleep <id> | wake <id> | sweep | status [id]" >&2
  exit 2
}

valid_id() { case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

marker_of() { printf '%s/%s.asleep\n' "$STATE" "$1"; }

opted_in() {  # <id>
  local line
  [ -f "$OPT_IN_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    [ -n "$line" ] || continue
    [ "$line" = '*' ] || [ "$line" = "$1" ] && return 0
  done < "$OPT_IN_FILE"
  return 1
}

# The mate's home: its task record first, the registry for a seeded mate that was never launched.
home_of() {  # <id>
  local h
  h=$(fm_meta_get "$STATE/$1.meta" home)
  [ -n "$h" ] || h=$(secondmate_registry_field "$DATA_DIR/secondmates.md" "$1" home 2>/dev/null || true)
  [ -n "$h" ] && [ -d "$h" ] || return 1
  printf '%s\n' "$h"
}

# Queued or in-flight backlog items that are not held for the captain.
open_backlog_items() {  # <home>
  local backlog="$1/data/backlog.md"
  [ -f "$backlog" ] || { printf '0\n'; return 0; }
  awk '/^- \[ \] / && !/\(hold: / { n++ } END { print n + 0 }' "$backlog"
}

unread_inbox_messages() {  # <id>
  local n=0 f
  for f in "$STATE/$1.inbox"/*.msg; do
    [ -e "$f" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

unresolved_requests() {  # <id>
  local rec n=0
  for rec in "$STATE/pending-replies"/*; do
    [ -f "$rec" ] || continue
    [ "$(fm_meta_get "$rec" task_id)" = "$1" ] || continue
    [ "$(fm_meta_get "$rec" phase)" = resolved ] || n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Seconds since anything the mate owns last changed.
quiet_secs() {  # <id> <home>
  local id=$1 home=$2 best=999999 p age
  for p in "$STATE/$id.busy-state" "$STATE/$id.status" "$STATE/$id.inbox" \
    "$home/data/backlog.md" "$home/state" "$home/state/.wake-queue"; do
    [ -e "$p" ] || continue
    age=$(fm_path_age "$p")
    [ "$age" -ge "$best" ] || best=$age
  done
  printf '%s\n' "$best"
}

# Prints the reason and returns 1 when the mate is not provably idle. `owned`
# checks only the work the home holds; the full check adds the busy state and
# the quiet time, which mean nothing for an endpoint that is already stopped.
idle_check() {  # <id> <home> <owned|full>
  local id=$1 home=$2 depth=$3 n busy quiet f
  n=0
  for f in "$home/state"/*.meta; do [ -e "$f" ] && n=$((n + 1)); done
  [ "$n" -eq 0 ] || { echo "it has $n crewmate record(s) in flight"; return 1; }
  n=$(open_backlog_items "$home")
  [ "$n" -eq 0 ] || { echo "its backlog has $n open item(s)"; return 1; }
  n=$(unresolved_requests "$id")
  [ "$n" -eq 0 ] || { echo "$n request(s) to it are unresolved"; return 1; }
  n=$(unread_inbox_messages "$id")
  [ "$n" -eq 0 ] || { echo "its steering inbox holds $n message(s)"; return 1; }
  [ "$depth" = full ] || return 0
  busy=$(fm_busy_record_read "$STATE" "$id" 2>/dev/null | awk '{ print $1 }')
  [ "$busy" = idle ] || { echo "its busy state reads '${busy:-unreadable}', not idle"; return 1; }
  quiet=$(quiet_secs "$id" "$home")
  [ "$quiet" -ge "$IDLE_SECS" ] || { echo "it changed ${quiet}s ago (needs ${IDLE_SECS}s of quiet)"; return 1; }
  return 0
}

# Takes the per-mate liveness lock, waiting briefly: the watcher tick holds it
# for a moment while it probes.
lock_mate() {  # <id>
  local tries=0
  until fm_secondmate_liveness_lock "$1"; do
    tries=$((tries + 1))
    [ "$tries" -le 60 ] || { echo "error: another liveness check still holds secondmate $1" >&2; return 1; }
    sleep 1
  done
}

cmd_sleep() {  # <id>
  local id=$1 meta="$STATE/$1.meta" home reason rc=0 out
  valid_id "$id" || usage
  [ -f "$meta" ] && [ "$(fm_meta_get "$meta" kind)" = secondmate ] \
    || { echo "refused: $id is not a launched secondmate of this home" >&2; return 3; }
  [ -z "$(fm_meta_get "$meta" remote_host)" ] \
    || { echo "refused: $id runs on a remote host; only local secondmates sleep" >&2; return 3; }
  home=$(home_of "$id") || { echo "error: cannot resolve the home of $id" >&2; return 1; }
  lock_mate "$id" || return 1
  fm_secondmate_liveness_probe "$meta" "$id" poll
  case "$FM_SM_LIVE_STATUS" in
    alive)
      if ! reason=$(idle_check "$id" "$home" full); then
        fm_secondmate_liveness_unlock "$id"
        echo "refused: $id stays awake: $reason" >&2
        return 3
      fi
      if ! out=$("$SCRIPT_DIR/fm-control.sh" "$id" exit 2>&1); then
        fm_secondmate_liveness_unlock "$id"
        echo "error: could not stop $id: $(printf '%s\n' "$out" | tail -1)" >&2
        return 1
      fi
      ;;
    relaunchable | asleep)
      if ! reason=$(idle_check "$id" "$home" owned); then
        fm_secondmate_liveness_unlock "$id"
        echo "refused: $id stays marked awake: $reason" >&2
        return 3
      fi
      ;;
    *)
      fm_secondmate_liveness_unlock "$id"
      echo "refused: $id endpoint state is ${FM_SM_LIVE_STATE:-unknown}; ${FM_SM_LIVE_REASON:-not provably stopped}" >&2
      return 3
      ;;
  esac
  date +%s > "$(marker_of "$id")" || rc=1
  fm_secondmate_liveness_unlock "$id"
  [ "$rc" -eq 0 ] || { echo "error: could not write $(marker_of "$id")" >&2; return 1; }
  echo "$id asleep"
}

cmd_wake() {  # <id>
  local id=$1 meta="$STATE/$1.meta" marker rc=0 out
  valid_id "$id" || usage
  marker=$(marker_of "$id")
  [ -e "$marker" ] || [ -L "$marker" ] || { echo "$id already awake"; return 0; }
  lock_mate "$id" || return 1
  if [ ! -f "$meta" ]; then
    # Seeded but never launched: the first launch is the wake.
    out=$("$SCRIPT_DIR/fm-spawn.sh" "$id" --secondmate 2>&1) || rc=$?
  else
    FM_SM_LIVE_IGNORE_ASLEEP=1 fm_secondmate_liveness_probe "$meta" "$id" poll
    case "$FM_SM_LIVE_STATUS" in
      alive) ;;
      relaunchable)
        fm_secondmate_liveness_relaunch "$meta" "$id" "${FM_SECONDMATE_SLEEP_WAKE_TIMEOUT:-120}" || rc=$?
        out=$FM_SM_LIVE_OUT
        [ "$FM_SM_LIVE_STATUS" != skipped ] || out=$FM_SM_LIVE_REASON
        ;;
      *) rc=1; out="endpoint state ${FM_SM_LIVE_STATE:-unknown}: ${FM_SM_LIVE_REASON:-not relaunchable}" ;;
    esac
  fi
  if [ "$rc" -ne 0 ]; then
    fm_secondmate_liveness_unlock "$id"
    echo "error: could not wake $id: $(printf '%s\n' "${out:-}" | tail -1)" >&2
    return 1
  fi
  rm -f "$marker"
  # A wake is not a crash: keep it out of the watcher's relaunch bound.
  fm_secondmate_liveness_ledger_add "$id" rearmed || true
  fm_secondmate_liveness_unlock "$id"
  echo "$id awake"
}

cmd_sweep() {
  local meta marker id home rc=0 n
  # Sleeping mates that have work wake first, so a routed item never waits on the idle clock.
  for marker in "$STATE"/*.asleep; do
    [ -e "$marker" ] || continue
    id=${marker##*/}; id=${id%.asleep}
    valid_id "$id" || continue
    home=$(home_of "$id") || continue
    n=$(( $(open_backlog_items "$home") + $(unread_inbox_messages "$id") ))
    [ "$n" -gt 0 ] || continue
    cmd_wake "$id" || rc=1
  done
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
    id=${meta##*/}; id=${id%.meta}
    valid_id "$id" || continue
    opted_in "$id" || continue
    marker=$(marker_of "$id")
    if [ -e "$marker" ]; then
      # Alive despite the mark: someone reopened it by hand, so it is awake.
      fm_secondmate_liveness_probe "$meta" "$id" poll
      [ "$FM_SM_LIVE_STATUS" != alive ] || rm -f "$marker"
      continue
    fi
    cmd_sleep "$id" >/dev/null 2>&1 || true
  done
  return "$rc"
}

cmd_status() {  # [id]
  local id state meta marker
  for marker in "$STATE"/*.asleep; do
    [ -e "$marker" ] || continue
    id=${marker##*/}; id=${id%.asleep}
    [ -z "${1:-}" ] || [ "$1" = "$id" ] || continue
    state=asleep; [ -f "$STATE/$id.meta" ] || state=never-launched
    printf '%s %s%s\n' "$id" "$state" "$(opted_in "$id" && echo ' opted-in')"
  done
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
    id=${meta##*/}; id=${id%.meta}
    [ -z "${1:-}" ] || [ "$1" = "$id" ] || continue
    [ ! -e "$(marker_of "$id")" ] || continue
    printf '%s awake%s\n' "$id" "$(opted_in "$id" && echo ' opted-in')"
  done
  return 0
}

CMD=${1:-}
shift 2>/dev/null || true
case "$CMD" in
  sleep) [ $# -eq 1 ] || usage; cmd_sleep "$1" ;;
  wake) [ $# -eq 1 ] || usage; cmd_wake "$1" ;;
  sweep) [ $# -eq 0 ] || usage; cmd_sweep ;;
  status) [ $# -le 1 ] || usage; cmd_status "${1:-}" ;;
  *) usage ;;
esac
