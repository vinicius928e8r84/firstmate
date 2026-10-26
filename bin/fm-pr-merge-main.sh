#!/usr/bin/env bash
# fm-pr-merge-main.sh - merge the base branch into a PR branch deterministically.
#
# Usage:
#   fm-pr-merge-main.sh --worktree DIR [--remote origin] [--base main]
#                       [--check CMD]... [--slug OWNER/REPO --pr N] [--verify-only]
#
# The routine "bring this PR up to date with main" step, done by a script so a
# model is only needed when the merge truly conflicts. In the PR branch worktree
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
# --verify-only skips the fetch and merge and runs only the checks and the pin
# report on DIR's current head, for use after a model resolved a conflict and
# committed.
#
# Result lines (one is always printed first after the work starts):
#   ALREADY-CURRENT <remote>/<base>   nothing to merge
#   MERGE-CLEAN <old> -> <new>        merged without conflict
#   MERGE-CONFLICT                    stopped; the merge is left in progress in
#                                     DIR and the conflicted files follow, one
#                                     per line as "  conflicted: <path>"
#   CHECK-FAILED <command>            a --check command failed (output above it)
# Exit status: 0 merged or current and every check passed, 2 usage, 3 refused
# or git error (dirty worktree, merge already in progress, fetch failed),
# 10 conflict, 11 a check failed.
set -uo pipefail

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() { sed -n 2,40p "$0"; }

wt= remote=origin base=main slug= pr= verify_only=0
checks=()
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) wt=${2:-}; shift 2 ;;
    --remote) remote=${2:-}; shift 2 ;;
    --base) base=${2:-}; shift 2 ;;
    --check) checks+=("${2:-}"); shift 2 ;;
    --slug) slug=${2:-}; shift 2 ;;
    --pr) pr=${2:-}; shift 2 ;;
    --verify-only) verify_only=1; shift ;;
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

if [ "$verify_only" = 0 ]; then
  [ ! -e "$git_dir/MERGE_HEAD" ] || { echo "a merge is already in progress in $wt" >&2; exit 3; }
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ] || { echo "worktree has uncommitted changes: $wt" >&2; exit 3; }
  git -C "$wt" fetch -q "$remote" "$base" || { echo "fetch $remote $base failed" >&2; exit 3; }
  target=$(git -C "$wt" rev-parse "FETCH_HEAD^{commit}") || exit 3
  old=$(git -C "$wt" rev-parse HEAD) || exit 3
  if git -C "$wt" merge-base --is-ancestor "$target" "$old"; then
    echo "ALREADY-CURRENT $remote/$base"
  elif git -C "$wt" merge --no-edit "$target" >/dev/null 2>&1; then
    echo "MERGE-CLEAN ${old:0:8} -> $(git -C "$wt" rev-parse --short=8 HEAD)"
  else
    if [ -e "$git_dir/MERGE_HEAD" ]; then
      echo "MERGE-CONFLICT"
      git -C "$wt" diff --name-only --diff-filter=U | sed 's/^/  conflicted: /'
      exit 10
    fi
    echo "merge failed without a conflict state in $wt" >&2
    exit 3
  fi
fi

for cmd in "${checks[@]+"${checks[@]}"}"; do
  if ! ( cd "$wt" && bash -c "$cmd" ); then
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
