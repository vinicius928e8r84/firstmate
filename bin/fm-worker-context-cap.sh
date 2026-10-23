#!/usr/bin/env bash
# Context cap for Pi workers of named projects.
#
# A worker session re-reads its whole context on every model call, so a long run
# pays for a large context hundreds of times. Pi compacts automatically once the
# context passes the model's window minus compaction.reserveTokens, which is how
# the primary session is capped at 250K on a 1M window. This helper computes the
# worker-side equivalent for one (project, model) pair, from
# $FM_CONFIG/worker-context-cap, and prints the project-level Pi settings file
# bin/fm-spawn.sh installs in the worker's worktree. Nothing is printed, and
# nothing is capped, for a pair the file does not name, so a model with a smaller
# window can never be handed a reserve that exceeds it.
#
#   fm-worker-context-cap.sh settings <project> <model> <task-id>
#       Print the settings JSON for a listed pair, or nothing (exit 0).
#
# Config: one entry per line, fields separated by blanks, # starts a comment:
#   <project> <cap-tokens> <model-id> <window-tokens>
#   modo-caverna 250000 claude-opus-5-5 1000000
# <project> is the registered project name (the directory under projects/),
# <model-id> is the model without its provider prefix, <window-tokens> is the
# model's context window as `pi --list-models` reports it, in tokens. Compaction
# then triggers near <cap-tokens>: reserveTokens = window - cap, and the
# window must exceed the cap by at least 100000 tokens or the entry is ignored.
# The generated file carries "firstmateWorkerContextCap": "<task-id>", the marker
# bin/fm-control-lib.sh uses to retire only the file firstmate wrote.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME_DIR="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CONFIG_FILE="${FM_CONFIG_OVERRIDE:-$FM_HOME_DIR/config}/worker-context-cap"
KEEP_RECENT_TOKENS=40000
MIN_HEADROOM=100000

usage() {
  echo "usage: fm-worker-context-cap.sh settings <project> <model> <task-id>" >&2
  exit 2
}

[ "$#" -eq 4 ] && [ "$1" = settings ] || usage
project=$2
model=${3##*/}
task=$4
case "$task" in ''|*[!A-Za-z0-9._-]*) echo "fm-worker-context-cap: invalid task id" >&2; exit 2 ;; esac
[ -f "$CONFIG_FILE" ] || exit 0

entry=$(awk -v p="$project" -v m="$model" '
  { sub(/#.*/, "") }
  NF >= 4 && $1 == p && $3 == m && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { print $2, $4; exit }
' "$CONFIG_FILE")
[ -n "$entry" ] || exit 0
cap=${entry% *}
window=${entry#* }
[ "$((window - cap))" -ge "$MIN_HEADROOM" ] || { echo "fm-worker-context-cap: ignored $project/$model: window $window leaves under $MIN_HEADROOM tokens above the cap $cap" >&2; exit 0; }

printf '{"firstmateWorkerContextCap":"%s","compaction":{"enabled":true,"reserveTokens":%s,"keepRecentTokens":%s}}\n' \
  "$task" "$((window - cap))" "$KEEP_RECENT_TOKENS"
