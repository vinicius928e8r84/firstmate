#!/usr/bin/env bash
# fm-review-sweep.sh - open the independent review of every open PR head that has none, with no model in the loop.
# It replaces data/tools/fm-review-launch.sh (a request to a secondmate, which failed whenever the mate was idle): each review is a
# scout this script spawns itself through bin/fm-spawn-task.sh, from a fixed text with the PR URL, exact head, project and risk level.
#
# Usage: fm-review-sweep.sh [--dry-run] [--repo owner/repo ...]
#   default repos: vinicius928e8r84/{multimodel-core,PerpetualMiner,modo-caverna}; the project is the repo name under projects/
#   --dry-run  prints "WOULD OPEN ..." / "WOULD HARVEST ..." lines and changes nothing (no lock, spawn, registry write or review record)
# For each open PR row of data/tools/fm-pr-ready.sh --json it opens ONE review scout when ALL hold:
#   - review is none or stale (a head with any review record is never reviewed again), whatever CI says: a red, absent or pending CI
#     must not hold back the FIRST review
#   - not a draft, and verdict is not NEEDS-UPDATE (behind main or conflicting: the head will change, review it after the update)
#   - this exact head was not requested before: registry $DIR/requests.tsv (epoch repo pr head status id risk note), the LAST status of
#     the head decides; SPAWNED/HARVESTED/UNPARSED count as requested, DEFERRED/FAILED/LOST do not (they are retried next sweep)
# There is NO cap on simultaneous reviews. The only brakes are the spawn's own slot ceiling (a refusal with exit 75 is recorded
# DEFERRED and retried next sweep; the task id is derived from repo, PR and head, so a retry resumes the same brief and never
# duplicates), the per-head registry, and the sweep lock (a second sweep exits at once with SWEEP-BUSY).
# Scout profile: HIGH risk runs on Opus ($FM_REVIEW_SWEEP_OPUS, pi claude-opus-5-5 high); other levels follow bin/fm-dispatch-resolve.sh,
# falling back to the same Opus profile only when the resolver cannot give a clear answer. bin/fm-spawn-task.sh runs the launch check
# (data/tools/fm-verify-launch.sh) after every spawn.
# Harvest (start of every non-dry sweep): a SPAWNED review whose data/<id>/report.md exists is read. Line 1 must be "CLEAN <head>" or
# "NOT CLEAN <head>" with the requested head (>=7 hex chars of it); the result is written with fm-review-record.sh (verdict clean|findings,
# open findings = the report's "Blocking findings (P0/P1): N" line, else 0 for CLEAN and the P0/P1 lines counted, at least 1, for NOT CLEAN)
# and a clean one is pinned with fm-review-pin.sh, so fm-merge-pr.sh sees it. A report that does not parse is marked UNPARSED and printed,
# never retried. A SPAWNED review with no live task, no report and older than $FM_REVIEW_SWEEP_GRACE seconds (21600) is marked LOST
# and the head is reviewed again under a new id suffix.
# It only reads GitHub through fm-pr-ready.sh: it never merges, comments or pushes. Run it by hand or from cron every 15 minutes.
# Output: one line per decision (OPEN, WOULD OPEN, SKIP, DEFER, FAIL, HARVEST, LOST) and a final SUMMARY line.
# Exit: 0 ok (whatever the decisions), 3 fm-pr-ready failed or the registry could not be written, 2 usage.
# Env: FM_HOME, FM_REVIEW_SWEEP_DIR (default data/review-sweep), FM_READY_BIN, FM_RECORD_BIN, FM_PIN_BIN, FM_SPAWN_TASK_BIN (default
#      bin/fm-spawn-task.sh), FM_REVIEW_RULES_BIN (default bin/fm-review-rules.sh), FM_REVIEW_SWEEP_OPUS, FM_REVIEW_SWEEP_GRACE,
#      FM_REVIEW_SWEEP_NOW (epoch, tests).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$HERE/.." && pwd)}; export FM_HOME
TOOLS=$FM_HOME/data/tools
READY=${FM_READY_BIN:-$TOOLS/fm-pr-ready.sh}
RECORD=${FM_RECORD_BIN:-$TOOLS/fm-review-record.sh}
PIN=${FM_PIN_BIN:-$TOOLS/fm-review-pin.sh}
SPAWN_TASK=${FM_SPAWN_TASK_BIN:-$HERE/fm-spawn-task.sh}
RULES=${FM_REVIEW_RULES_BIN:-$HERE/fm-review-rules.sh}
OPUS=${FM_REVIEW_SWEEP_OPUS:---harness pi --model claude-bridge/claude-opus-5-5 --effort high}
GRACE=${FM_REVIEW_SWEEP_GRACE:-21600}
DIR=${FM_REVIEW_SWEEP_DIR:-$FM_HOME/data/review-sweep}; REG=$DIR/requests.tsv
now() { echo "${FM_REVIEW_SWEEP_NOW:-$(date +%s)}"; }

