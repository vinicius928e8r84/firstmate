#!/usr/bin/env bash
# fm-temp-sweep.sh - delete temporaries that firstmate scripts leak into /tmp and state/ when a process is killed by a signal.
# Usage: fm-temp-sweep.sh [--dry-run|--apply] [--rules] [--tmp-age DAYS] [--tmp-dir DIR] [--state-dir DIR] [--tsv FILE]
#   default --dry-run and --rules; the daily cron (fm-cron-cleanup.sh) passes --apply.
# --rules     sweep the known leak prefixes (table in this script) in --tmp-dir (default /tmp) and --state-dir (default $FM_HOME/state),
#             each at its own minimum age in days.
# --tmp-age N one-off: every top-level entry of --tmp-dir owned by this user whose newest file is older than N days (also needs the guards).
# Output: one TSV line per candidate `rule<TAB>path<TAB>bytes<TAB>age_days` (to --tsv when given, else stdout), then a summary line.
# Never (every rule and --tmp-age): an entry (or anything below it) modified inside its age window; one that a live process has as
#   cwd, open file, argument or environment value; a mount point; a git worktree of this repo or of projects/*; a symlink target
#   of a *.lock link; a *.lock.owner.* directory whose pid file names a live process; an entry not owned by this user; with
#   --tmp-age also /tmp/fm-main, /tmp/fm-fill, pmfbkey, rv-segredos-* and any name containing the id of a task that has state/<id>.meta.
#   Deletion is `rm -rf --one-file-system` of exactly the listed path; no globbing at delete time, no pkill, no -f matching.
# Env: FM_HOME (default: the code root).
# Exit: 0 ok, 64 usage.
set -uo pipefail
FM_HOME=${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
apply=0; tmp_age=""; tmp_dir=/tmp; state_dir=$FM_HOME/state; tsv=""
while [ $# -gt 0 ]; do case "$1" in
  --apply) apply=1;; --dry-run) apply=0;; --rules) ;;
  --tmp-age) tmp_age=${2:?}; shift;;
  --tmp-dir) tmp_dir=${2:?}; shift;; --state-dir) state_dir=${2:?}; shift;; --tsv) tsv=${2:?}; shift;;
  *) echo "usage: $0 [--dry-run|--apply] [--rules] [--tmp-age DAYS] [--tmp-dir DIR] [--state-dir DIR] [--tsv FILE]" >&2; exit 64;; esac; shift; done
case "$tmp_age" in *[!0-9]*) echo "usage: --tmp-age takes whole days" >&2; exit 64;; esac
me=$(id -un); now=$(date +%s)
# <dir-kind>:<name pattern>:<min age days>; dir-kind t = tmp dir, s = state dir
RULES='t:fm-fleet-tasks.*:1 t:fm-fleet-snapshot.*:1 t:fm-timeout-status.*:1 t:fm-contributions.*:1 t:fm-bootstrap-fleet.*:1
t:fm-bootstrap-par.*:1 t:fm-remote-reply-ingest.*:1 t:fm-merge-pr.*:1 t:.fm-test-cleanup.*:1 t:bb-provider-bridge-provider-*:2
s:.home-summary-error.*:1 s:.home-summary.json.*:1 s:.claude-autoarm-output.*:1 s:.watch-arm-output.*:1
s:.fm-lease-command.lock.owner.*:1 s:.wake-queue.lock.owner.*:1 s:.claude-autoarm.lock.owner.*:1'

busy=$(mktemp); prot=$(mktemp); ids=$(mktemp); trap 'rm -f "$busy" "$prot" "$ids"' EXIT
# first-level entries below tmp_dir/state_dir that any live process references (cwd, fds, argv, environ)
{ for p in /proc/[0-9]*; do
    readlink "$p/cwd"; find "$p/fd" -maxdepth 1 -type l -printf '%l\n'
    tr '\0' '\n' < "$p/cmdline"; tr '\0' '\n' < "$p/environ"
  done; } 2>/dev/null | grep -oE "($tmp_dir|$state_dir)/[^/ :'\"=,;]+" | sort -u > "$busy"
