#!/usr/bin/env bash
# fm-decision-page.sh - the decision page without hand-built HTML: the model writes only the text of each decision.
#
# Usage:
#   fm-decision-page.sh build <decisoes.tsv> [--name <page-name>] [--title <heading>]
#   fm-decision-page.sh apply <source-id | page.html>
#
# build   Reads one decision per line, tab separated, and publishes the page through bin/fm-daily-page.sh
#         (cards, recommended option preselected, bind to the keyed-answer intake, armed process event).
#         Columns: key <TAB> title <TAB> context <TAB> recommend <TAB> options
#           key        the held task's id (slug: letters, digits, . _ -); the answer resolves that hold
#           title      the question shown on the card
#           context    plain text under the title (may be empty)
#           recommend  the option value to preselect and mark (required; must be one of the options)
#           options    value=Label[=hint] items joined by `|`; empty gives Aprovar, Adiar and Recusar
#         Blank lines, `#` lines and a header line starting with `key<TAB>` are skipped. The page is named
#         decisoes-<tsv name>-<date> unless --name is given. The candidate page must pass bin/fm-page-check.sh
#         before it replaces the file. A key that is not an open captain hold only warns on stderr.
#         Prints what fm-daily-page.sh prints (`page:`, `url:`, `armed:`).
# apply   For a source whose captured answers were not fed to the intake (unbound, or the runner was down), feeds
#         every unhandled captured result of that source to `fm-captain-hold.sh answers` and then marks it
#         handled with `fm-procevent.sh handled`. A result the intake refuses stays unhandled. Idempotent.
#
# Env: FM_HOME; test seams FM_DECISION_PAGE_DAILY, FM_DECISION_PAGE_ADAPTER, FM_DECISION_PAGE_HOLD_CMD,
#   FM_DECISION_PAGE_PROCEVENT, FM_DECISION_PAGE_CHECK (default the sibling bin/ scripts).
# Exit: 0 ok, 1 failure (build input invalid, page check failed, intake refused), 2 usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DAILY="${FM_DECISION_PAGE_DAILY:-$SCRIPT_DIR/fm-daily-page.sh}"
ADAPTER="${FM_DECISION_PAGE_ADAPTER:-$SCRIPT_DIR/fm-procevent-lavish.sh}"
HOLD="${FM_DECISION_PAGE_HOLD_CMD:-$SCRIPT_DIR/fm-captain-hold.sh}"
PROCEVENT="${FM_DECISION_PAGE_PROCEVENT:-$SCRIPT_DIR/fm-procevent.sh}"
CHECK="${FM_DECISION_PAGE_CHECK:-$SCRIPT_DIR/fm-page-check.sh}"

fail() { printf 'fm-decision-page: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }

cmd_build() {
  local tsv=${1-} name='' title='' json tmp base rc key
  [ -n "$tsv" ] || usage
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name=${2-}; shift 2 || usage ;;
      --title) title=${2-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -f "$tsv" ] || fail "no such file: $tsv"
  command -v jq >/dev/null 2>&1 || fail "jq is not installed"
  base=$(basename "$tsv"); base=${base%.*}; base=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-')
  [ -n "$name" ] || name="decisoes-$base-${FM_DAILY_PAGE_DATE:-$(date +%F)}"
  json=$(jq -Rn '
    def slug: test("^[A-Za-z0-9._-]{1,128}$");
    [ inputs | rtrimstr("\r") | select(length > 0 and (startswith("#") | not)) | select(startswith("key\t") | not) ]
    | to_entries
    | map(.key as $i | (.value | split("\t")) as $c
        | ($c[0] // "") as $key | ($c[1] // "") as $title | ($c[2] // "") as $ctx
        | ($c[3] // "") as $rec | ($c[4] // "") as $raw
        | if ($key | slug | not) then error("line \($i + 1): key must be a slug, got \"\($key)\"")
          elif $title == "" then error("line \($i + 1): \($key) has no title")
          elif $rec == "" then error("line \($i + 1): \($key) has no recommendation")
          else
            ([ $raw | split("|")[] | select(length > 0) | split("=")
               | {value: .[0], label: (.[1] // .[0]), hint: (.[2:] | join("="))} ]) as $opts
            | (if ($opts | map(.value | slug) | all) then . else error("line \($i + 1): \($key) has an option value that is not a slug") end)
            | (if ($opts | length == 0 and ($rec | IN("approve","defer","decline"))) or ($opts | any(.value == $rec)) then .
               else error("line \($i + 1): \($key) recommends \"\($rec)\", which is not one of its options") end)
            | {key: $key, verb: "captain-hold", summary: $title, context: $ctx, owner: "(main)", options: $opts, recommend: $rec}
          end)
    | if length == 0 then error("no decisions in the file")
      elif (map(.key) | length) != (map(.key) | unique | length) then error("a key appears twice")
      else {decisions_open: .} end
  ' < "$tsv" 2>&1) || fail "$(printf '%s' "$json" | sed 's/^jq: error (at [^)]*): //')"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-decision-page.XXXXXX") || fail "cannot stage the decisions"
  # shellcheck disable=SC2064
  trap "rm -f -- '$tmp'" EXIT
  printf '%s\n' "$json" > "$tmp"
  while IFS= read -r key; do
    "$HOLD" open "$key" >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ] || printf 'fm-decision-page: warning: %s is not an open captain hold (exit %s); its answer will not resolve anything\n' "$key" "$rc" >&2
  done < <(jq -r '.decisions_open[].key' "$tmp")
  env FM_HOME="$FM_HOME" FM_DAILY_PAGE_NAME="$name" ${title:+"FM_DAILY_PAGE_TITLE=$title"} \
    FM_DAILY_PAGE_READER="cat '$tmp'" FM_DAILY_PAGE_CHECK_CMD="$CHECK" "$DAILY"
}

cmd_apply() {
  local arg=${1-} id state inbox result seq base n failed=0 origin
  local -a scope
  [ -n "$arg" ] && [ $# -eq 1 ] || usage
  case "$arg" in
    *.html) id=$("$ADAPTER" source-id "$arg") || fail "cannot derive the source id of $arg" ;;
    *) id=$arg ;;
  esac
  case "$id" in ''|*[!A-Za-z0-9._-]*) fail "not a source id: $id" ;; esac
  state="$FM_HOME/state"; inbox="$state/procevent-inbox"
  origin=$("$HOLD" binding "$id" 2>/dev/null) || origin=''
  scope=(--any-origin)
  case "$origin" in ''|'(any)') ;; *) scope=("$origin") ;; esac
  n=0
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    base=$(basename "$result" .result); seq=${base##*.}
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    [ -e "$inbox/$id.$seq.handled" ] && continue
    if "$ADAPTER" answers "$result" | "$HOLD" answers "${scope[@]}" \
         --source "the captured result $id sequence $seq" >/dev/null; then
      "$PROCEVENT" handled "$id" "$seq" >/dev/null || { failed=1; echo "failed: $id $seq could not be marked handled"; continue; }
      echo "applied: $id $seq"; n=$((n + 1))
    else
      failed=1; echo "kept: $id $seq the intake refused it"
    fi
  done < <(find "$inbox" -maxdepth 1 -name "$id.*.result" 2>/dev/null | sort -V)
  echo "applied $n result(s) for $id"
  return "$failed"
}

case "${1-}" in
  build) shift; cmd_build "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  *) usage ;;
esac
