#!/usr/bin/env bash
# fm-repo-charter.sh - print the charter text (or routing scope) of the
# per-repo secondmate that owns one product repo's PR pipeline.
#
# One charter shape serves every product repo, so a second repo can never inherit
# another repo's text: the repo name, its GitHub slug, the merge script and the
# repo's own merge rule are the only inputs, and nothing else is copied between
# charters. The output is a single line, the form bin/fm-brief.sh fills into
# `# Charter` and bin/fm-home-seed.sh derives the registry summary from.
#
# Usage:
#   fm-repo-charter.sh <project> [--slug <owner/repo>] [--merge-script <path>] [--rule-file <file>] [--scope]
#     <project>       registered project name (the directory under projects/)
#     --slug          GitHub owner/repo; default: read from the project clone's origin
#     --merge-script  the script that merges a ready PR; default: bin/fm-pr-merge.sh
#     --rule-file     the repo's own merge rule, plain text; default: the general rule
#     --scope         print the one-line routing scope instead of the charter
#
# Seed and launch (the launch is a separate, deliberate step):
#   FM_SECONDMATE_CHARTER="$(bin/fm-repo-charter.sh <project> ...)" \
#   FM_SECONDMATE_SCOPE="$(bin/fm-repo-charter.sh <project> ... --scope)" \
#     bin/fm-home-seed.sh <id> - <project>
# The sleeping behavior the charter names is bin/fm-secondmate-sleep.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  echo "usage: fm-repo-charter.sh <project> [--slug <owner/repo>] [--merge-script <path>] [--rule-file <file>] [--scope]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
PROJECT=$1
shift
case "$PROJECT" in '' | -* | *[!A-Za-z0-9._-]*) usage ;; esac
SLUG= MERGE_SCRIPT=bin/fm-pr-merge.sh RULE_FILE= SCOPE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) [ $# -ge 2 ] || usage; SLUG=$2; shift 2 ;;
    --merge-script) [ $# -ge 2 ] || usage; MERGE_SCRIPT=$2; shift 2 ;;
    --rule-file) [ $# -ge 2 ] || usage; RULE_FILE=$2; shift 2 ;;
    --scope) SCOPE_ONLY=1; shift ;;
    *) usage ;;
  esac
done

if [ -z "$SLUG" ]; then
  origin=$(git -C "${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/$PROJECT" remote get-url origin 2>/dev/null || true)
  SLUG=${origin%.git}
  SLUG=${SLUG#*github.com[:/]}
  case "$SLUG" in */*) ;; *) echo "error: cannot read the GitHub slug of $PROJECT from its origin; pass --slug <owner/repo>" >&2; exit 1 ;; esac
fi
case "$SLUG" in *[!A-Za-z0-9._/-]* | /* | */ | */*/*) echo "error: --slug must look like owner/repo" >&2; exit 2 ;; esac

SCOPE="$PROJECT pull request queue: reviews, fixes, proofs, merges and readiness reports for every $PROJECT PR and slice routed to this mate"
if [ "$SCOPE_ONLY" -eq 1 ]; then
  printf '%s\n' "$SCOPE"
  exit 0
fi

RULE='merge a PR only when it is LOW or MEDIUM attention, its independent review is clean at the exact head, CI is green at that head and the base branch has not moved ahead of it; everything else goes back to the main firstmate'
if [ -n "$RULE_FILE" ]; then
  [ -f "$RULE_FILE" ] && [ -r "$RULE_FILE" ] || { echo "error: cannot read --rule-file $RULE_FILE" >&2; exit 1; }
  RULE=$(tr '\n' ' ' <"$RULE_FILE" | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')
  [ -n "$RULE" ] || { echo "error: --rule-file $RULE_FILE is empty" >&2; exit 1; }
fi

# One line, no semicolons inside the first sentence: the registry summary is its first sentence.
printf '%s\n' "Own the $PROJECT ($SLUG) PR pipeline end to end for the main firstmate: for every open PR of $PROJECT and every slice routed here, run the stages independent review of each new head, routing of findings to the PR's owner worker (test-first fixes, one push), delta re-review, the real-path proof on HIGH attention PRs, merging the base branch into stale PRs, keeping a one-screen queue table in data/queue.md (PR, head sha, stage, owner, next action) and closing workers whose PR is delivered. Decide all of that yourself and do not ask the main firstmate for progress approvals. Merge only through the script $MERGE_SCRIPT (never a hand-run merge command) and only under this rule: $RULE. You never answer captain decisions and never decide ask-user findings of your own workers' gates. You sleep while there is no work: with an empty queue, no worker of yours in flight and no message waiting, your process is closed on purpose (bin/fm-secondmate-sleep.sh) and reopened when the main firstmate routes something to you, so on every reopening read your backlog, queue table and inbox first and start nothing that is not on them. Your context compacts near 150k tokens; keep durable state in data/queue.md and your backlog, never only in the conversation. Report to the main firstmate through marked status only these outcomes: a PR you merged (with its full URL), a real blocker, or a decision the captain owns; send no progress. Use the models the dispatch configuration chooses for each task; heavy tests run one at a time. Never touch unshipped work of other workers, the captain's browser profiles or desktop apps."
