#!/usr/bin/env bash
# fm-clean-pr-guard.sh - a PR that is CLEAN but has no reviewer gets one raised in the same watcher cycle (daily
# speed audit 2026-10-28 item 3b). Pure shell plus gh: no model call. Never merges, never spawns; it only reports.
# Usage: fm-clean-pr-guard.sh        (prints one alert line per NEW (pr, head) pair)
# Scan: every state/*.meta that is not a secondmate and has a `pr=` line is read with
#   `gh pr view <url> --json headRefOid,mergeStateStatus,state` (timeout FM_CPG_GH_TIMEOUT, default 20, per call).
#   An OPEN PR whose mergeStateStatus is CLEAN and whose head has no review record raises
#   `clean-pr-guard: <url> head <sha7> is CLEAN with no review record (task <id>)`.
# Review record for a head (any one counts; a sha is matched by its first 7 characters):
#   state/<id>.reviewed naming the sha, data/rv-*/report.md naming the sha, or data/reviews/<owner>-<repo>-<pr>.json
#   (bin/fm-review-record.sh) whose reviewed_head is the sha.
# Each (pr, head) pair alerts once: it is remembered in state/.clean-pr-guard.seen. A new head alerts again.
# A gh failure, a closed or merged PR, or a PR that is not CLEAN prints nothing and is retried on the next scan.
# bin/fm-watch.sh runs it every FM_CLEAN_PR_GUARD_INTERVAL seconds (default 600) and wakes on any output.
# Env: FM_HOME FM_STATE_OVERRIDE FM_CPG_GH_TIMEOUT.
# Exit: 0 nothing new, 1 at least one alert was printed.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
F=${FM_HOME:-$(cd "$HERE/.." && pwd)}
S=${FM_STATE_OVERRIDE:-$F/state}
D=$F/data
SEEN=$S/.clean-pr-guard.seen
GH_TIMEOUT=${FM_CPG_GH_TIMEOUT:-20}
ALERTED=0

meta_get() { sed -n "s/^$2=//p" "$1" | head -1; }

reviewed() { # id url head -> 0 when a review record names this head
  local id=$1 url=$2 head=$3 short=${3:0:7} repo n rec
  grep -qF "$short" "$S/$id.reviewed" 2>/dev/null && return 0
  for rec in "$D"/rv-*/report.md; do
    [ -f "$rec" ] && grep -qF "$short" "$rec" && return 0
  done
  repo=${url#*://*/}; repo=${repo%%/pull/*}; n=${url##*/}
  rec=$D/reviews/${repo/\//-}-$n.json
  [ -f "$rec" ] && grep -E '"reviewed_head"' "$rec" | grep -qF "$short" && return 0
  return 1
}

for meta in "$S"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  [ "$(meta_get "$meta" kind)" != secondmate ] || continue
  url=$(meta_get "$meta" pr)
  case "$url" in https://*/pull/[0-9]*) ;; *) continue ;; esac
  json=$(timeout "$GH_TIMEOUT" gh pr view "$url" --json headRefOid,mergeStateStatus,state </dev/null 2>/dev/null) || continue
  state=$(printf '%s' "$json" | jq -r '.state // empty' 2>/dev/null)
  merge=$(printf '%s' "$json" | jq -r '.mergeStateStatus // empty' 2>/dev/null)
  head=$(printf '%s' "$json" | jq -r '.headRefOid // empty' 2>/dev/null)
  [ "$state" = OPEN ] && [ "$merge" = CLEAN ] && [ -n "$head" ] || continue
  reviewed "$id" "$url" "$head" && continue
  grep -qxF "$url $head" "$SEEN" 2>/dev/null && continue
  printf '%s %s\n' "$url" "$head" >> "$SEEN"
  echo "clean-pr-guard: $url head ${head:0:7} is CLEAN with no review record (task $id)"
  ALERTED=1
done
exit "$ALERTED"