dry=0; repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --repo) [ $# -ge 2 ] || { echo "--repo needs owner/repo" >&2; exit 2; }; repos+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[ ${#repos[@]} -gt 0 ] || repos=(vinicius928e8r84/multimodel-core vinicius928e8r84/PerpetualMiner vinicius928e8r84/modo-caverna)

abbr_of() { case "${1##*/}" in multimodel-core) echo mmc ;; PerpetualMiner) echo pm ;; modo-caverna) echo mc ;; *) echo "${1##*/}" | tr -c 'A-Za-z0-9\n' '-' | cut -c1-8 ;; esac; }
label_of() { case "$1" in HIGH) echo ALTA ;; MEDIUM) echo MEDIA ;; LOW) echo BAIXA ;; *) echo "$1" ;; esac; }

if [ $dry = 1 ]; then
  [ -f "$REG" ] || REG=/dev/null
else
  { mkdir -p "$DIR/specs" && touch "$REG"; } || { echo "fm-review-sweep: cannot write $DIR" >&2; exit 3; }
  exec 8>"$DIR/.lock"
  flock -n 8 || { echo "SWEEP-BUSY another review sweep is running"; exit 0; }
fi
reg_add() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}" >> "$REG"; }
# last_status <repo> <pr> <head>: the newest status row of that head, empty when none
last_status() { awk -F'\t' -v r="$1" -v p="$2" -v h="$3" '$2==r && $3==p && $4==h {s=$5} END{print s}' "$REG"; }
# lost_count <repo> <pr> <head>: earlier attempts that were lost, the id suffix of the next one
lost_count() { awk -F'\t' -v r="$1" -v p="$2" -v h="$3" '$2==r && $3==p && $4==h && $5=="LOST" {n++} END{print n+0}' "$REG"; }
review_id() { # <repo> <pr> <head>
  local n; n=$(lost_count "$1" "$2" "$3")
  echo "rv-$(abbr_of "$1")$2-${3:0:8}$([ "$n" = 0 ] || echo "-r$n")"
}

# ---- harvest: write the review record of every finished review ------------------------------------------------------------------------
harvest() {
  local repo pr head id risk ep report first verdict hpre open st
  # the newest row per head, SPAWNED only
  while IFS=$'\t' read -r ep repo pr head st id risk _; do
    [ "$st" = SPAWNED ] || continue
    [ "$(last_status "$repo" "$pr" "$head")" = SPAWNED ] || continue
    [ "$(review_id "$repo" "$pr" "$head")" = "$id" ] || continue
    report=$FM_HOME/data/$id/report.md
    if [ ! -s "$report" ]; then
      if [ ! -e "$FM_HOME/state/$id.meta" ] && [ $(( $(now) - ep )) -ge "$GRACE" ]; then
        if [ $dry = 1 ]; then echo "WOULD MARK LOST ${repo##*/}#$pr head ${head:0:8} ($id has no task and no report)"
        else reg_add "$repo" "$pr" "$head" LOST "$id" "$risk" "no live task and no report"; echo "LOST ${repo##*/}#$pr head ${head:0:8} ($id has no task and no report); it will be reviewed again"; fi
      fi
      continue
    fi
    first=$(grep -m1 . "$report" | sed 's/\*//g')
    verdict=""; case "$first" in "NOT CLEAN"*|"Not clean"*) verdict=findings ;; CLEAN*|Clean*) verdict=clean ;; esac
    hpre=$(grep -oiE '\b[0-9a-f]{7,40}\b' <<<"$first" | head -1 | tr 'A-F' 'a-f')
    if [ -z "$verdict" ] || [ -z "$hpre" ] || [ "${head#"$hpre"}" = "$head" ]; then
      if [ $dry = 1 ]; then echo "WOULD MARK UNPARSED ${repo##*/}#$pr ($id: line 1 is not CLEAN|NOT CLEAN <requested head>)"
      else reg_add "$repo" "$pr" "$head" UNPARSED "$id" "$risk" "line 1 not CLEAN|NOT CLEAN <head>"; echo "HARVEST ${repo##*/}#$pr: $id report does not start with CLEAN|NOT CLEAN <requested head>; mark it by hand with fm-review-record.sh"; fi
      continue
    fi
    open=$(sed -nE 's/.*[Bb]locking findings[^:]*:[^0-9]*([0-9]+).*/\1/p' "$report" | head -1)
    if [ -z "$open" ]; then
      if [ $verdict = clean ]; then open=0; else open=$(grep -cE '^[^A-Za-z0-9]*(P0|P1)\b' "$report"); [ "$open" -ge 1 ] || open=1; fi
    fi
    [ $verdict = clean ] && [ "$open" != 0 ] && verdict=findings
    [ $verdict = clean ] || [ "$open" -ge 1 ] || open=1
    if [ $dry = 1 ]; then echo "WOULD HARVEST ${repo##*/}#$pr head ${head:0:8} $verdict open=$open ($id)"; continue; fi
    if "$RECORD" write "$repo" "$pr" --head "$head" --verdict "$verdict" --open-findings "$open" --reviewer "scout:$id" --risk "${risk:-UNKNOWN}" --report "$report" >/dev/null 2>&1; then
      reg_add "$repo" "$pr" "$head" HARVESTED "$id" "$risk" "$verdict open=$open"
      echo "HARVEST ${repo##*/}#$pr head ${head:0:8} $verdict open=$open ($id)"
      [ $verdict = clean ] && { "$PIN" record "$repo" "$pr" "$head" "$report" >/dev/null 2>&1 || echo "HARVEST ${repo##*/}#$pr: review pin not stored (fm-review-pin.sh failed); fm-merge-pr will use the exact-head record"; }
    else
      echo "HARVEST ${repo##*/}#$pr: fm-review-record.sh refused the record of $id; retried next sweep"
    fi
  done < <(cat "$REG")
}
harvest

