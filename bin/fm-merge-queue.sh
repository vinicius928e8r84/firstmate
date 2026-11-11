#!/usr/bin/env bash
# fm-merge-queue.sh - join main into ONLY the PR whose turn it is, wait for its CI, merge it, take the next. No model.
#
# Usage:
#   fm-merge-queue.sh --slug OWNER/REPO --by captain|yolo [--order "N N ..."] [--limit N]
#                     [--wait SECONDS] [--check CMD]... [--dry-run] [--work DIR]
#
# Retires the rework of every open PR re-joining main after each merge: the queue is a plain
# loop around scripts that already exist, and it never asks for a model. Per turn:
#   1 pick     the first PR of the order that is eligible: not a draft, a clean review record
#              (fm-pr-ready row review ok, or stale when only the review pin can carry it) and CI not
#              red. An ineligible PR ahead of it is skipped with one "SKIP" line, it does not block
#              the PRs behind it. The order is --order, else the private fm-merge-order.sh
#              (FM_MQ_ORDER_BIN) output for the repo.
#   2 join     only when the PR is BEHIND or DIRTY: in the queue's own scratch clone (never the
#              project's clone, never the owner's worktree) bin/fm-pr-merge-main.sh --mechanical
#              merges the base into the PR branch (a plain merge, never a rebase), then the new
#              head is pushed to the PR branch WITHOUT force (a rejected push stops the queue).
#              Only conflicts that config/merge-mechanical covers are settled by script
#              (docs/configuration.md); a conflict in code stops the queue.
#   3 wait     poll fm-pr-ready until it reports the new head with CI green, at most --wait seconds
#              (default 3600); red stops the queue, an exhausted wait stops it too (run again later
#              and it resumes from the PR's live state, nothing is held between runs).
#   4 merge    bin/fm-merge-pr.sh --by <who> <url>, which keeps every merge guard: it refuses a PR
#              behind main, a missing or stale review the pin cannot carry, a red or unreported
#              check, HIGH risk under --by yolo. A merge it refuses stops the queue.
#   then the next PR, with main moved, starts again at 1. One PR is ever touched at a time.
# --by is mandatory and passed to fm-merge-pr.sh unchanged: this script decides nothing about WHO
# may merge. --dry-run does steps 1-2 locally in the scratch clone (nothing is pushed, nothing is
# merged) and prints what the real run would do. --limit N stops after N merges.
# Off switch: a file $FM_HOME/config/merge-queue-off makes every run print DISABLED and do nothing.
# One run per repo at a time (flock on the scratch directory).
#
# Output, one line per event, always ending with exactly one of these:
#   SKIP #N: <why>                          not eligible, left alone
#   JOINED #N <old> -> <new> [clean|mechanical: paths]   pushed (dry-run: WOULD-JOIN, not pushed)
#   WAITING #N <head8>                      CI of the new head is running
#   MERGED <repo>#N ...                     fm-merge-pr.sh's line, passed through
#   DONE merged=<n>                         the queue is empty or --limit reached
#   STOPPED #N: <one line reason>           the queue stops here, in a state a person can read
#   DISABLED / DRY-RUN-OK merged=0 joined=<n>
# Exit: 0 DONE, DISABLED or DRY-RUN-OK; 1 refused by fm-merge-pr.sh or a CI/wait stop; 2 usage;
# 3 environment or git/gh error; 10 conflict in code; 11 a --check failed.
# Env: FM_HOME, FM_CONFIG_OVERRIDE, FM_MQ_GH (gh), FM_READY_BIN,
#      FM_MQ_ORDER_BIN, FM_MQ_MERGE_PR (default bin/fm-merge-pr.sh), FM_MQ_CLONE_URL (default
#      https://github.com/<slug>.git), FM_MQ_WORK (scratch parent), FM_MQ_POLL (seconds, default 30).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$HERE/.." && pwd)
FM_HOME=${FM_HOME:-$FM_ROOT}; export FM_HOME
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
GH=${FM_MQ_GH:-gh}
READY=${FM_READY_BIN:-$FM_HOME/data/tools/fm-pr-ready.sh}
ORDER_BIN=${FM_MQ_ORDER_BIN:-$FM_HOME/data/tools/fm-merge-order.sh}
MERGE_PR=${FM_MQ_MERGE_PR:-$HERE/fm-merge-pr.sh}
MERGE_MAIN=$HERE/fm-pr-merge-main.sh
POLL=${FM_MQ_POLL:-30}

# shellcheck source=bin/fm-usage-ledger-lib.sh
. "$HERE/fm-usage-ledger-lib.sh"

usage() { sed -n 2,46p "$0" >&2; exit 2; }

slug='' by='' order_arg='' limit=0 wait_s=3600 dry=0 work_arg=''
checks=()
while [ $# -gt 0 ]; do
  case "$1" in
    --slug|--by|--order|--limit|--wait|--check|--work) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --slug) slug=$2; shift 2 ;;
    --by) by=$2; shift 2 ;;
    --order) order_arg=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --wait) wait_s=$2; shift 2 ;;
    --check) checks+=("$2"); shift 2 ;;
    --work) work_arg=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n 2,46p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ $slug =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "--slug OWNER/REPO is required" >&2; usage; }
