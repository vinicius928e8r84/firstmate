#!/usr/bin/env bash
# fm-close-finished-lanes.sh - close the lanes of ordinary tasks that are already finished, so
# finished work stops holding worker slots. A guarded step meant for a nightly cleanup routine.
#
# Usage: fm-close-finished-lanes.sh [--dry-run|--apply] [--max N] [--budget SECS] [--ttl SECS]
#   default --dry-run (reports what it would close); --apply closes.
#   --ttl SECS    a lane is closed only SECS after it ended - its newest status line's own time, else the
#                 status file's last write (default 21600 = 6 h, env FM_LANE_CLOSE_TTL; 0 turns the wait off).
#                 bin/fm-resil.sh runs this hourly with --apply --max 1: one lane at a time.
#   --max N       close at most N lanes per run (default 3, env FM_LANE_CLOSE_MAX)
#   --budget SECS stop before starting a teardown the remaining time cannot cover
#                 (default 900, env FM_LANE_CLOSE_BUDGET); one teardown is assumed to take
#                 FM_LANE_CLOSE_EST seconds (default 150) and is bounded by
#                 FM_LANE_CLOSE_TEARDOWN_TIMEOUT (default 1200).
#
# A lane is closed only when ALL hold; otherwise it is left alone and reported as
# `kept: <id> <reason>` (`skipped: <id> secondmate` for persistent secondmates, never touched):
#   - bin/fm-crew-state.sh reports its current state as done (a status log line is never trusted);
#   - a scout has its report at data/<id>/report.md; a ship has positive merged evidence: its recorded
#     pr= reads merged on the forge (open, closed or unreadable keeps it, so bin/fm-pr-merge.sh still has
#     its record), or - with no pr= recorded - its branch head is already on the project's local default branch;
#   - bin/fm-captain-hold.sh `open` says it is not an open captain call (0 and 2 both keep it) and
#     the status log folds to no open decision;
#   - its local copy has no uncommitted tracked or untracked change and its steering inbox holds no
#     unhandled message;
#   - no spawn for the same project is waiting for the project lock (a live state/.spawn-waiting/<id>
#     marker from bin/fm-spawn.sh): the close yields to it and is tried again on the next run.
# Before closing, the status log, the metadata and the logs under the recorded tasktmp are saved to
# data/<id>/archive-<date>/. Then bin/fm-teardown.sh runs WITHOUT --force: any refusal (unlanded work,
# uncommitted changes, unmerged PR or branch, a scout's unresolved-decision gate, a live endpoint)
# is reported as kept and never retried with force; the archive made for a refused lane is removed.
# Teardown takes the treehouse project lock itself; lanes are closed strictly one at a time under one
# run-wide lock (a second concurrent run exits 0 without doing anything).
#
# The budget also bounds the scan: tasks not yet checked when it runs out are kept.
# Output ends with `lanes: N closed, M kept, K skipped` (`would be closed` under --dry-run).
# Each close and each refusal by teardown is one line in state/.resil.log (bin/fm-resil-lib.sh).
# Env: FM_HOME; test seams FM_LANE_CLOSE_CREW_STATE_CMD, FM_LANE_CLOSE_TEARDOWN_CMD,
#   FM_LANE_CLOSE_HOLD_CMD, FM_LANE_CLOSE_PR_CMD <pr-url> (prints the state, exit 0 only when merged)
#   (each defaults to the sibling bin/ script).
# Exit: 0 (also when lanes were kept), 64 usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
DATA="$FM_HOME/data"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-resil-lib.sh
. "$SCRIPT_DIR/fm-resil-lib.sh"

apply=0
max=${FM_LANE_CLOSE_MAX:-3}
budget=${FM_LANE_CLOSE_BUDGET:-900}
ttl=${FM_LANE_CLOSE_TTL:-21600}
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --max) shift; max=${1:-} ;;
    --budget) shift; budget=${1:-} ;;
    --ttl) shift; ttl=${1:-} ;;
    *) echo "usage: $0 [--dry-run|--apply] [--max N] [--budget SECS] [--ttl SECS]" >&2; exit 64 ;;
  esac
  shift
done
case "$max" in ''|*[!0-9]*) echo "usage: $0: --max needs a number" >&2; exit 64 ;; esac
case "$budget" in ''|*[!0-9]*) echo "usage: $0: --budget needs a number" >&2; exit 64 ;; esac
case "$ttl" in ''|*[!0-9]*) echo "usage: $0: --ttl needs a number" >&2; exit 64 ;; esac
est=${FM_LANE_CLOSE_EST:-150}
td_timeout=${FM_LANE_CLOSE_TEARDOWN_TIMEOUT:-1200}
crew_state=${FM_LANE_CLOSE_CREW_STATE_CMD:-$SCRIPT_DIR/fm-crew-state.sh}
teardown=${FM_LANE_CLOSE_TEARDOWN_CMD:-$SCRIPT_DIR/fm-teardown.sh}
hold=${FM_LANE_CLOSE_HOLD_CMD:-$SCRIPT_DIR/fm-captain-hold.sh}
pr_cmd=${FM_LANE_CLOSE_PR_CMD:-}

