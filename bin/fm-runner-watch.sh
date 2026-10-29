#!/usr/bin/env bash
# fm-runner-watch.sh - warn when a workflow job sits queued with no self-hosted runner online to take it.
# Pure shell plus gh and jq: no model call, read-only. It only ever issues `gh api` GET requests, never a POST,
# PUT, PATCH or DELETE, so it cannot start, cancel or re-run a workflow or touch a runner.
# Usage: fm-runner-watch.sh <owner/repo>
# Reads: actions/runs?status=queued, then actions/runs/<id>/jobs for each queued run, then actions/runners.
#   A job counts as stuck when its status is `queued` and it has been queued for more than FM_RW_QUEUE_SEC (600).
#   The runner list is read only once a stuck job exists; an online runner is one with status `online`.
# Output: one line `runner-watch: <owner/repo> job "<name>" queued <N>m with no self-hosted runner online` on stdout.
#   The name is that of the oldest stuck job. Any other outcome prints nothing on stdout.
# A gh failure or unparsable answer (including a token that may not read the runner list) prints one line on stderr
#   and exits 2 rather than guessing, so an unreadable runner list is never reported as "no runner online".
# Env: FM_RW_QUEUE_SEC FM_RW_NOW (epoch, tests) FM_RW_GH_TIMEOUT (seconds per gh call, default 20).
# Exit: 0 nothing stuck, or a stuck job with a runner online; 2 usage or gh error; 3 warning printed.
set -uo pipefail
QUEUE_SEC=${FM_RW_QUEUE_SEC:-600}
GH_TIMEOUT=${FM_RW_GH_TIMEOUT:-20}
NOW=${FM_RW_NOW:-$(date +%s)}

die() { echo "fm-runner-watch: $*" >&2; exit 2; }
api() { timeout "$GH_TIMEOUT" gh api "$1" 2>/dev/null || die "gh api $1 failed"; }

repo=${1:-}
case $repo in */*/* | */ | /* | '' | *[!A-Za-z0-9._/-]*) die "usage: fm-runner-watch.sh <owner/repo>" ;; esac
[[ $repo == */* ]] || die "usage: fm-runner-watch.sh <owner/repo>"
command -v jq >/dev/null 2>&1 || die "jq is required"

runs=$(api "repos/$repo/actions/runs?status=queued&per_page=100") || exit 2
ids=$(printf '%s' "$runs" | jq -r '.workflow_runs[]?.id' 2>/dev/null) || die "unparsable run list for $repo"

stuck="" # "<age seconds>\t<job name>" of the oldest stuck job
for id in $ids; do
  jobs=$(api "repos/$repo/actions/runs/$id/jobs?per_page=100") || exit 2
  found=$(printf '%s' "$jobs" | jq -r --argjson now "$NOW" --argjson max "$QUEUE_SEC" '
    .jobs[]? | select(.status == "queued" and .created_at != null)
    | [($now - (.created_at | fromdateiso8601)), .name]
    | select(.[0] > $max) | "\(.[0])\t\(.[1])"' 2>/dev/null) || die "unparsable job list for run $id"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -z "$stuck" ] || [ "${line%%$'\t'*}" -gt "${stuck%%$'\t'*}" ]; then stuck=$line; fi
  done <<< "$found"
done
[ -n "$stuck" ] || exit 0

runners=$(api "repos/$repo/actions/runners?per_page=100") || exit 2
online=$(printf '%s' "$runners" \
  | jq '[.runners[]? | select(.status == "online")] | length' 2>/dev/null) || die "unparsable runner list for $repo"
[ "${online:-0}" -eq 0 ] || exit 0

age=${stuck%%$'\t'*}
printf 'runner-watch: %s job "%s" queued %dm with no self-hosted runner online\n' "$repo" "${stuck#*$'\t'}" $((age / 60))
exit 3
