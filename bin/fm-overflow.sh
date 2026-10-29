#!/usr/bin/env bash
# fm-overflow.sh - place CPU-heavy, main-data-free work on a remote secondmate
# host that has room, instead of on this overloaded home.
#
# Usage:
#   fm-overflow.sh pick [--json]       choose the host; exit 0 picked, 1 none free
#   fm-overflow.sh send <text...>      pick, then hand the text to the picked host
#
# Candidates are remote secondmates (docs/remote-secondmates.md), by default
# creative-aux and pc-aux2. Each candidate publishes its lane facts to its own
# state/lane-capacity.json (bin/fm-capacity.sh --publish, which runs while that
# home has a config/lane-capacity). This script reads that file through
# fm-on.sh and fm-remote-file.sh, so it adds no transport and no remote command.
#
# A candidate is skipped, with the reason printed, unless all of these hold:
#   - this home has a remote secondmate record for it (state/<id>.meta);
#   - its facts were readable, in fm-lane-capacity.v1 shape, and generated within
#     FM_OVERFLOW_MAX_AGE seconds (default 600);
#   - its cap is valid and it has a free lane (cap target minus lanes);
#   - its load per core is known and under FM_OVERFLOW_MAX_LOAD_PER_CORE
#     (default 3), its pressure is not critical, and it holds no captain reserve.
# Among the rest, the lowest load per core wins, then the most free lanes.
#
# pick prints one line, `picked: <id> (<why>)` or `none free`, then one
# `skipped: <id> (<why>)` line per skipped candidate. --json prints the same as
# one object. send hands everything after `send` to the picked secondmate with
# fm-send.sh, which marks it as a routed request and tracks the reply; it sends
# nothing and exits 1 when no host is free. Only work that needs nothing from
# this home's data belongs here: the receiving secondmate runs it in its own
# home, and it never merges or answers captain decisions.
#
# Environment: FM_OVERFLOW_HOSTS (space-separated candidate ids),
# FM_OVERFLOW_MAX_LOAD_PER_CORE, FM_OVERFLOW_MAX_AGE, FM_OVERFLOW_READ_TIMEOUT
# (seconds per host, default 30), FM_OVERFLOW_ON and FM_OVERFLOW_SEND (the
# fm-on.sh and fm-send.sh commands, for tests), plus FM_HOME and
# FM_STATE_OVERRIDE as in the other bin/ scripts.
#
# Exit status: 0 picked (and, for send, delivered), 1 none free or the send
# failed, 2 usage error or jq missing.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
HOSTS="${FM_OVERFLOW_HOSTS:-creative-aux pc-aux2}"
MAX_LOAD="${FM_OVERFLOW_MAX_LOAD_PER_CORE:-3}"
MAX_AGE="${FM_OVERFLOW_MAX_AGE:-600}"
READ_TIMEOUT="${FM_OVERFLOW_READ_TIMEOUT:-30}"
ON="${FM_OVERFLOW_ON:-$SCRIPT_DIR/fm-on.sh}"
SEND="${FM_OVERFLOW_SEND:-$SCRIPT_DIR/fm-send.sh}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-2}"; }

mode=${1:-}
case "$mode" in
  -h|--help) usage 0 ;;
  pick) shift ;;
  send) shift ;;
  *) usage 2 ;;
esac
json=0
if [ "$mode" = pick ] && [ "${1:-}" = --json ]; then json=1; shift; fi
if [ "$mode" = pick ] && [ "$#" -gt 0 ]; then usage 2; fi
if [ "$mode" = send ] && [ "$#" -eq 0 ]; then usage 2; fi
command -v jq >/dev/null 2>&1 || { echo "fm-overflow: needs jq" >&2; exit 2; }
case "$MAX_AGE" in ''|*[!0-9]*) MAX_AGE=600 ;; esac
case "$MAX_LOAD" in ''|*[!0-9.]*|*.*.*) MAX_LOAD=3 ;; esac
case "$READ_TIMEOUT" in ''|*[!0-9]*) READ_TIMEOUT=30 ;; esac