case "$by" in captain|yolo) ;; *) echo "--by captain|yolo is required: this script decides nothing about who may merge" >&2; usage ;; esac
[[ $limit =~ ^[0-9]+$ ]] && [[ $wait_s =~ ^[0-9]+$ ]] && [[ $POLL =~ ^[0-9]+$ ]] || { echo "--limit, --wait and FM_MQ_POLL are whole numbers" >&2; usage; }

if [ -e "$CONFIG/merge-queue-off" ]; then echo "DISABLED $CONFIG/merge-queue-off exists; remove it to run the queue"; exit 0; fi
for t in "$READY" "$MERGE_PR" "$MERGE_MAIN"; do [ -x "$t" ] || { echo "STOPPED: tool missing or not executable: $t" ; exit 3; }; done

work=${work_arg:-${FM_MQ_WORK:-${TMPDIR:-/tmp}/fm-merge-queue}/${slug//\//__}}
clone_url=${FM_MQ_CLONE_URL:-https://github.com/$slug.git}
mkdir -p "$(dirname "$work")" || exit 3
exec 9>"$work.lock"
flock -n 9 || { echo "STOPPED: another merge queue run holds $work.lock"; exit 3; }

merged=0 joined=0 skipped=' ' picked='' new_head=''
stop() { # <pr> <rc> <reason>: the one line the queue ends on
  fm_usage_record fm-merge-queue STOPPED "$1" merge
  echo "STOPPED #$1: $3"; exit "$2"
}
ready_rows() { "$READY" --repo "$slug" --json --no-cache 2>/dev/null; }
row_of() { jq -c --argjson n "$1" '.rows[] | select(.pr == $n)' <<<"$2" 2>/dev/null; }

order=()
if [ -n "$order_arg" ]; then
  read -r -a order <<<"${order_arg//[#,]/ }"
else
  [ -x "$ORDER_BIN" ] || { echo "STOPPED: no --order and the order tool is missing: $ORDER_BIN"; exit 3; }
  mapfile -t order < <("$ORDER_BIN" "$slug" 2>/dev/null | sed -n 's/^ *#\([0-9][0-9]*\) .*/\1/p')
fi
[ ${#order[@]} -gt 0 ] || { echo "DONE merged=0 (the order is empty)"; exit 0; }
for n in "${order[@]}"; do [[ $n =~ ^[0-9]+$ ]] || { echo "the order holds PR numbers only, got '$n'" >&2; exit 2; }; done

# pick_pr: set picked to the number of the first eligible PR of the order (empty when none); SKIP lines print once each.
pick_pr() {
  local rows n row why review ci draft
  picked=
  rows=$(ready_rows) || { echo "STOPPED: fm-pr-ready failed for $slug"; exit 3; }
  for n in "${order[@]}"; do
    row=$(row_of "$n" "$rows")
    why=
    if [ -z "$row" ]; then why="not an open PR the readiness list knows"
    else
      review=$(jq -r .review <<<"$row"); ci=$(jq -r .ci.state <<<"$row"); draft=$(jq -r .draft <<<"$row")
      if [ "$draft" = true ]; then why="draft"
      elif [ "$review" != ok ] && [ "$review" != stale ]; then why="review is $review"
      elif [ "$ci" = red ]; then why="CI is red"
      fi
    fi
    if [ -z "$why" ]; then picked=$n; return 0; fi
    case "$skipped" in *" $n "*) ;; *) skipped="$skipped$n "; echo "SKIP #$n: $why" ;; esac
  done
}

prepare_scratch() { # <ref> <expected head>: the scratch clone sits on the PR branch's remote head
  if [ -d "$work/.git" ]; then
    git -C "$work" merge --abort >/dev/null 2>&1
    git -C "$work" fetch -q origin >/dev/null 2>&1 || return 1
  else
    git clone -q "$clone_url" "$work" >/dev/null 2>&1 || return 1
  fi
  git -C "$work" fetch -q origin "$1" || return 1
  git -C "$work" checkout -q -f -B "$1" FETCH_HEAD >/dev/null 2>&1 || return 1
  git -C "$work" clean -fdq
  [ "$(git -C "$work" rev-parse HEAD)" = "$2" ]
}

# join_main <pr> <ref> <base> <head>: bring the PR up to date with its base; sets new_head.
join_main() {
  local n=$1 ref=$2 base=$3 head=$4 out rc args first files
  prepare_scratch "$ref" "$head" || stop "$n" 3 "cannot get the PR branch $ref at ${head:0:8} into the scratch clone (it moved, or the fetch failed)"
  args=(--worktree "$work" --remote origin --base "$base" --mechanical)
  for c in "${checks[@]+"${checks[@]}"}"; do args+=(--check "$c"); done
  out=$("$MERGE_MAIN" "${args[@]}" 2>&1); rc=$?
  first=$(printf '%s\n' "$out" | sed -n 1p)
  case $rc in
    0) ;;
    10)
      files=$(printf '%s\n' "$out" | sed -n 's/^  code: //p' | paste -sd, -)
      git -C "$work" merge --abort >/dev/null 2>&1
      stop "$n" 10 "conflict in code (${files:-see the PR}); a person or a model must resolve it, the queue does not guess"
      ;;
    11) git -C "$work" reset -q --hard "$head"; stop "$n" 11 "a --check failed after joining ${base}: $(printf '%s\n' "$out" | grep -m1 '^CHECK-FAILED')" ;;
    *) stop "$n" 3 "fm-pr-merge-main refused: $(printf '%s\n' "$out" | tail -1 | cut -c1-200)" ;;
  esac
  new_head=$(git -C "$work" rev-parse HEAD)
  case $first in
    ALREADY-CURRENT*) echo "JOINED #$n ${head:0:8} -> ${head:0:8} (already current)"; return 0 ;;
    MERGE-MECHANICAL*) files=$(printf '%s\n' "$out" | sed -n 's/^  resolved: //p' | paste -sd, -); detail="mechanical: $files" ;;
    *) detail=clean ;;
  esac
  if [ $dry = 1 ]; then echo "WOULD-JOIN #$n ${head:0:8} -> ${new_head:0:8} ($detail), not pushed"; joined=$((joined + 1)); return 0; fi
  # A plain push: if the branch moved meanwhile it is refused and the queue stops, never forced.
  git -C "$work" push -q origin "HEAD:refs/heads/$ref" >/dev/null 2>&1 || stop "$n" 3 "push of the joined head to $ref was refused (the branch moved?); nothing was forced"
  joined=$((joined + 1))
  fm_usage_record fm-merge-queue JOINED "$n" merge
  echo "JOINED #$n ${head:0:8} -> ${new_head:0:8} ($detail)"
}

