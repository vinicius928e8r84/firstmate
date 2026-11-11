#!/usr/bin/env bash
# fm-pr-merge-main.sh - merge the base branch into a PR branch deterministically.
#
# Usage:
#   fm-pr-merge-main.sh --worktree DIR [--remote origin] [--base main]
#                       [--check CMD]... [--slug OWNER/REPO --pr N] [--verify-only]
#                       [--allow-unpinned] [--mechanical]
#
# The routine "bring this PR up to date with main" step, done by a script so a
# model is only needed when the merge truly conflicts. It is run by the worker
# that owns the PR, in that worker's own worktree, or by bin/fm-merge-queue.sh in
# its own scratch clone: it commits inside a project worktree, so firstmate itself
# never runs it. In the PR branch worktree
# DIR it fetches <remote>/<base>, runs `git merge --no-edit` on it, then runs
# each --check command (the project's own cheap checks, such as typecheck or
# lint) from DIR. It never pushes: the worker that owns the PR pushes.
#
# With --slug and --pr it also reports whether the clean review pin still
# applies to the merged head, through the private fm-review-pin.sh
# (FM_REVIEW_PIN overrides its path, default $FM_HOME/data/tools/fm-review-pin.sh).
# The merge commit is not pushed yet, so it is fetched from DIR into the pin's
# scratch bare clone (FM_PIN_WORK, default /tmp/fm-pins) before `pin check`
# reads it. The pin verdict is printed as its own line and never changes the
# exit status: PIN-VALID means the review still stands, anything else means
# review only what fm-review-delta.sh prints.
#
# The merge commit is pinned to the project's registered commit identity so a
# project whose CI rejects a stray author (PerpetualMiner's autoria rule) never
# sees one from this path. The identity comes from gitignored
# $FM_HOME/config/commit-identity, one entry per line:
#   <owner/repo | repo-name> <email> [<author name>]
# (# comments and blank lines allowed). The project key is --slug when given,
# else the owner/repo of the worktree's <remote> URL, else the repo-name
# (basename of that URL). The script exports the identity as GIT_AUTHOR_* and
# GIT_COMMITTER_* for the merge only, so it wins over any ambient git config or
# environment. With no entry it refuses before touching DIR (exit 3) and says
# where to register one; --allow-unpinned runs the merge with the ambient
# identity for a project that has no authorship rule. --verify-only creates no
# commit and needs no identity.
#
# --mechanical settles a conflicting merge without a model when EVERY conflicted
# path is a content conflict (both sides modified, or both added) that a rule in
# gitignored $FM_HOME/config/merge-mechanical covers; one line per rule:
#   <owner/repo | repo-name> <glob> keep-pr|take-main|union|regen [command...]
# (same project key lookup as commit-identity; the glob is a bash pattern over
# the repo-relative path, so `*` also crosses `/`; the first matching line wins).
# keep-pr takes the PR branch's side whole (version numbers), take-main takes the
# base's side whole, union keeps the lines of both sides (append-only tables and
# indexes), regen runs the command from DIR after every other path is settled
# (a generated file; the command runs once per distinct line and must rewrite the
# conflicted files). Nothing is guessed: a path without a rule, a delete/modify
# conflict, a leftover conflict marker, a command that fails or a regen that
# dirties any other tracked file makes the run behave exactly as without the
# flag (MERGE-CONFLICT, the merge left open in DIR, exit 10), with the unruled
# paths named as "  code: <path>". No rule file means nothing is mechanical.
#
# --verify-only skips the fetch and merge and runs only the checks and the pin
# report on DIR's current head, for use after a model resolved a conflict and
# committed; like a merge it refuses a worktree with a merge still in progress
# or uncommitted changes.
#
# Result lines (one is always printed first after the work starts):
#   ALREADY-CURRENT <remote>/<base>   nothing to merge
#   MERGE-CLEAN <old> -> <new>        merged without conflict
#   MERGE-MECHANICAL <old> -> <new>   --mechanical settled every conflict by rule
#                                     and committed; "  resolved: <path> (<rule>)"
#                                     follows per path
#   MERGE-CONFLICT                    stopped; the merge is left in progress in
#                                     DIR and the conflicted files follow, one
#                                     per line as "  conflicted: <path>"
#   CHECK-FAILED <command>            a --check command failed (output above it)
# Exit status: 0 merged or current and every check passed, 2 usage, 3 refused
# or git error (dirty worktree, merge already in progress, fetch failed, no
# registered commit identity), 10 conflict, 11 a check failed.
set -uo pipefail

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-usage-ledger-lib.sh
. "$FM_ROOT/bin/fm-usage-ledger-lib.sh"

