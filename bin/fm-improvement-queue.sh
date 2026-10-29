#!/usr/bin/env bash
# fm-improvement-queue.sh - the audits' improvement queue as an append-only ledger.
#
# Usage:
#   fm-improvement-queue.sh add <title> [--audit YYYYMMDD] [--owner WHO] [--probe NAME]... [--even-if-present]
#   fm-improvement-queue.sh set <id> <state> [note]
#   fm-improvement-queue.sh list [--open] [--all-history]
#
# An audit used to publish its proposed improvements as prose, and the next audit
# rebuilt their fate from chat and git: of 30 proposals in the 24-27/10 audits 10
# were confirmed done, and one was proposed again after it had landed. Here each
# improvement is one id with an owner and a state the moment the audit publishes,
# and the next audit reads the ids instead of reconstructing them.
#
# add   records state "proposed" and prints the new id (<audit>-<n>). Before it
#       records anything it looks for the thing already existing: each --probe
#       NAME, and every fm-... word in the title, is searched as a file name under
#       bin/ and as text under bin/ and .agents/skills/. A hit prints
#       "EXISTS <name>: <path>" and exits 3 without recording, so an improvement
#       that landed is not proposed again; --even-if-present records it anyway.
# set   appends a new state row for the id (a row is never edited). States:
#         proposed, building, landed (on main), synced (reached the fork or the
#         fleet), proved (checked in the real path), dropped (will not be done).
# list  prints the latest row per id as "id<TAB>state<TAB>owner<TAB>title<TAB>note";
#       --open leaves out landed-and-later states that need nothing more
#       (proved, dropped) so what is printed is what still needs someone;
#       --all-history prints every row instead of the latest per id.
#
# Ledger: $FM_HOME/data/audit-queue.tsv, tab-separated, appended one line at a
# time: epoch, id, state, owner, title, note. A tab or newline in a field becomes
# a space. Exit status: 0 ok, 2 usage, 3 refused (already exists, unknown id).
set -uo pipefail

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
LEDGER=${FM_AUDIT_QUEUE:-$FM_HOME/data/audit-queue.tsv}

usage() { sed -n 2,31p "$0"; }
die_usage() { echo "$1" >&2; usage >&2; exit 2; }
clean() { printf '%s' "$1" | tr '\t\n' '  '; }

valid_state() {
  case "$1" in proposed|building|landed|synced|proved|dropped) return 0 ;; *) return 1 ;; esac
}

append() {  # id state owner title note
  mkdir -p "$(dirname "$LEDGER")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(clean "$1")" "$(clean "$2")" "$(clean "$3")" "$(clean "$4")" "$(clean "$5")" >> "$LEDGER"
}

# latest_row <id>: the newest ledger row for the id, empty when none.
latest_row() {
  [ -f "$LEDGER" ] || return 0
  awk -F'\t' -v id="$1" '$2 == id { row = $0 } END { if (row != "") print row }' "$LEDGER"
}

cmd_add() {
  local title='' audit='' owner=unassigned force=0 word n id found=0 hit
  local -a probes=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --audit|--owner|--probe) [ $# -ge 2 ] || die_usage "$1 needs a value" ;;
    esac
    case "$1" in
      --audit) audit=$2; shift 2 ;;
      --owner) owner=$2; shift 2 ;;
      --probe) probes+=("$2"); shift 2 ;;
      --even-if-present) force=1; shift ;;
      -*) die_usage "unknown argument: $1" ;;
      *) [ -z "$title" ] || die_usage "one title only, quote it"; title=$1; shift ;;
    esac
  done
  [ -n "$title" ] || die_usage "add needs a title"
  [ -n "$audit" ] || audit=$(date +%Y%m%d)
  case "$audit" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) die_usage "--audit must be YYYYMMDD" ;; esac
  for word in $title; do
    case "$word" in fm-[A-Za-z0-9._-]*) probes+=("${word%%[.,;:]}") ;; esac
  done
  if [ "$force" = 0 ]; then
    for word in ${probes[@]+"${probes[@]}"}; do
      hit=$(find "$FM_ROOT/bin" -maxdepth 2 -name "${word}*" -type f 2>/dev/null | head -1)
      [ -n "$hit" ] || hit=$(grep -rIlF -- "$word" "$FM_ROOT/bin" "$FM_ROOT/.agents/skills" 2>/dev/null | head -1)
      if [ -n "$hit" ]; then
        echo "EXISTS $word: ${hit#"$FM_ROOT"/}"
        found=1
      fi
    done
    [ "$found" = 0 ] || { echo "nothing recorded; pass --even-if-present if this really is new work" >&2; exit 3; }
  fi
  n=$(awk -F'\t' -v p="$audit-" 'index($2, p) == 1 && !seen[$2]++ { c++ } END { print c + 1 }' "$LEDGER" 2>/dev/null || echo 1)
  id="$audit-$n"
  append "$id" proposed "$owner" "$title" ""
  printf '%s\n' "$id"
}

cmd_set() {
  [ $# -ge 2 ] || die_usage "set needs an id and a state"
  local id=$1 state=$2 note=${3:-} row
  valid_state "$state" || die_usage "unknown state: $state"
  row=$(latest_row "$id")
  [ -n "$row" ] || { echo "no such improvement: $id" >&2; exit 3; }
  append "$id" "$state" "$(printf '%s' "$row" | cut -f4)" "$(printf '%s' "$row" | cut -f5)" "$note"
}

cmd_list() {
  local open=0 history=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --open) open=1 ;;
      --all-history) history=1 ;;
      *) die_usage "unknown argument: $1" ;;
    esac
    shift
  done
  [ -f "$LEDGER" ] || return 0
  awk -F'\t' -v OFS='\t' -v open="$open" -v history="$history" '
    history { print $2, $3, $4, $5, $6; next }
    { if (!($2 in row)) order[++n] = $2; row[$2] = $2 OFS $3 OFS $4 OFS $5 OFS $6; st[$2] = $3 }
    END { for (i = 1; i <= n; i++) { id = order[i]; if (open && (st[id] == "proved" || st[id] == "dropped")) continue; print row[id] } }
  ' "$LEDGER"
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  set) shift; cmd_set "$@" ;;
  list) shift; cmd_list "$@" ;;
  -h|--help) usage ;;
  *) die_usage "unknown command: ${1:-}" ;;
esac
