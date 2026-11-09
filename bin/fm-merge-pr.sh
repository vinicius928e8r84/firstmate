#!/usr/bin/env bash
# fm-merge-pr.sh - merge one reviewed GitHub PR end to end and print ONE result line.
#
# Usage: fm-merge-pr.sh --by captain|yolo [--task ID] [--dry-run] <pr-url> [-- <bin/fm-pr-merge.sh args>]
#
# This composes the pieces that already exist so a merge is one command instead of a
# hand-repeated sequence; it decides nothing. WHO may merge stays with the caller, which
# must name the authority it holds in --by:
#   captain  the captain gave the word for this PR
#   yolo     the project's registered posture is yolo (bin/fm-project-mode.sh must say "on"),
#            and the PR is not HIGH risk (the class rule keeps HIGH on the captain's word)
# Steps, in order; the first refusal stops everything and nothing is merged:
#   1 read     the PR is open, not a draft, mergeStateStatus CLEAN (BEHIND or DIRTY names
#              bin/fm-pr-merge-main.sh as the way to join main)
#   2 review   fm-pr-ready.sh row for this head. When the only gap is a review of an older head,
#              fm-review-pin.sh check decides: PIN-VALID (same patch-id of the PR's own change, only
#              clean main merges added after) re-records the clean review for this head
#              (fm-review-record.sh), anything else leaves the gate to refuse
#   3 gate     fm-merge-gate.sh: head contains the base tip, review/suite/proof of this exact head,
#              head re-read right before the merge, then bin/fm-pr-merge.sh --expected-head. It owns
#              every merge guard (HIGH proof, behind main, red or unreported check); none is relaxed here
#   4 stand-in when no task's state/*.meta carries pr=<url>, a stand-in record is written for the
#              merge and parked in state/parked-<date>/ afterwards, merged or not
#   5 after    fm-post-merge.sh: guarded fleet sync of the clone, teardown of the owning task
#              (never --force), audit row; then one merge-pr audit row naming --by
# Output: exactly one line on stdout.
#   MERGED <repo>#<n> <head8> by=<who> review=<ok|pinned> post=<ok|...>
#   DRY-RUN-OK <repo>#<n> <head8> by=<who> review=<ok|pinned>
#   REFUSED <repo>#<n>: <reason>; <reason>... [log: <file>]
# The full output of every step goes to the log file named on a refusal or a post-merge problem.
# Exit: 0 merged (or dry-run ok), 1 refused, 2 usage, 5 merged but post-merge refused (nothing bypassed).
# Env: FM_HOME, FM_STATE_OVERRIDE, FM_MERGE_PR_GH (gh), FM_READY_BIN, FM_REVIEW_PIN, FM_REVIEW_RECORD,
#      FM_MERGE_GATE, FM_POST_MERGE (the private tools, default $FM_HOME/data/tools/<name>.sh),
#      FM_PROJECT_MODE (default bin/fm-project-mode.sh), FM_PM_AUDIT (audit file), FM_MERGE_PR_NOW (tests).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$HERE/.." && pwd)}; export FM_HOME
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
TOOLS=$FM_HOME/data/tools
GH=${FM_MERGE_PR_GH:-gh}
READY=${FM_READY_BIN:-$TOOLS/fm-pr-ready.sh}
PIN=${FM_REVIEW_PIN:-$TOOLS/fm-review-pin.sh}
RECORD=${FM_REVIEW_RECORD:-$TOOLS/fm-review-record.sh}
GATE=${FM_MERGE_GATE:-$TOOLS/fm-merge-gate.sh}
POST=${FM_POST_MERGE:-$TOOLS/fm-post-merge.sh}
MODE=${FM_PROJECT_MODE:-$HERE/fm-project-mode.sh}
AUDIT=${FM_PM_AUDIT:-$FM_HOME/data/audit-2026-10-05.tsv}
REVIEWS=${FM_REVIEWS_DIR:-$FM_HOME/data/reviews}

