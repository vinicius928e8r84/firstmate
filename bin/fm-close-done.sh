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

# is_candidate <id>: sets WHY to the reason it is not one; returns 0 when it is.
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
  return 0
}

# save_log <id>: scrollback to data/<id>/session-log-<epoch>.txt; sets LOG.
save_log() {
  local id=$1 dir="$DATA/$id" tmp
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
  if ! is_candidate "$id"; then
    if [ "$explicit" -eq 1 ]; then
      echo "skipped $id: $WHY"
      rc=1
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
