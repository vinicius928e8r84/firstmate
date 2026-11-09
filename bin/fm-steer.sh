#!/usr/bin/env bash
# fm-steer.sh - send a prepared steer to a worker: claim the supervision lease, send with fm-say, release, print ONE line.
#
# Usage: fm-steer.sh <target> (--file MSG | --file -) [--again] [--paths-ok] [--resolve-key KEY]...
# It replaces the hand-repeated `cat > msgNNN.txt; fm-lease claim; fm-say ...; fm-lease release` sequence for a steer whose text
# is already written (a review verdict to the PR's author, "main moved, merge main", a captain's words passed on). Choosing
# the text stays with the caller; this only delivers it safely.
#   1 text     MSG must be non-empty (`-` reads stdin); it is sent as one multi-line message
#   2 lease    bin/fm-lease.sh claim <target> --actor main. A lease the other supervisor holds REFUSES the steer (LEASE-HELD,
#              exit 6, nothing sent). A lease main already held before is left held; only a lease taken here is released
#   3 send     data/tools/fm-say.sh [--again] [--paths-ok] <target> [--resolve-key KEY]... <text>: it dedups a resend, hides
#              the supervisor noise and proves the record reached the target's inbox
#   4 result   fm-say's own final line, unchanged: DELIVERED | UNKNOWN | FAILED | DUPLICATE-REFUSED | TYPED
# Exit: fm-say's (0 delivered or typed, 1 failed, 3 unknown - do not resend blindly, 4 duplicate refused, 5 path missing on the remote),
#       2 usage, 6 lease held by the other supervisor.
# Env: FM_HOME (explicit, as for bin/fm-send.sh), FM_STEER_SAY (default $FM_HOME/data/tools/fm-say.sh), FM_STEER_LEASE (default bin/fm-lease.sh).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${FM_HOME:?FM_HOME must be set explicitly (a steer must not resolve against another home)}"; export FM_HOME
SAY=${FM_STEER_SAY:-$FM_HOME/data/tools/fm-say.sh}
LEASE=${FM_STEER_LEASE:-$HERE/fm-lease.sh}
usage() { sed -n 2,3p "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

target=${1:-}; [ -n "$target" ] || usage
case "$target" in -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
shift
file=""; say_args=(); keys=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file) [ $# -ge 2 ] || usage; file=$2; shift 2 ;;
    --again|--paths-ok) say_args+=("$1"); shift ;;
    --resolve-key) [ $# -ge 2 ] || usage; keys+=("$1" "$2"); shift 2 ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$file" ] || usage
if [ "$file" = - ]; then text=$(cat); else
  [ -r "$file" ] || { echo "FAILED $target: cannot read $file"; exit 2; }
  text=$(cat "$file")
fi
[ -n "${text//[[:space:]]/}" ] || { echo "FAILED $target: the message is empty (nothing sent)"; exit 2; }
[ -x "$SAY" ] || { echo "FAILED $target: $SAY is missing (nothing sent)"; exit 2; }

held_before=0; "$LEASE" check "$target" 2>/dev/null | grep -q '^main ' && held_before=1
if ! "$LEASE" claim "$target" --actor main >/dev/null 2>&1; then
  echo "LEASE-HELD $target: the other supervisor holds its lease; nothing sent, retry shortly"; exit 6
fi
out=$("$SAY" "${say_args[@]}" "$target" "${keys[@]}" "$text" 2>&1); rc=$?
[ $held_before = 1 ] || "$LEASE" release "$target" --actor main >/dev/null 2>&1
result=$(printf '%s\n' "$out" | grep -E '^(DELIVERED|TYPED|UNKNOWN|FAILED|DUPLICATE-REFUSED|PATH-MISSING-REMOTE)' | tail -1)
[ -n "$result" ] || result="FAILED $target: fm-say printed no result (exit $rc): $(printf '%s\n' "$out" | tail -1 | cut -c1-160)"
echo "$result"
exit "$rc"