usage() { sed -n 2,6p "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
by=; task=; dry=0; url=
while [ $# -gt 0 ]; do case "$1" in
  --by) [ $# -ge 2 ] || usage; by=$2; shift 2 ;;
  --task) [ $# -ge 2 ] || usage; task=$2; shift 2 ;;
  --dry-run) dry=1; shift ;;
  -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --) shift; break ;;
  *) [ -z "$url" ] || usage; url=$1; shift ;;
esac; done
extra=("$@")
[ -n "$url" ] || usage
case "$by" in captain|yolo) ;; *) usage ;; esac
[[ $url =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]] || { echo "REFUSED $url: not a GitHub pull request URL"; exit 1; }
slug=${BASH_REMATCH[1]}/${BASH_REMATCH[2]}; repo=${BASH_REMATCH[2]}; num=${BASH_REMATCH[3]}; tag="$repo#$num"

LOG=$(mktemp "${TMPDIR:-/tmp}/fm-merge-pr.XXXXXX"); standin=; reasons=()
cleanup() {
  if [ -n "$standin" ]; then
    local parked
    parked=$STATE/parked-$(date -u +%Y%m%d)
    mkdir -p "$parked"; mv "$STATE/$standin".* "$parked"/ 2>/dev/null
  fi
}
trap cleanup EXIT
refuse() { reasons+=("$*"); }
finish_refused() {
  local out=$tag: r first=1
  for r in "${reasons[@]}"; do [ $first = 1 ] && out="$out $r" || out="$out; $r"; first=0; done
  echo "REFUSED $out [log: $LOG]"; exit 1
}
need() { [ -x "$2" ] || { refuse "$1 is missing or not executable: $2 (no guard is skipped; install it or set the env override)"; finish_refused; }; }
need fm-pr-ready "$READY"; need fm-review-pin "$PIN"; need fm-review-record "$RECORD"; need fm-merge-gate "$GATE"; need fm-post-merge "$POST"

# 1 read
view=$("$GH" pr view -R "$slug" "$num" --json state,isDraft,headRefOid,headRefName,mergeStateStatus 2>>"$LOG") || { refuse "cannot read the PR: $(tail -1 "$LOG")"; finish_refused; }
head=$(jq -r .headRefOid <<<"$view"); ref=$(jq -r .headRefName <<<"$view"); ms=$(jq -r .mergeStateStatus <<<"$view")
[ "$(jq -r .state <<<"$view")" = OPEN ] || refuse "the PR is not open"
[ "$(jq -r .isDraft <<<"$view")" = false ] || refuse "the PR is a draft"
case "$ms" in
  CLEAN|HAS_HOOKS) ;;
  BEHIND|DIRTY) refuse "merge state $ms: join main first with bin/fm-pr-merge-main.sh, then re-test the new head" ;;
  *) refuse "merge state $ms: a check is red, pending or missing, or a rule blocks the merge" ;;
