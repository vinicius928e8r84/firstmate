#!/usr/bin/env bash
# fm-improvement-queue.sh - the audits' improvement queue as an append-only ledger.
#
# Usage:
#   fm-improvement-queue.sh add <title> [--audit YYYYMMDD] [--owner WHO] [--probe NAME]... [--even-if-present] [--due EPOCH|+Nh]
#   fm-improvement-queue.sh set <id> <state> [note] [--due EPOCH|+Nh]
#   fm-improvement-queue.sh list [--open] [--all-history]
#   fm-improvement-queue.sh wip
#   fm-improvement-queue.sh stale
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
#         proposed, approved (the captain said yes; a worker is owed), building,
#         landed (on main), synced (reached the fork or the fleet), proved
#         (checked in the real path), dropped (will not be done).
# list  prints the latest row per id as "id<TAB>state<TAB>owner<TAB>title<TAB>note";
#       --open leaves out landed-and-later states that need nothing more
#       (proved, dropped) so what is printed is what still needs someone;
#       --all-history prints every row instead of the latest per id. A sixth
#       column carries the due epoch (see below), empty when none.
# wip   prints how many ids are in flight: latest state approved or building.
#       Work in flight is capped at FM_IMPROVEMENT_WIP_MAX (default 5): `set <id>
#       approved` for a sixth id is refused with exit 4, so what exceeds the cap
#       waits as "proposed" until a slot frees (the cap of the 2026-10-31 plan).
# stale prints the ids whose latest state is still approved after their due
#       time, one "id<TAB>due<TAB>owner<TAB>title" line each: approved and no
#       worker started. `set <id> approved` sets the due time to 24 h out
#       (FM_IMPROVEMENT_WORKER_HOURS), `set <id> building` ends the wait.
#       bin/fm-improvement-feed.sh watch turns these lines into a wake.
# due   (the 7th ledger column) is an epoch. `add --due` / `set --due` take an
#       epoch or +Nh; the ledger carries it forward on later rows of the same id.
#
# Ledger: $FM_HOME/data/audit-queue.tsv, tab-separated, appended one line at a
# time: epoch, id, state, owner, title, note, due. A tab or newline in a field
# becomes a space. Exit status: 0 ok, 2 usage, 3 refused (already exists, unknown
# id), 4 refused (work-in-flight cap reached).
set -uo pipefail

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
LEDGER=${FM_AUDIT_QUEUE:-$FM_HOME/data/audit-queue.tsv}

usage() { sed -n 2,50p "$0"; }
die_usage() { echo "$1" >&2; usage >&2; exit 2; }
clean() { printf '%s' "$1" | tr '\t\n' '  '; }

valid_state() {
  case "$1" in proposed|approved|building|landed|synced|proved|dropped) return 0 ;; *) return 1 ;; esac
}

now() { echo "${FM_IMPROVEMENT_NOW:-$(date +%s)}"; }
WIP_MAX=${FM_IMPROVEMENT_WIP_MAX:-5}
WORKER_HOURS=${FM_IMPROVEMENT_WORKER_HOURS:-24}

append() {  # id state owner title note [due]
  mkdir -p "$(dirname "$LEDGER")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$(clean "$1")" "$(clean "$2")" "$(clean "$3")" "$(clean "$4")" "$(clean "$5")" "$(clean "${6:-}")" >> "$LEDGER"
}

# due_epoch <EPOCH|+Nh>: the epoch, or exit 2 on anything else.
due_epoch() {
  if [[ $1 =~ ^\+([0-9]+)h$ ]]; then echo $(( $(now) + ${BASH_REMATCH[1]} * 3600 ))
  elif [[ $1 =~ ^[0-9]+$ ]]; then echo "$1"
  else die_usage "bad --due: $1"; fi
}

# wip_count [except-id]: ids whose latest state is approved or building.
wip_count() {
  [ -f "$LEDGER" ] || { echo 0; return; }
  awk -F'\t' -v skip="${1:-}" '{ st[$2] = $3 } END { for (i in st) if (i != skip && (st[i] == "approved" || st[i] == "building")) c++; print c + 0 }' "$LEDGER"
}

# latest_row <id>: the newest ledger row for the id, empty when none.
latest_row() {
  [ -f "$LEDGER" ] || return 0
  awk -F'\t' -v id="$1" '$2 == id { row = $0 } END { if (row != "") print row }' "$LEDGER"
}

cmd_add() {
  local title='' audit='' owner=unassigned force=0 word n id found=0 hit due=''
  local -a probes=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --audit|--owner|--probe|--due) [ $# -ge 2 ] || die_usage "$1 needs a value" ;;
    esac
    case "$1" in
      --due) due=$(due_epoch "$2") || exit 2; shift 2 ;;
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
  append "$id" proposed "$owner" "$title" "" "$due"
  printf '%s\n' "$id"
}

cmd_set() {
  [ $# -ge 2 ] || die_usage "set needs an id and a state"
  local id=$1 state=$2 note='' row due='' prev_state
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --due) [ $# -ge 2 ] || die_usage "--due needs a value"; due=$(due_epoch "$2") || exit 2; shift 2 ;;
      *) [ -z "$note" ] || die_usage "one note only, quote it"; note=$1; shift ;;
    esac
  done
  valid_state "$state" || die_usage "unknown state: $state"
  row=$(latest_row "$id")
  [ -n "$row" ] || { echo "no such improvement: $id" >&2; exit 3; }
  prev_state=$(printf '%s' "$row" | cut -f3)
  if [ -z "$due" ]; then
    due=$(printf '%s' "$row" | cut -f7)
    if [ "$state" = approved ] && [ "$prev_state" != approved ]; then due=$(( $(now) + WORKER_HOURS * 3600 )); fi
  fi
  if [ "$state" = approved ] && [ "$prev_state" != approved ] && [ "$prev_state" != building ] \
      && [ "$(wip_count "$id")" -ge "$WIP_MAX" ]; then
    echo "work in flight is at the cap of $WIP_MAX (approved or building); $id stays $prev_state until one lands or is dropped" >&2
    exit 4
  fi
  append "$id" "$state" "$(printf '%s' "$row" | cut -f4)" "$(printf '%s' "$row" | cut -f5)" "$note" "$due"
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
    history { print $2, $3, $4, $5, $6, $7; next }
    { if (!($2 in row)) order[++n] = $2; row[$2] = $2 OFS $3 OFS $4 OFS $5 OFS $6 OFS $7; st[$2] = $3 }
    END { for (i = 1; i <= n; i++) { id = order[i]; if (open && (st[id] == "proved" || st[id] == "dropped")) continue; print row[id] } }
  ' "$LEDGER"
}

cmd_stale() {
  [ -f "$LEDGER" ] || return 0
  awk -F'\t' -v OFS='\t' -v now="$(now)" -v hours="$WORKER_HOURS" '
    { if (!($2 in at)) order[++n] = $2
      st[$2] = $3; at[$2] = $1; owner[$2] = $4; title[$2] = $5; due[$2] = $7 }
    END { for (i = 1; i <= n; i++) { id = order[i]
            if (st[id] != "approved") continue
            d = (due[id] ~ /^[0-9]+$/) ? due[id] : at[id] + hours * 3600
            if (d < now) print id, d, owner[id], title[id] } }
  ' "$LEDGER"
}

case "${1:-}" in
  wip) wip_count ;;
  stale) cmd_stale ;;
  add) shift; cmd_add "$@" ;;
  set) shift; cmd_set "$@" ;;
  list) shift; cmd_list "$@" ;;
  -h|--help) usage ;;
  *) die_usage "unknown command: ${1:-}" ;;
esac
