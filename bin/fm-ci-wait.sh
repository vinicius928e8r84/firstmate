#!/usr/bin/env bash
# fm-ci-wait.sh - wait for one pull request's checks in ONE blocking command.
#
# Usage: fm-ci-wait.sh <pr-url|number> [--repo OWNER/NAME] [--timeout SECS] [--interval SECS]
#   Polls the forge's checks for the PR inside this process until they settle, then prints one result line
#   (and, on a failure, one line per failing check) and exits:
#     0  every reported check passed (skipped checks count as passed)
#     1  at least one check failed or was cancelled: it does not wait for the rest
#     3  still pending when --timeout ran out, or nothing had reported yet: run the SAME command again
#     2  usage error or the forge could not be read for the whole wait
#   --timeout default 540 s (FM_CI_WAIT_TIMEOUT), --interval default 20 s (FM_CI_WAIT_INTERVAL). Pass the shell
#   tool a timeout a little above --timeout.
#
# Why it exists: a worker that waits with `sleep N` and then a status check spends one model turn per look and
# resends its whole context every time (PerpetualMiner workers: 288 single-poll sleeps, 24 h of sleep, plus 273
# bounded shell loops each re-issued every few minutes, in 7 days). gh-axi has no --watch, and no generated brief
# named a blocking wait unless config/wait-no-turns was set, which no home sets. This is that wait.
# Env: FM_CI_WAIT_GH (the gh command, default gh; tests swap it).
set -uo pipefail

usage() { sed -n '2,/^set -uo/p' "$0" | sed -n '2,/^# Env/p' | sed 's/^# \{0,1\}//'; }
die() { echo "fm-ci-wait: $*" >&2; exit 2; }

ref=""; repo=""
timeout=${FM_CI_WAIT_TIMEOUT:-540}; interval=${FM_CI_WAIT_INTERVAL:-20}
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo|-R) shift; repo=${1:-}; [ -n "$repo" ] || die "--repo needs OWNER/NAME" ;;
    --timeout) shift; timeout=${1:-} ;;
    --interval) shift; interval=${1:-} ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$ref" ] || die "one PR only"; ref=$1 ;;
  esac
  shift
done
[ -n "$ref" ] || die "usage: fm-ci-wait.sh <pr-url|number> [--repo OWNER/NAME] [--timeout SECS] [--interval SECS]"
case "$timeout" in ''|*[!0-9]*) die "--timeout needs whole seconds" ;; esac
case "$interval" in ''|*[!0-9]*|0) die "--interval needs whole seconds above 0" ;; esac
gh_cmd=${FM_CI_WAIT_GH:-gh}
command -v "$gh_cmd" >/dev/null 2>&1 || die "$gh_cmd is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

start=$(date +%s)
unreadable=0; last_err=""
while :; do
  args=(pr checks "$ref" --json "name,bucket,link")
  [ -z "$repo" ] || args+=(-R "$repo")
  out=$("$gh_cmd" "${args[@]}" 2>&1)
  total=""; failed=""; pending=""
  if printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    unreadable=0
    total=$(printf '%s' "$out" | jq 'length')
    failed=$(printf '%s' "$out" | jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | .[] | "failed: \(.name) \(.link // "")"')
    pending=$(printf '%s' "$out" | jq '[.[] | select(.bucket == "pending")] | length')
  elif printf '%s' "$out" | grep -qi 'no checks reported'; then
    unreadable=0; total=0; pending=0
  else
    unreadable=$((unreadable + 1)); last_err=$(printf '%s' "$out" | head -n1 | cut -c1-200)
  fi
  if [ -n "$failed" ]; then
    echo "ci: FAILED on $ref after $(( $(date +%s) - start ))s"
    printf '%s\n' "$failed"
    exit 1
  fi
  if [ "$unreadable" = 0 ] && [ "${total:-0}" -gt 0 ] && [ "${pending:-0}" -eq 0 ]; then
    echo "ci: PASSED on $ref ($total checks) after $(( $(date +%s) - start ))s"
    exit 0
  fi
  if [ $(( $(date +%s) - start + interval )) -gt "$timeout" ]; then
    if [ "$unreadable" -gt 0 ]; then
      echo "ci: could not read the checks of $ref ($last_err)" >&2
      exit 2
    fi
    if [ "${total:-0}" -eq 0 ]; then echo "ci: no checks reported yet on $ref after ${timeout}s; run the same command again"
    else echo "ci: still pending on $ref ($pending of $total checks) after ${timeout}s; run the same command again"; fi
    exit 3
  fi
  sleep "$interval"
done