esac
[ ${#reasons[@]} = 0 ] || finish_refused

# 2 review (and the yolo class rule)
rows=$("$READY" --repo "$slug" --json --no-cache 2>>"$LOG") || { refuse "fm-pr-ready failed: $(tail -1 "$LOG")"; finish_refused; }
row=$(jq -c --argjson n "$num" '.rows[] | select(.pr == $n)' <<<"$rows" 2>/dev/null)
[ -n "$row" ] || { refuse "fm-pr-ready does not list this PR"; finish_refused; }
if [ "$by" = yolo ]; then
  read -r _ yolo_on < <("$MODE" "$repo" 2>/dev/null)
  [ "${yolo_on:-off}" = on ] || refuse "by=yolo but $repo is not registered with yolo on; the captain's word is needed (--by captain)"
  [ "$(jq -r .risk <<<"$row")" != HIGH ] || refuse "by=yolo on a HIGH risk PR; HIGH merges only on the captain's word (--by captain)"
fi
[ ${#reasons[@]} = 0 ] || finish_refused
review=ok
if [ "$(jq -r .review <<<"$row")" = stale ]; then
  review=pinned
  pinout=$("$PIN" check "$slug" "$num" --head "$head" 2>>"$LOG"); echo "$pinout" >> "$LOG"
  rec=$REVIEWS/${slug//\//-}-$num.json
  if [[ $pinout == PIN-VALID* ]] && [ "$(jq -r '.verdict' "$rec" 2>/dev/null)" = clean ] && [ "$(jq -r '.open_findings' "$rec" 2>/dev/null)" = 0 ]; then
    old=$(jq -r .reviewed_head "$rec")
    if [ $dry = 0 ] && ! "$RECORD" write "$slug" "$num" --head "$head" --verdict clean --open-findings 0 \
         --reviewer "pin: review of ${old:0:8} still applies (same patch-id)" --report "$(jq -r '.report // empty' "$rec")" >>"$LOG" 2>&1; then
      refuse "the review pin is valid but the record could not be refreshed"; finish_refused
    fi
  else
    refuse "review is of an older head and the pin does not carry it: ${pinout:-no pin output}"; finish_refused
  fi
fi

# 4 stand-in (the gate finds the owning task by pr= in state/*.meta)
if [ -z "$task" ]; then
  owners=()
  for m in "$STATE"/*.meta; do [ -f "$m" ] || continue; grep -qxF "pr=$url" "$m" && owners+=("$(basename "$m" .meta)"); done
  if [ ${#owners[@]} -gt 1 ]; then refuse "several tasks claim $url (${owners[*]}); pass --task <id>"; finish_refused; fi
  task=${owners[0]:-}
fi
if [ -z "$task" ]; then
  task=${repo}-pr$num-standin
  if [ $dry = 0 ]; then
    standin=$task
    printf 'kind=ship\nmode=direct-PR\nyolo=%s\nbranch=%s\nworktree=%s\nproject=%s\npr=%s\npr_head=%s\n' \
      "$([ "$by" = yolo ] && echo on || echo off)" "$ref" "$FM_HOME/projects/$repo" "$FM_HOME/projects/$repo" "$url" "$head" > "$STATE/$task.meta"
  fi
fi

# 3 gate (which calls bin/fm-pr-merge.sh --expected-head)
if [ $dry = 1 ] && [ "$review" = pinned ]; then
  echo "DRY-RUN-OK $tag ${head:0:8} by=$by review=pinned (gate not run: it needs the refreshed review record)"; rm -f "$LOG"; exit 0
fi
gate_args=(--task "$task"); [ $dry = 1 ] && gate_args+=(--dry-run)
"$GATE" "${gate_args[@]}" "$url" -- "${extra[@]}" >"$LOG.gate" 2>&1; rc=$?
cat "$LOG.gate" >> "$LOG"; rm -f "$LOG.gate"
if [ $rc != 0 ]; then
  while IFS= read -r l; do case "$l" in REFUSED:*) refuse "${l#REFUSED: }" ;; esac; done <"$LOG"
  [ ${#reasons[@]} -gt 0 ] || refuse "merge step exited $rc: $(grep -v '^WARNING' "$LOG" | tail -1 | cut -c1-200)"
  finish_refused
fi
if [ $dry = 1 ]; then echo "DRY-RUN-OK $tag ${head:0:8} by=$by review=$review"; rm -f "$LOG"; exit 0; fi

# 5 after
[ -z "$standin" ] || { cleanup; standin=; }
"$POST" "$url" >>"$LOG" 2>&1; prc=$?
post=ok; [ $prc = 0 ] || post="exit-$prc"
ts=${FM_MERGE_PR_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
mkdir -p "$(dirname "$AUDIT")"; [ -s "$AUDIT" ] && [ -n "$(tail -c1 "$AUDIT")" ] && echo >> "$AUDIT"
printf '%s\tmerge-pr\t%s PR %s merged\tauthority=%s\tfm-merge-pr.sh %s\thead=%s; review=%s; post=%s\n' "$ts" "$repo" "$num" "$by" "$url" "${head:0:8}" "$review" "$post" >> "$AUDIT"
echo "MERGED $tag ${head:0:8} by=$by review=$review post=$post$([ "$post" = ok ] || echo " [log: $LOG]")"
[ "$post" = ok ] && { rm -f "$LOG"; exit 0; }
exit 5
