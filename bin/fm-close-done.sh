#!/usr/bin/env bash
# fm-close-done.sh - list the workers that reported done but still hold an open
# agent session, and close them one at a time.
#
# Usage: fm-close-done.sh [--close] [<task-id>...]
#
# A worker that delivered keeps its agent process, and the memory behind it,
# until someone stops it; a fleet of finished sessions filled the swap and
# starved the supervision watcher (captain's fleet rule 3). This is the small
# guarded step that closes them in the same supervision cycle as the `done`.
#
# Without --close it only lists. A candidate is a ship or scout task in THIS
# home (never a secondmate, which is persistent, and never a remote task) whose
# current state, read through bin/fm-crew-state.sh, is `done` and whose recorded
# endpoint still shows a live agent. With explicit task ids only those are
# considered; each is reported as skipped when it is not a candidate.
#
# With --close, each candidate in turn (the next starts only after the previous
# one is confirmed closed; the first failure stops the run):
#   1. saves the endpoint's scrollback to data/<id>/session-log-<epoch>.txt
#      (mode 0600), and skips the worker when no log could be saved;
#   2. confirms nothing unmerged would be lost: a ship's worktree must have no
#      tracked or untracked changes and a scout's report must exist (the
#      `done` state itself already required the named head to be reachable
#      outside the worker's disposable copy, bin/fm-dod-lib.sh);
#   3. closes the agent through `bin/fm-control.sh <id> exit`, the control
#      plane's verified stop. That verb preserves the endpoint, worktree, and
#      every change; there is no force path here, and nothing is deleted, so
#      cleanup (bin/fm-teardown.sh) stays a separate, later step.
#
# A `done` only counts when it belongs to the CURRENT agent: the status log's last
# `done [at=<epoch>]` line must be later than this incarnation's spawn_gen
# (bin/fm-spawn.sh stamps a fresh one on every spawn and relaunch). Otherwise the
# previous round's `done` would close a relaunched worker that has delivered
# nothing yet. A task held for the captain (bin/fm-captain-hold.sh open), one
# whose hold cannot be read, and one with a keyed needs-decision or blocked line
# that no `resolved` line has closed are never closed either, because the
# captain's review may send the same worker back.
#
# A closed worker keeps its worktree and task record, so `bin/fm-control.sh <id>
# relaunch` can bring an agent back if the work needs another round.
#
# Output is one line per worker: `candidate`, `closed`, or `skipped` followed by
# the task id and the reason or log path. Exit 0 when every candidate was closed
# or there was none, 1 when a worker was skipped or a close failed, 2 on usage
# or a missing FM_HOME.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-close-done refuses to resolve workers without an explicit firstmate home" >&2
  exit 2
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 2; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 2; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

CLOSE=0
IDS=()
for arg in "$@"; do
  case "$arg" in
    --close) CLOSE=1 ;;
    -*) echo "usage: fm-close-done.sh [--close] [<task-id>...]" >&2; exit 2 ;;
    *) IDS+=("$arg") ;;
  esac
done

explicit=0
[ "${#IDS[@]}" -eq 0 ] || explicit=1
if [ "${#IDS[@]}" -eq 0 ]; then
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    IDS+=("${id%.meta}")
  done
fi

rc=0

# done_at <id>: the [at=] epoch of the status log's last done line; "none" for a
# done line without one, empty when there is no done line.
done_at() {
  awk '
    $1 == "done" || $1 == "done:" {
      if (match($0, /\[at=[0-9]+\]/)) at = substr($0, RSTART + 4, RLENGTH - 5)
      else at = "none"
    }
    END { print at }
  ' "$STATE/$1.status" 2>/dev/null
}

# open_decision_keys <id>: keyed needs-decision/blocked lines no resolved line closed.
open_decision_keys() {
  awk '
    function key(line) { if (match(line, /\[key=[^]]+\]/)) return substr(line, RSTART + 5, RLENGTH - 6); return "" }
    $1 ~ /^(needs-decision|blocked)/ { k = key($0); if (k != "") open[k] = 1 }
    $1 ~ /^resolved/ { k = key($0); if (k != "") delete open[k] }
    END { for (k in open) printf "%s ", k }
  ' "$STATE/$1.status" 2>/dev/null
}