mkdir -p "$STATE"
exec 8> "$STATE/.lane-close.lock"
flock -n 8 || { echo "lanes: another run holds the lock, nothing done"; exit 0; }

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Epoch the lane ended: its newest status line's own time, else the status file's last write, else 0.
lane_end_epoch() {  # <status-file>
  local f=$1 line at
  line=$(last_status_line "$f")
  if [ -n "$line" ] && at=$(status_line_at_epoch "$line") && [ -n "$at" ]; then printf '%s\n' "$at"; return; fi
  stat -c %Y "$f" 2>/dev/null || echo 0
}

# Print the id of a live spawn waiting on the project lock of <project>, and return 0; else return 1.
spawn_waiting_for() {  # <project>
  local m pid proj want
  want=$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")
  for m in "$STATE"/.spawn-waiting/*; do
    [ -f "$m" ] || continue
    pid=$(sed -n 's/^pid=//p' "$m" | head -n 1); proj=$(sed -n 's/^project=//p' "$m" | head -n 1)
    [ "$(readlink -f "$proj" 2>/dev/null || printf '%s' "$proj")" = "$want" ] || continue
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || continue
    basename "$m"; return 0
  done
  return 1
}

# Print the PR's state and exit 0 only when it is merged; anything unreadable prints unknown.
pr_state() {  # <pr-url>
  local out rc=1
  if [ -n "$pr_cmd" ]; then out=$("$pr_cmd" "$1" 2>/dev/null); rc=$?
  else out=$(fm_resil_pr_state "$1"); rc=$?
  fi
  printf '%s\n' "${out:-unknown}" | head -n1
  return "$rc"
}

# 0 when the ship has positive merged evidence; otherwise prints the keep reason and returns 1.
ship_merge_evidence() {  # <meta>
  local meta=$1 pr project wt default state
  pr=$(meta_value "$meta" pr)
  if [ -n "$pr" ]; then
    state=$(pr_state "$pr") && return 0
    echo "PR not merged (${state:-unknown})"; return 1
  fi
  project=$(meta_value "$meta" project); wt=$(meta_value "$meta" worktree)
  default=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); default=${default#origin/}
  if [ -z "$default" ]; then
    for default in main master; do git -C "$project" show-ref --verify --quiet "refs/heads/$default" && break; default=; done
  fi
  [ -n "$default" ] && [ -d "$wt" ] && git -C "$project" merge-base --is-ancestor "$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo none)" "refs/heads/$default" 2>/dev/null && return 0
  echo "no merged PR recorded and branch not on ${default:-the default branch}"; return 1
}

# Save status, metadata and tasktmp logs; echo the archive dir. Returns 1 when it already existed.
archive_copy() {  # <id> <meta> <dir>
  local id=$1 meta=$2 dir=$3 tmp f rel
  mkdir -p "$dir" || return 1
  if [ -f "$STATE/$id.status" ]; then cp -p "$STATE/$id.status" "$dir/status.log" || return 1; fi
  cp -p "$meta" "$dir/meta" || return 1
  tmp=$(meta_value "$meta" tasktmp)
  if [ -n "$tmp" ] && [ -d "$tmp" ]; then
    while IFS= read -r f; do
      rel=${f#"$tmp"/}
      mkdir -p "$dir/tasktmp/$(dirname "$rel")" && cp -p "$f" "$dir/tasktmp/$rel" || return 1
    done < <(find "$tmp" -maxdepth 3 -type f \( -name '*.log' -o -name '*.out' -o -name '*.txt' \) -size -5M 2>/dev/null)
  fi
}

archive_lane() {  # <id> <meta>
  local id=$1 meta=$2 dir created=0
  dir="$DATA/$id/archive-$(date -u +%Y%m%d)"
  [ -d "$dir" ] || created=1
  if ! archive_copy "$id" "$meta" "$dir"; then
    [ "$created" = 1 ] && rm -rf "$dir"
    return 2
  fi
  printf '%s\n' "$dir"
  [ "$created" = 1 ]
}

closed=0; kept=0; skipped=0; started=$(date +%s)
shopt -s nullglob
echo "== fm-close-finished-lanes $([ $apply = 1 ] && echo apply || echo dry-run) $(date -u +%FT%TZ)"
for meta in "$STATE"/*.meta; do
  id=$(basename "$meta" .meta)
  kind=$(meta_value "$meta" kind); [ -n "$kind" ] || kind=ship
  if [ "$kind" = secondmate ] || [ -n "$(meta_value "$meta" remote_host)" ]; then
    echo "skipped: $id secondmate"; skipped=$((skipped + 1)); continue
  fi
  if [ "$closed" -ge "$max" ]; then
    echo "kept: $id per-run cap of $max reached, not examined"; kept=$((kept + 1)); continue
  fi
  if [ $(( $(date +%s) - started + est )) -gt "$budget" ]; then
    echo "kept: $id time budget of ${budget}s reached before it was checked"; kept=$((kept + 1)); continue
  fi
  line=$("$crew_state" "$id" 2>/dev/null | head -n1)
  st=${line#state: }; st=${st%% *}
  if [ "$st" != "done" ]; then
    echo "kept: $id not finished (state: ${st:-unknown})"; kept=$((kept + 1)); continue
  fi
  if [ "$ttl" -gt 0 ]; then
    ended=$(lane_end_epoch "$STATE/$id.status"); age=$(( $(date +%s) - ended ))
    if [ "$age" -lt "$ttl" ]; then
      echo "kept: $id finished ${age}s ago, waits for its ${ttl}s quiet period"; kept=$((kept + 1)); continue
    fi
  fi
  if [ "$kind" = scout ]; then
    if [ ! -s "$DATA/$id/report.md" ]; then echo "kept: $id scout has no report"; kept=$((kept + 1)); continue; fi
  elif ! why=$(ship_merge_evidence "$meta"); then
    echo "kept: $id $why"; kept=$((kept + 1)); continue
  fi
  "$hold" open "$id" >/dev/null 2>&1; rc=$?
  if [ "$rc" != 1 ]; then
    echo "kept: $id $([ "$rc" = 0 ] && echo 'open captain hold' || echo 'captain hold state unknown')"; kept=$((kept + 1)); continue
  fi
  if [ -n "$(status_open_decisions "$STATE/$id.status" "$kind")" ]; then
    echo "kept: $id open decision in status log"; kept=$((kept + 1)); continue
  fi
  wt=$(meta_value "$meta" worktree)
  if [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    echo "kept: $id uncommitted changes in its local copy"; kept=$((kept + 1)); continue
  fi
  unhandled=0
  for f in "$STATE/$id.inbox/"*.msg; do unhandled=1; break; done
  if [ "$unhandled" = 1 ]; then
    echo "kept: $id unhandled steering message in its inbox"; kept=$((kept + 1)); continue
  fi
  if waiting=$(spawn_waiting_for "$(meta_value "$meta" project)"); then
    echo "kept: $id yields to the spawn of $waiting waiting for the same project"; kept=$((kept + 1)); continue
  fi
  if [ $(( $(date +%s) - started + est )) -gt "$budget" ]; then
    echo "kept: $id time budget of ${budget}s reached"; kept=$((kept + 1)); continue
  fi
  if [ $apply = 0 ]; then
    echo "would close: $id"; closed=$((closed + 1)); continue
  fi
  adir=$(archive_lane "$id" "$meta"); acreated=$?
  if [ -z "$adir" ] || [ "$acreated" = 2 ]; then
    echo "kept: $id could not save archive"; kept=$((kept + 1)); continue
  fi
  out=$(timeout -k 10 "$td_timeout" "$teardown" "$id" 2>&1); rc=$?
  printf '%s\n' "$out" > "$adir/teardown.log"
  if [ "$rc" = 0 ] || [ "$rc" = 4 ]; then
    echo "closed: $id (archive: $adir)$([ "$rc" = 4 ] && echo ' - pool slot lost, see archive teardown.log')"
    closed=$((closed + 1))
    fm_resil_log "$STATE" "$id" finished-lane close "closed (archive $adir)"
  else
    reason=$(printf '%s\n' "$out" | grep -m1 -E 'REFUSED|refus|ERROR|error' | cut -c1-200)
    if [ "$rc" = 124 ]; then
      echo "kept: $id teardown timed out after ${td_timeout}s - needs inspection (see $adir/teardown.log)"
    else
      echo "kept: $id teardown refused (exit $rc): ${reason:-no reason given}"
    fi
    kept=$((kept + 1))
    fm_resil_log "$STATE" "$id" finished-lane close "kept: teardown exit $rc ${reason:-}"
    if [ "$acreated" = 0 ] && [ "$rc" != 124 ] && [ -f "$meta" ]; then rm -rf "$adir"; rmdir "$DATA/$id" 2>/dev/null; fi
  fi
done
echo "lanes: $closed $([ $apply = 1 ] && echo closed || echo 'would be closed'), $kept kept, $skipped skipped"
exit 0