# ---- the open PRs ---------------------------------------------------------------------------------------------------------------------
args=(); for r in "${repos[@]}"; do args+=(--repo "$r"); done
ERRF=$(mktemp); trap 'rm -f "$ERRF"' EXIT
rows=$("$READY" "${args[@]}" --json 2>"$ERRF") || { echo "fm-review-sweep: fm-pr-ready failed: $(head -2 "$ERRF")" >&2; exit 3; }

spec_text() { # <repo> <pr> <head> <url> <project> <risk> <id> <review> <prior-head>
  local repo=$1 pr=$2 head=$3 url=$4 project=$5 risk=$6 id=$7 review=$8 prior=$9
  cat <<SPEC
- Scout, read-only: never commit, push, merge or comment on GitHub. Write only data/$id/report.md.
- Review exactly head $head of $repo#$pr ($url). Re-read the head with gh pr view $pr -R $repo --json headRefOid first; if it moved, say so in the report and still review $head.
- Review the code INTEGRATED with the current base branch, not the old base: in a scratch copy of projects/$project merge the head into the tip of the PR's base branch (origin/main unless the PR is stacked) and read and test that result.
- Two axes: Standards (the repo's own documented coding standards and AGENTS.md/CLAUDE.md) and Spec (does the change do what the issue and the PR body asked, and nothing else; is the PR body honest and about THIS PR; is CI at this head green or why not).
- Score every finding frequency (1-10) x severity (1-10) and give it a P-level. Product below 5: only a comment, do not ask for a fix and do not open an issue. 5 or more: fix. Only P0 and P1 block the merge and make the verdict NOT CLEAN.
- Risk level $(label_of "$risk") ($risk by the deterministic classifier).$([ "$risk" = HIGH ] && echo " Be exact: prove each claim on this head, not by reading alone.")$([ -n "$prior" ] && echo " An earlier review covered $prior: for the part that did not change read the bin/fm-review-delta.sh packet instead of the whole PR, and review the rest in full.")
- Report in data/$id/report.md, one screen. Line 1: CLEAN $head or NOT CLEAN $head (the full head sha). Line 2: Blocking findings (P0/P1): N. Then the findings with P-level and score, and the proofs you ran.
$("$RULES" 2>/dev/null)
SPEC
}

opened=0; would=0; skipped=0; deferred=0; failed=0
while IFS= read -r row; do
  repo=$(jq -r .repo <<<"$row"); pr=$(jq -r .pr <<<"$row"); head=$(jq -r .head <<<"$row"); url=$(jq -r .url <<<"$row")
  verdict=$(jq -r .verdict <<<"$row"); review=$(jq -r .review <<<"$row"); risk=$(jq -r '.risk // "UNKNOWN"' <<<"$row"); tag="${repo##*/}#$pr"
  project=${repo##*/}
  [ -d "$FM_HOME/projects/$project" ] || { echo "SKIP $tag: no project $project under projects/"; skipped=$((skipped+1)); continue; }
  [ "$(jq -r '.draft // false' <<<"$row")" = false ] || { echo "SKIP $tag: draft"; skipped=$((skipped+1)); continue; }
  [ "$verdict" != NEEDS-UPDATE ] || { echo "SKIP $tag: verdict NEEDS-UPDATE (behind main or conflicts: review the head after the update)"; skipped=$((skipped+1)); continue; }
  case "$review" in none|stale) ;; *) echo "SKIP $tag: head ${head:0:8} already has a review record ($review)"; skipped=$((skipped+1)); continue ;; esac
  case "$(last_status "$repo" "$pr" "$head")" in
    SPAWNED|HARVESTED|UNPARSED) echo "SKIP $tag: review of head ${head:0:8} already requested"; skipped=$((skipped+1)); continue ;;
  esac
  id=$(review_id "$repo" "$pr" "$head")
  if [ -e "$FM_HOME/state/$id.meta" ]; then
    # the task is live but the registry has no row (a sweep died between the spawn and the write): adopt it
    [ $dry = 1 ] || reg_add "$repo" "$pr" "$head" SPAWNED "$id" "$risk" "adopted live task"
    echo "SKIP $tag: review $id is already running"; skipped=$((skipped+1)); continue
  fi
  if [ $dry = 1 ]; then echo "WOULD OPEN $tag head ${head:0:8} risk=$risk review=$review id=$id profile=$([ "$risk" = HIGH ] && echo opus || echo dispatch-rule)"; would=$((would+1)); continue; fi

  prior=""
  if [ "$review" = stale ]; then prior=$("$RECORD" read "$repo" "$pr" --json 2>/dev/null | jq -r '.reviewed_head // empty' 2>/dev/null); fi
  printf 'Independent review of %s (%s, risk level %s), exact head %s.\nStanding authorization (24/10): every open PR head gets an independent review at each sweep.\n' "$url" "$project" "$(label_of "$risk")" "$head" > "$DIR/specs/$id.task"
  spec_text "$repo" "$pr" "$head" "$url" "$project" "$risk" "$id" "$review" "$prior" > "$DIR/specs/$id.spec"
  prof=(); [ "$risk" != HIGH ] || read -r -a prof <<<"$OPUS"
  title="Independent review $tag $(label_of "$risk") head ${head:0:8}"
  out=$("$SPAWN_TASK" scout "$id" "$project" --title "$title" --task "$DIR/specs/$id.task" --spec "$DIR/specs/$id.spec" "${prof[@]}" 2>&1); rc=$?
  line=$(printf '%s\n' "$out" | grep . | tail -1 | cut -c1-240)
  if [ $rc != 0 ] && [ ${#prof[@]} = 0 ] && [[ $line == *": profile: "* ]]; then
    read -r -a prof <<<"$OPUS"
    out=$("$SPAWN_TASK" scout "$id" "$project" --title "$title" --task "$DIR/specs/$id.task" --spec "$DIR/specs/$id.spec" "${prof[@]}" 2>&1); rc=$?
    line=$(printf '%s\n' "$out" | grep . | tail -1 | cut -c1-240)
  fi
  if [ $rc = 0 ]; then
    reg_add "$repo" "$pr" "$head" SPAWNED "$id" "$risk" "$line"; echo "OPEN $tag head ${head:0:8} risk=$risk: $line"; opened=$((opened+1))
  elif [ $rc = 75 ]; then
    reg_add "$repo" "$pr" "$head" DEFERRED "$id" "$risk" "$line"; echo "DEFER $tag head ${head:0:8}: no slot yet, retried next sweep ($line)"; deferred=$((deferred+1))
  elif [ -e "$FM_HOME/state/$id.meta" ]; then
    # spawned but the launch check refused: the worker exists, never spawn a second one
    reg_add "$repo" "$pr" "$head" SPAWNED "$id" "$risk" "launch check: $line"; echo "OPEN $tag head ${head:0:8} risk=$risk: spawned, launch check failed - $line"; opened=$((opened+1)); failed=$((failed+1))
  else
    reg_add "$repo" "$pr" "$head" FAILED "$id" "$risk" "$line"; echo "FAIL $tag head ${head:0:8}: $line"; failed=$((failed+1))
  fi
done < <(jq -c '.rows[]' <<<"$rows")
echo "SUMMARY opened=$opened would-open=$would deferred=$deferred failed=$failed skipped=$skipped$([ $dry = 1 ] && echo ' (dry-run: nothing changed)')"
exit 0
