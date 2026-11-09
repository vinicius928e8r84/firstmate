#!/usr/bin/env bash
# fm-improvement-feed.sh - feed bin/fm-improvement-queue.sh and make an approved improvement either get a worker
# or go back to the captain. Pure shell: no model call, no network (audit of 2026-11-09, changes 3 and 4: the queue
# had 0 rows because nothing wrote to it, and 21 approved improvements sat for days with no worker).
# Usage:
#   fm-improvement-feed.sh ingest [--audit-file FILE] [--dry-run]
#   fm-improvement-feed.sh seed [--dry-run] <task-id>...
#   fm-improvement-feed.sh watch
# ingest  reads the "## Melhorias" table of the newest audit (data/audit-daily/YYYY-MM-DD[-suffix].md, never an
#         -apendice file) or of --audit-file, and records one `proposed` row per table row: title = the "O que" cell,
#         owner = the first bold name of the "Quem / como" cell (**MAIN**, **Capitão**, **Firstmate (ramo):**),
#         due = 48 h out (the captain's window to approve or drop it), note = the how-cell without markdown.
#         It is idempotent: a title already in the ledger, in any state, is not recorded again, and a title that
#         names something already in bin/ is refused by the queue's own existence check and reported as skipped.
# seed    records the listed backlog tasks (data/backlog.md, Queued) as improvements the captain already approved,
#         oldest "since" date first and the given order within a date: each is `approved` while fewer than the
#         work-in-flight cap are in flight, otherwise `proposed` with the note "aprovada pelo dono; espera vaga" and
#         promoted by `watch` when a slot frees. It creates no worker and edits no backlog item.
# watch   (1) promotes waiting approved tasks into free slots, then (2) turns every approved improvement still without
#         a worker 24 h after its approval into ONE inbox note for firstmate (bin/fm-inbox.sh note, a durable `check`
#         wake) - "launch the worker" for the first day, "give it back to the captain to drop" from 48 h on. One note
#         per id per UTC day, so a standing item reminds once a day and never floods.
# Env: FM_HOME, FM_AUDIT_DIR (default $FM_HOME/data/audit-daily), FM_BACKLOG (default $FM_HOME/data/backlog.md),
#   FM_AUDIT_QUEUE (the ledger, see the queue), FM_IMPROVEMENT_NOW (epoch, tests), FM_NOTIFY_INBOX (command that takes
#   the note text, tests; default bin/fm-inbox.sh note).
# Exit: 0 ok, 1 an unknown task id or unreadable input, 2 usage.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$HERE/.." && pwd)
F=${FM_HOME:-$FM_ROOT}
QUEUE=$HERE/fm-improvement-queue.sh
AUDIT_DIR=${FM_AUDIT_DIR:-$F/data/audit-daily}
BACKLOG=${FM_BACKLOG:-$F/data/backlog.md}
MARKS=$F/state/.improvement-feed
WAIT_NOTE='aprovada pelo dono; espera vaga'
export FM_HOME=$F

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2; exit 2; }
now() { echo "${FM_IMPROVEMENT_NOW:-$(date +%s)}"; }
q() { "$QUEUE" "$@"; }
wip_max() { echo "${FM_IMPROVEMENT_WIP_MAX:-5}"; }
have_title() { # <title>: succeeds when the ledger already has it, in any state
  local want; want=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  q list --all-history 2>/dev/null | awk -F'\t' -v w="$want" 'tolower($4) == w { f = 1 } END { exit !f }'
}