# wait_ci <pr> <head>: 0 when fm-pr-ready reports this head with CI green; stops on red or when the wait runs out.
wait_ci() {
  local n=$1 head=$2 rows row ci ms rhead t0=$SECONDS announced=0
  while :; do
    rows=$(ready_rows); row=$(row_of "$n" "$rows")
    if [ -n "$row" ]; then
      rhead=$(jq -r .head <<<"$row"); ci=$(jq -r .ci.state <<<"$row"); ms=$(jq -r .merge_state <<<"$row")
      if [ "$rhead" = "$head" ]; then
        [ "$ci" != red ] || stop "$n" 1 "CI is red on ${head:0:8} (not merged, not touched again)"
        # GitHub still computing its merge state right after a push is not a reason to ask fm-merge-pr yet
        if [ "$ci" = green ]; then case "$ms" in BEHIND|DIRTY|UNKNOWN) ;; *) return 0 ;; esac; fi
      fi
    fi
    [ $announced = 1 ] || { echo "WAITING #$n ${head:0:8}"; announced=1; }
    [ $((SECONDS - t0)) -lt "$wait_s" ] || stop "$n" 1 "CI of ${head:0:8} still not green after ${wait_s}s; run the queue again later to resume"
    sleep "$POLL"
  done
}

while :; do
  [ "$limit" = 0 ] || [ "$merged" -lt "$limit" ] || break
  pick_pr
  [ -n "$picked" ] || break
  n=$picked
  view=$("$GH" pr view -R "$slug" "$n" --json headRefOid,headRefName,baseRefName,isCrossRepository,state 2>/dev/null) \
    || stop "$n" 3 "cannot read the PR from GitHub"
  head=$(jq -r .headRefOid <<<"$view"); ref=$(jq -r .headRefName <<<"$view"); base=$(jq -r .baseRefName <<<"$view")
  [ "$(jq -r .state <<<"$view")" = OPEN ] || stop "$n" 1 "the PR is not open"
  [ "$(jq -r .isCrossRepository <<<"$view")" = false ] || stop "$n" 1 "the PR comes from a fork; the queue pushes only to branches of $slug"
  # Joined by git, not by GitHub's merge state: right after a merge GitHub still calls the next PR CLEAN for a while.
  join_main "$n" "$ref" "$base" "$head"
  if [ $dry = 1 ]; then echo "DRY-RUN-OK merged=0 joined=$joined (first PR only: the rest depend on main moving)"; exit 0; fi
  head=$new_head
  wait_ci "$n" "$head"
  url=$(jq -r '.url // empty' <<<"$(row_of "$n" "$(ready_rows)")")
  [ -n "$url" ] || url=https://github.com/$slug/pull/$n
  out=$("$MERGE_PR" --by "$by" "$url" 2>&1); mrc=$?
  line=$(printf '%s\n' "$out" | tail -1)
  echo "$line"
  case "$line" in
    MERGED*) merged=$((merged + 1)); skipped="$skipped$n "; fm_usage_record fm-merge-queue MERGED "$n" merge
      [ $mrc = 0 ] || stop "$n" 1 "merged, but the post-merge step needs a person (line above)" ;;
    *) stop "$n" 1 "fm-merge-pr.sh did not merge it (line above); the PRs behind it wait" ;;
  esac
done
fm_usage_record fm-merge-queue DONE - merge
echo "DONE merged=$merged"
exit 0