usage() { sed -n 2,74p "$0"; }

wt='' remote=origin base=main slug='' pr='' verify_only=0 allow_unpinned=0 mechanical=0 usage_outcome=''
# One usage line per run (bin/fm-usage-ledger-lib.sh): the result line, or the exit status of a refused run.
trap 'fm_usage_record fm-pr-merge-main "${usage_outcome:-exit-$?}" "$pr" merge' EXIT
checks=()
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree|--remote|--base|--check|--slug|--pr) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --worktree) wt=$2; shift 2 ;;
    --remote) remote=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --check) checks+=("$2"); shift 2 ;;
    --slug) slug=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --verify-only) verify_only=1; shift ;;
    --allow-unpinned) allow_unpinned=1; shift ;;
    --mechanical) mechanical=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$wt" ] && [ -d "$wt" ] || { echo "--worktree must name an existing directory" >&2; exit 2; }
if { [ -n "$slug" ] && [ -z "$pr" ]; } || { [ -z "$slug" ] && [ -n "$pr" ]; }; then
  echo "--slug and --pr go together" >&2; exit 2
fi
git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git worktree: $wt" >&2; exit 3; }

git_dir=$(git -C "$wt" rev-parse --git-dir) || exit 3
case "$git_dir" in /*) ;; *) git_dir=$wt/$git_dir ;; esac

[ ! -e "$git_dir/MERGE_HEAD" ] || { echo "a merge is in progress in $wt; resolve and commit it first" >&2; exit 3; }
[ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ] || { echo "worktree has uncommitted changes: $wt" >&2; exit 3; }
# project_keys: set keys=() to the registry keys of this project, most specific first.
keys=()
project_keys() {
  local url short owner
  url=$(git -C "$wt" remote get-url "$remote" 2>/dev/null || true)
  short=${url%.git}
  short=${short##*[/:]}
  owner=${url%.git}
  owner=${owner%/*}
  owner=${owner##*[/:]}
  keys=("$slug" "${owner:+$owner/$short}" "$short")
}
project_keys
# commit_identity: print "<email>\t<name>" for this project from
# config/commit-identity, or nothing when none is registered.
commit_identity() {
  local file=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/commit-identity key
  [ -r "$file" ] || return 0
  for key in "${keys[@]}"; do
    [ -n "$key" ] || continue
    awk -v k="$key" '
      /^[[:space:]]*(#|$)/ { next }
      $1 == k { name = ""; for (i = 3; i <= NF; i++) name = name (i > 3 ? " " : "") $i; print $2 "\t" name; found = 1; exit }
      END { exit !found }' "$file" && return 0
  done
  return 0
}

# mechanical_rule <path>: print "<strategy>\t<command>" of the first config/merge-mechanical
# line whose project key and glob match the path; status 1 when none does.
mechanical_rule() {
  local file=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/merge-mechanical proj glob strat cmd key
  [ -r "$file" ] || return 1
  while read -r proj glob strat cmd; do
    case $proj in ''|'#'*) continue ;; esac
    for key in "${keys[@]}"; do
      [ -n "$key" ] && [ "$proj" = "$key" ] || continue
      # shellcheck disable=SC2053 # the rule's glob is a pattern on purpose
      if [[ $1 == $glob ]]; then
        case $strat in keep-pr|take-main|union|regen) printf '%s\t%s\n' "$strat" "$cmd"; return 0 ;; esac
      fi
    done
  done < "$file"
  return 1
}

# resolve_mechanical: settle every unmerged path through its rule, all or nothing.
# On success the merge is committed and resolved_lines holds the report; on failure
# the merge is back in its plain conflicted state and unruled lists paths without a rule.
resolved_lines=() unruled=()
resolve_mechanical() {
  local -a paths=() strategies=() commands=() ran=()
  local p r stages i tmp rc c seen
  while IFS= read -r p; do paths+=("$p"); done < <(git -C "$wt" diff --name-only --diff-filter=U)
  [ ${#paths[@]} -gt 0 ] || return 1
  for p in "${paths[@]}"; do
    stages=$(git -C "$wt" ls-files -u -- "$p" | awk '{ print $3 }' | sort -u | tr -d '\n')
    if [ "$stages" != 123 ] && [ "$stages" != 23 ]; then unruled+=("$p"); continue; fi
    r=$(mechanical_rule "$p") || { unruled+=("$p"); continue; }
    strategies+=("${r%%$'\t'*}"); commands+=("${r#*$'\t'}")
  done
  [ ${#unruled[@]} = 0 ] || return 1
  tmp=$(mktemp -d)
  rc=0
  for i in "${!paths[@]}"; do
    p=${paths[$i]}
    case ${strategies[$i]} in
      keep-pr) git -C "$wt" checkout -q --ours -- "$p" || rc=1 ;;
      take-main) git -C "$wt" checkout -q --theirs -- "$p" || rc=1 ;;
      union)
        git -C "$wt" show ":2:$p" > "$tmp/pr" 2>/dev/null && git -C "$wt" show ":3:$p" > "$tmp/main" 2>/dev/null || rc=1
        git -C "$wt" show ":1:$p" > "$tmp/base" 2>/dev/null || : > "$tmp/base"
        if [ $rc = 0 ] && git merge-file -p --union "$tmp/pr" "$tmp/base" "$tmp/main" > "$tmp/out" 2>/dev/null; then
          cat "$tmp/out" > "$wt/$p"
        else rc=1; fi ;;
    esac
    [ $rc = 0 ] || break
  done
  if [ $rc = 0 ]; then
    for i in "${!paths[@]}"; do
      [ "${strategies[$i]}" = regen ] || continue
      c=${commands[$i]}
      seen=0; for r in "${ran[@]+"${ran[@]}"}"; do [ "$r" = "$c" ] && seen=1; done
      [ $seen = 1 ] && continue
      ran+=("$c")
      if [ -z "$c" ] || ! ( cd "$wt" && bash -c "$c" >/dev/null 2>&1 ); then rc=1; break; fi
    done
  fi
  if [ $rc = 0 ]; then
    for p in "${paths[@]}"; do
      if [ ! -f "$wt/$p" ] || grep -Iq '^\(<<<<<<<\|>>>>>>>\) ' "$wt/$p"; then rc=1; break; fi
      git -C "$wt" add -- "$p" || { rc=1; break; }
    done
  fi
  if [ $rc = 0 ] && git -C "$wt" status --porcelain --untracked-files=no | grep -qv '^[MADRC] '; then rc=1; fi
  if [ $rc = 0 ] && ! env "${merge_env[@]+"${merge_env[@]}"}" git -C "$wt" commit -q --no-edit >/dev/null 2>&1; then rc=1; fi
  rm -rf "$tmp"
  if [ $rc != 0 ]; then
    # back to the plain conflicted merge, so the caller reports it as it always did
    git -C "$wt" merge --abort >/dev/null 2>&1 || git -C "$wt" reset -q --hard "$old"
    env "${merge_env[@]+"${merge_env[@]}"}" git -C "$wt" merge --no-edit "$target" >/dev/null 2>&1
    return 1
  fi
  for i in "${!paths[@]}"; do resolved_lines+=("  resolved: ${paths[$i]} (${strategies[$i]})"); done
}

merge_env=()
if [ "$verify_only" = 0 ] && [ "$allow_unpinned" = 0 ]; then
  ident=$(commit_identity)
  if [ -z "$ident" ]; then
    echo "no commit identity registered for this project; add '<owner/repo> <email> [<name>]' to ${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/commit-identity, or pass --allow-unpinned if it has no authorship rule" >&2
    exit 3
  fi
  id_email=${ident%%$'\t'*}
  id_name=${ident#*$'\t'}
  [ -n "$id_name" ] || id_name=$(git -C "$wt" config user.name 2>/dev/null || true)
  [ -n "$id_name" ] || id_name=${id_email%%@*}
  merge_env=(GIT_AUTHOR_NAME="$id_name" GIT_AUTHOR_EMAIL="$id_email" GIT_COMMITTER_NAME="$id_name" GIT_COMMITTER_EMAIL="$id_email")
fi
if [ "$verify_only" = 0 ]; then
  git -C "$wt" fetch -q "$remote" "$base" || { echo "fetch $remote $base failed" >&2; exit 3; }
  target=$(git -C "$wt" rev-parse "FETCH_HEAD^{commit}") || exit 3
  old=$(git -C "$wt" rev-parse HEAD) || exit 3
  if git -C "$wt" merge-base --is-ancestor "$target" "$old"; then
    usage_outcome=ALREADY-CURRENT
    echo "ALREADY-CURRENT $remote/$base"
  elif merge_out=$(env "${merge_env[@]+"${merge_env[@]}"}" git -C "$wt" merge --no-edit "$target" 2>&1); then
    usage_outcome=MERGE-CLEAN
    echo "MERGE-CLEAN ${old:0:8} -> $(git -C "$wt" rev-parse --short=8 HEAD)"
  else
    if [ ! -e "$git_dir/MERGE_HEAD" ]; then
      echo "merge failed without a conflict state in $wt:" >&2
      printf '%s\n' "$merge_out" >&2
      exit 3
    fi
    if [ "$mechanical" = 1 ] && resolve_mechanical; then
      usage_outcome=MERGE-MECHANICAL
      echo "MERGE-MECHANICAL ${old:0:8} -> $(git -C "$wt" rev-parse --short=8 HEAD)"
      printf '%s\n' "${resolved_lines[@]}"
    else
      usage_outcome=MERGE-CONFLICT
      echo "MERGE-CONFLICT"
      git -C "$wt" diff --name-only --diff-filter=U | sed 's/^/  conflicted: /'
      [ ${#unruled[@]} = 0 ] || printf '  code: %s\n' "${unruled[@]}"
      exit 10
    fi
  fi
fi

[ "$verify_only" = 0 ] || usage_outcome=VERIFY-ONLY
for cmd in "${checks[@]+"${checks[@]}"}"; do
  if ! ( cd "$wt" && bash -c "$cmd" ); then
    usage_outcome=CHECK-FAILED
    echo "CHECK-FAILED $cmd"
    exit 11
  fi
done

if [ -n "$slug" ]; then
  pin=${FM_REVIEW_PIN:-$FM_HOME/data/tools/fm-review-pin.sh}
  work=${FM_PIN_WORK:-/tmp/fm-pins}
  bare=$work/${slug//\//__}.git
  head=$(git -C "$wt" rev-parse HEAD) || exit 3
  if [ ! -x "$pin" ]; then
    echo "PIN-UNAVAILABLE review pin script not found: $pin"
  else
    # Let the pin script create its scratch clone first, then hand it the unpushed head.
    [ -d "$bare" ] || "$pin" check "$slug" "$pr" >/dev/null 2>&1 || true
    if [ -d "$bare" ] && git -C "$bare" fetch -q "$wt" "+HEAD:refs/fmpin/local-pr$pr" 2>/dev/null; then
      "$pin" check "$slug" "$pr" --head "$head" || true
    else
      "$pin" check "$slug" "$pr" || true
    fi
  fi
fi
exit 0