latest_audit() {
  local f
  for f in "$AUDIT_DIR"/*.md; do
    [ -e "$f" ] || continue
    [[ $(basename "$f") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(-[A-Za-z0-9]+)?\.md$ ]] || continue
    [[ $f == *-apendice.md ]] && continue
    echo "$f"
  done | sort | tail -1
}

cmd_ingest() {
  local file='' dry=0 base day rows title who owner note id rc added=0 skipped=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --audit-file) [ $# -ge 2 ] || usage; file=$2; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$file" ] || file=$(latest_audit)
  [ -n "$file" ] && [ -r "$file" ] || { echo "fm-improvement-feed: no readable audit report (looked in $AUDIT_DIR)" >&2; exit 1; }
  base=$(basename "$file")
  day=$(printf '%s' "$base" | sed -n 's/^\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\).*/\1\2\3/p')
  [ -n "$day" ] || day=$(date -u -d "@$(now)" +%Y%m%d)
  # The table rows of the Melhorias section: "| n | title | who / how | effort | gain |".
  rows=$(awk -F'|' '
    /^## Melhorias/ { on = 1; next }
    /^## / { on = 0 }
    on && /^\|/ && $2 !~ /^[ ]*#[ ]*$/ && $2 !~ /^[ ]*-+[ ]*$/ && NF >= 6 {
      t = $3; w = $4
      gsub(/^[ ]+|[ ]+$/, "", t); gsub(/^[ ]+|[ ]+$/, "", w)
      print t "\t" w
    }' "$file")
  while IFS=$'\t' read -r title who; do
    [ -n "$title" ] || continue
    title=${title//\*\*/}; title=${title//\`/}
    owner=$(printf '%s' "$who" | sed -n 's/^[^*]*\*\*\([^*]*\)\*\*.*/\1/p' | sed 's/ *(.*//; s/[:.,; ]*$//')
    [ -n "$owner" ] || owner=unassigned
    note=$(printf '%s' "$who" | sed 's/\*\*//g; s/`//g' | cut -c1-240)
    if have_title "$title"; then
      echo "skip known: $title"; skipped=$((skipped + 1)); continue
    fi
    if [ "$dry" = 1 ]; then echo "would add [$owner]: $title"; added=$((added + 1)); continue; fi
    id=$(q add "$title" --audit "$day" --owner "$owner" --due +48h --note "$note" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "added $id [$owner]: $title"; added=$((added + 1))
    elif [ "$rc" -eq 3 ]; then
      echo "skip exists in repo: $title ($(printf '%s' "$id" | head -1))"; skipped=$((skipped + 1))
    else
      echo "fm-improvement-feed: could not record '$title': $id" >&2; exit 1
    fi
  done <<<"$rows"
  echo "ingest $base: $added recorded, $skipped skipped"
}

# backlog_line <task-id>: "since<TAB>title" of its Queued line, nothing when absent.
backlog_line() {
  [ -r "$BACKLOG" ] || return 0
  awk -v id="$1" '
    index($0, "- [ ] " id " - ") == 1 {
      line = substr($0, length("- [ ] " id " - ") + 1)
      since = "none"; if (match(line, /\(since [0-9-]+\)/)) since = substr(line, RSTART + 7, RLENGTH - 8)
      sub(/ \(repo: .*$/, "", line)
      print since "\t" line; exit
    }' "$BACKLOG"
}

cmd_seed() {
  local dry=0 id line since title n=0 bad=0 sorted day qid state wipn
  local -a ids=() rows=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      -*) usage ;;
      *) ids+=("$1"); shift ;;
    esac
  done
  [ "${#ids[@]}" -gt 0 ] || usage
  for id in "${ids[@]}"; do
    line=$(backlog_line "$id")
    if [ -z "$line" ]; then echo "fm-improvement-feed: $id is not a Queued task in $BACKLOG" >&2; bad=1; continue; fi
    n=$((n + 1))
    rows+=("$(printf '%s\t%04d\t%s\t%s' "$(printf '%s' "$line" | cut -f1)" "$n" "$id" "$(printf '%s' "$line" | cut -f2)")")
  done
  sorted=$(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1 -k2,2n)
  while IFS=$'\t' read -r since _ id title; do
    [ -n "$id" ] || continue
    title="$id: $title"
    if have_title "$title"; then echo "skip known: $id"; continue; fi
    day=${since//-/}; [ "$day" != none ] || day=$(date -u -d "@$(now)" +%Y%m%d)
    wipn=$(q wip)
    if [ "$wipn" -lt "$(wip_max)" ]; then state=approved; else state=proposed; fi
    if [ "$dry" = 1 ]; then echo "would record $state: $title"; continue; fi
    qid=$(q add "$title" --audit "$day" --owner "firstmate (ship)" --even-if-present --note "$WAIT_NOTE") || { bad=1; continue; }
    if [ "$state" = approved ]; then
      q set "$qid" approved "aprovada pelo dono; worker devido em 24 h" || { bad=1; continue; }
    fi
    echo "recorded $state $qid: $title"
  done <<<"$sorted"
  return "$bad"
}

inbox() { # <text>
  if [ -n "${FM_NOTIFY_INBOX:-}" ]; then "$FM_NOTIFY_INBOX" "$1" >/dev/null 2>&1; return 0; fi
  "$HERE/fm-inbox.sh" note "$1" >/dev/null 2>&1 || true
}

cmd_watch() {
  local id state owner title note due today now_e launch='' give='' n=0 line mark
  now_e=$(now); today=$(date -u -d "@$now_e" +%Y%m%d)
  # (1) a freed slot takes the oldest approved task that was waiting for one
  while [ "$(q wip)" -lt "$(wip_max)" ]; do
    id=''
    while IFS=$'\t' read -r id state owner title note due; do
      [ "$state" = proposed ] && [[ $note == "$WAIT_NOTE"* ]] && break
      id=''
    done < <(q list)
    [ -n "$id" ] || break
    q set "$id" approved "aprovada pelo dono; vaga liberada, worker devido em 24 h" >/dev/null || break
    echo "promoted $id"
  done
  # (2) approved and no worker after 24 h: one note per id per UTC day
  mkdir -p "$MARKS" 2>/dev/null || true
  while IFS=$'\t' read -r id due owner title; do
    [ -n "$id" ] || continue
    mark="$MARKS/$id.$today"
    [ -e "$mark" ] && continue
    : > "$mark"
    n=$((n + 1))
    if [ "$now_e" -ge $((due + 86400)) ]; then
      give+="${give:+; }$id ($title)"
    else
      launch+="${launch:+; }$id ($title)"
    fi
  done < <(q stale)
  [ "$n" -gt 0 ] || return 0
  line="Melhorias aprovadas ha mais de 24 h sem worker ($n)."
  [ -z "$launch" ] || line+=" Lancar o worker agora: $launch."
  [ -z "$give" ] || line+=" Sem worker ha mais de 48 h, devolver ao dono para descartar ou mandar lancar: $give."
  line+=" Fila: bin/fm-improvement-queue.sh list --open; ao lancar, set <id> building; descartada, set <id> dropped."
  inbox "$line"
  echo "alerted $n"
  find "$MARKS" -type f -mtime +7 -delete 2>/dev/null || true
}

case "${1:-}" in
  ingest) shift; cmd_ingest "$@" ;;
  seed) shift; cmd_seed "$@" ;;
  watch) shift; [ $# -eq 0 ] || usage; cmd_watch ;;
  *) usage ;;
esac