now=$(date +%s)
skipped=
best=
best_load=
best_free=
best_why=

skip() { skipped="$skipped$1	$2
"; }

for id in $HOSTS; do
  case "$id" in *[!A-Za-z0-9._-]*|-*) skip "$id" "not a safe secondmate id"; continue ;; esac
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ] || ! grep -qx 'kind=secondmate' "$meta" 2>/dev/null ||
    ! grep -q '^remote_host=..*' "$meta" 2>/dev/null; then
    skip "$id" "no remote secondmate record here"
    continue
  fi
  facts=$(fm_run_timed "$READ_TIMEOUT" "$ON" "$id" fm-remote-file.sh get state/lane-capacity.json 2>/dev/null) || facts=
  verdict=$(printf '%s' "$facts" | jq -r --argjson now "$now" --argjson maxage "$MAX_AGE" --argjson maxload "$MAX_LOAD" '
    if type != "object" or .schema != "fm-lane-capacity.v1" then "skip\tlane facts unreadable"
    elif ((.generated_epoch | type) != "number") or ($now - .generated_epoch) > $maxage then "skip\tlane facts are stale"
    elif .cap.status != "ok" or (.cap.target | type) != "number" then "skip\tno valid lane cap published"
    elif (.lanes.count | type) != "number" then "skip\tno lane count published"
    elif .reserve.flag == "present" then "skip\tcaptain reserve is set"
    elif .pressure.level == "critical" then "skip\tpressure is critical"
    elif (.pressure.runq_per_core | type) != "number" then "skip\tno load figure published"
    elif .pressure.runq_per_core >= $maxload then "skip\tload \(.pressure.runq_per_core) per core, at or over \($maxload)"
    elif (.cap.target - .lanes.count) <= 0 then "skip\tno free lane (\(.lanes.count) of \(.cap.target))"
    else "ok\t\(.pressure.runq_per_core)\t\(.cap.target - .lanes.count)\t\(.lanes.count)\t\(.cap.target)" end' 2>/dev/null) || verdict=
  [ -n "$verdict" ] || verdict=$'skip\tlane facts unreadable'
  IFS=$'\t' read -r kind a b c d <<EOF
$verdict
EOF
  if [ "$kind" != ok ]; then skip "$id" "$a"; continue; fi
  # a = load per core, b = free lanes, c = lanes, d = cap
  why="$b free of $d lanes, load $a per core"
  if [ -z "$best" ] ||
    awk -v a="$a" -v b="$best_load" 'BEGIN{exit !(a < b)}' ||
    { [ "$a" = "$best_load" ] && [ "$b" -gt "$best_free" ]; }; then
    [ -z "$best" ] || skip "$best" "free but ranked below $id"
    best=$id best_load=$a best_free=$b best_why=$why
  else
    skip "$id" "free but ranked below $best"
  fi
done

if [ "$mode" = pick ] && [ "$json" -eq 1 ]; then
  jq -cn --arg picked "$best" --arg why "$best_why" --arg skipped "$skipped" '
    {picked: (if $picked == "" then null else $picked end),
     why: (if $picked == "" then null else $why end),
     skipped: [$skipped | split("\n")[] | select(. != "") | split("\t") | {id: .[0], why: .[1]}]}'
else
  if [ -n "$best" ]; then echo "picked: $best ($best_why)"; else echo "none free"; fi
  printf '%s' "$skipped" | while IFS=$'\t' read -r sid swhy; do
    [ -z "$sid" ] || echo "skipped: $sid ($swhy)"
  done
fi

[ -n "$best" ] || exit 1
[ "$mode" = send ] || exit 0

"$SEND" "$best" "$*" || {
  echo "fm-overflow: the hand-over to $best failed; nothing is confirmed delivered" >&2
  exit 1
}
echo "sent: $best"
exit 0