# git worktrees and *.lock link targets are protected too
for r in "$FM_HOME" "$FM_HOME"/projects/*; do [ -e "$r/.git" ] && git -C "$r" worktree list --porcelain 2>/dev/null; done | sed -n 's/^worktree //p' \
  | grep -oE "^($tmp_dir|$state_dir)/[^/]+" >> "$busy"
for l in "$state_dir"/.*.lock "$tmp_dir"/*.lock; do [ -L "$l" ] && readlink "$l" >> "$busy"; done
for m in "$state_dir"/*.meta; do [ -e "$m" ] && basename "$m" .meta; done > "$ids"
: > "$prot"

declare -A BUSY=(); while IFS= read -r l; do [ -n "$l" ] && BUSY[$l]=1; done < "$busy"
has_live_pid(){ local f; f=$(cat "$1/pid" 2>/dev/null) || return 1; case "$f" in ''|*[!0-9]*) return 1;; esac; kill -0 "$f" 2>/dev/null; }
declare -a IDS=(); while IFS= read -r l; do [ -n "$l" ] && IDS+=("$l"); done < "$ids"
protected_name(){ local n=$1 id
  case "$n" in fm-main|fm-fill|pmfbkey|rv-segredos-*) return 0;; esac
  for id in "${IDS[@]}"; do
    case "$n" in "$id"|"$id".*|"$id"-*|*-"$id"|*-"$id"-*|*-"$id".*|*_"$id"|*_"$id"_*|*_"$id".*) return 0;; esac
  done; return 1; }

out=${tsv:-/dev/stdout}; [ -z "$tsv" ] || : > "$tsv"
declare -A MNT=(); while read -r _ _ _ _ mp _; do MNT[$mp]=1; done < /proc/self/mountinfo
cand=$(mktemp); trap 'rm -f "$busy" "$prot" "$ids" "$cand"' EXIT
# phase 1: top-level entries of this user outside every age window, minus the cheap guards, as `rule<TAB>days<TAB>mtime<TAB>type<TAB>path`
list(){ # <rule> <dir> <days> [name pattern]
  local rule=$1 mt ty e
  while IFS=$'\t' read -r -d '' mt ty e; do
    [ -z "${BUSY[$e]:-}" ] && [ -z "${MNT[$e]:-}" ] || continue
    case "$rule" in tmp-age*) ! protected_name "${e##*/}" || continue;; esac
    case "${e##*/}" in *.lock.owner.*) [ "$ty" != d ] || ! has_live_pid "$e" || continue;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$rule" "$3" "$mt" "$ty" "$e"
  done < <(find "$2" -mindepth 1 -maxdepth 1 -user "$me" ${4:+-name "$4"} ! -newermt "@$((now-$3*86400))" -printf '%T@\t%y\t%p\0' 2>/dev/null) >> "$cand"; }
if [ -n "$tmp_age" ]; then list "tmp-age>${tmp_age}d" "$tmp_dir" "$tmp_age"
else for r in $RULES; do kind=${r%%:*}; rest=${r#*:}; pat=${rest%:*}; days=${rest##*:}
    base=$tmp_dir; [ "$kind" = s ] && base=$state_dir
    list "$kind:$pat" "$base" "$days" "$pat"; done; fi
# phase 2: a directory with any file inside its window is still in use; one find per distinct window, hits mapped back to their top-level entry
declare -A FRESH=()
while IFS= read -r days; do
  mapfile -t roots < <(awk -F'\t' -v d="$days" '$4=="d" && $2==d{print $5}' "$cand")
  # shellcheck disable=SC2185 # -files0-from takes the start points from stdin; a path argument would be an error
  while IFS= read -r -d '' hit; do
    for r in "${roots[@]}"; do case "$hit" in "$r"|"$r"/*) FRESH[$r]=1; break;; esac; done
  done < <(printf '%s\n' "${roots[@]}" | tr '\n' '\0' | find -files0-from - -newermt "@$((now-days*86400))" -print0 2>/dev/null)
done < <(awk -F'\t' '$4=="d"{print $2}' "$cand" | sort -un)
# phase 3: size (one du for all survivors), report, delete
declare -A SZ=()
while IFS=$'\t' read -r b e; do SZ[$e]=$b; done < <(awk -F'\t' '{print $5}' "$cand" | tr '\n' '\0' | du -sb --files0-from=- 2>/dev/null)
n=0; tot=0
while IFS=$'\t' read -r rule days mt ty e; do
  [ -z "${FRESH[$e]:-}" ] || continue
  b=${SZ[$e]:-}; [ -n "$b" ] || continue
  printf '%s\t%s\t%s\t%s\n' "$rule" "$e" "$b" "$(( (now-${mt%.*})/86400 ))" >> "$out"
  n=$((n+1)); tot=$((tot+b))
  if [ $apply = 1 ]; then chmod -R u+w -- "$e" 2>/dev/null; rm -rf --one-file-system -- "$e"; fi
done < "$cand"
echo "fm-temp-sweep $([ $apply = 1 ] && echo apply || echo dry-run): $n entries, $tot bytes $([ $apply = 1 ] && echo removed || echo would be removed)"
exit 0