# is_candidate <id>: sets WHY to the reason it is not one; returns 0 when it is.
# Sets SURFACE once the task is known to be done with an open agent, so the
# caller reports a refusal after that point even for a task nobody named.
# Sets META, BACKEND, TARGET, KIND, WT on success.
is_candidate() {
  local id=$1 state_line
  META="$STATE/$id.meta"
  [ -f "$META" ] || { WHY="no task record"; return 1; }
  KIND=$(fm_meta_get "$META" kind); [ -n "$KIND" ] || KIND=ship
  [ "$KIND" != secondmate ] || { WHY="secondmate (persistent)"; return 1; }
  [ -z "$(fm_meta_get "$META" remote_host)" ] || { WHY="remote task"; return 1; }
  state_line=$("$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | head -1)
  case "$state_line" in
    "state: done"*) ;;
    *) WHY="not done (${state_line%% ·*})"; return 1 ;;
  esac
  fm_backend_validate_task_endpoint "$META" "$id" >/dev/null 2>&1 || { WHY="endpoint record invalid"; return 1; }
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  TARGET=$FM_BACKEND_VALIDATED_TARGET
  WT=$(fm_meta_get "$META" worktree)
  [ "$(fm_backend_agent_state "$BACKEND" "$TARGET")" = alive ] || { WHY="agent already closed"; return 1; }
  SURFACE=1
  spawn_gen=$(fm_meta_get "$META" spawn_gen)
  spawned_at=${spawn_gen#s}
  spawned_at=${spawned_at%%.*}
  case "$spawned_at" in ''|*[!0-9]*) WHY="the task record has no spawn time to compare the done against"; return 1 ;; esac
  reported_at=$(done_at "$id")
  case "$reported_at" in
    '') WHY="the status log has no done line"; return 1 ;;
    *[!0-9]*) WHY="its done line has no [at=] time, so it cannot be shown to postdate this agent"; return 1 ;;
  esac
  [ "$reported_at" -gt "$spawned_at" ] || { WHY="its done predates this agent (done at $reported_at, agent spawned at $spawned_at); it was relaunched since"; return 1; }
  open_keys=$(open_decision_keys "$id")
  [ -z "$open_keys" ] || { WHY="decision [key=${open_keys% }] has no resolved line"; return 1; }
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" --distinguish-absent >/dev/null 2>&1
  case $? in
    0) WHY="held for the captain's review"; return 1 ;;
    1|3) ;;
    *) WHY="could not tell whether it is held for the captain"; return 1 ;;
  esac
  return 0
}

# save_log <id>: scrollback to data/<id>/session-log-<epoch>.txt; sets LOG.
save_log() {
  local id=$1 tmp dir
  dir="$DATA/$id"
  LOG="$dir/session-log-$(date +%s).txt"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "$dir/.session-log.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  if fm_backend_capture "$BACKEND" "$TARGET" 5000 "fm-$1" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$LOG"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# nothing_unmerged_lost <id>: sets WHY when closing could lose work.
nothing_unmerged_lost() {
  local id=$1
  if [ "$KIND" = scout ]; then
    [ -s "$DATA/$id/report.md" ] || { WHY="scout report data/$id/report.md is missing"; return 1; }
    return 0
  fi
  [ -d "$WT" ] || { WHY="worktree is gone"; return 1; }
  if [ -n "$(git -C "$WT" status --porcelain --untracked-files=all 2>/dev/null)" ] \
    || ! git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
    WHY="worktree has uncommitted or untracked changes (or is unreadable)"
    return 1
  fi
  return 0
}

for id in "${IDS[@]}"; do
  WHY=
  SURFACE=0
  if ! is_candidate "$id"; then
    # A worker that is not done is none of this command's business unless it was
    # named; a done worker that must stay open is reported either way, because
    # it is the one a supervisor would otherwise expect to see closed.
    if [ "$explicit" -eq 1 ] || [ "$SURFACE" -eq 1 ]; then
      echo "skipped $id: $WHY"
      if [ "$explicit" -eq 1 ] || [ "$CLOSE" -eq 1 ]; then rc=1; fi
    fi
    continue
  fi
  if [ "$CLOSE" -eq 0 ]; then
    echo "candidate $id: done with an open agent on $BACKEND"
    continue
  fi
  if ! save_log "$id"; then
    echo "skipped $id: could not save the session log first"
    rc=1
    continue
  fi
  if ! nothing_unmerged_lost "$id"; then
    echo "skipped $id: $WHY (log saved at $LOG)"
    rc=1
    continue
  fi
  if "$SCRIPT_DIR/fm-control.sh" "$id" exit >/dev/null 2>"$STATE/.close-done.$$.err"; then
    echo "closed $id (log $LOG)"
    rm -f "$STATE/.close-done.$$.err"
  else
    echo "failed $id: fm-control exit refused: $(head -c 300 "$STATE/.close-done.$$.err" | tr '\n' ' ')"
    rm -f "$STATE/.close-done.$$.err"
    exit 1
  fi
done
exit "$rc"
