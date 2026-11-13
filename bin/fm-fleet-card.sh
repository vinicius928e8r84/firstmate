#!/usr/bin/env bash
# fm-fleet-card.sh - a compact, always-complete card of what the supervisor must not lose.
#
# Printed first by a context re-emit (bin/fm-session-start.sh), so the state a
# compaction summary cannot carry survives even when a later, slower stage of the
# digest is cut short. It reads plain files only: it takes no lock, sources no
# library, runs no decision fold, no script of this repository and no network, and
# it launches a fixed number of processes however large the fleet is, so it stays
# fast on a loaded host and cannot be the slow stage itself.
#
# Sections, in priority order (each has its own line and byte ceiling, so a long
# section never pushes a later one out):
#   NOTICES          state/.wake-queue size, distinct keys, oldest row; the last
#                    acknowledgement and the drains that timed out after it
#                    (state/.watch-extension.log)
#   OPEN DECISIONS   the open set persisted by the drain's incremental fold
#                    (state/.<task>.open-decisions-cursor, owned by
#                    bin/fm-classify-lib.sh), plus a note when a status log has
#                    lines the fold has not read yet. Never dropped: past six rows
#                    each row shortens to "task [key]" instead of leaving
#   MERGE QUEUE      ship tasks whose last status line is done with a PR URL or
#                    "ready in branch", and who decides (yolo or the captain)
#   HELD FOR CAPTAIN backlog items carrying a "(hold:" marker
#   CAPTAIN ASKS     data/captain-asks.tsv, a home-local registry: key, first
#                    asked, last asked, count, state, text; only open and recent
#   PAGE ANSWERS     the last Lavish review rounds (state/procevent-inbox) and how
#                    many results still carry no .handled marker
#   QUEUED           the Queued backlog section: a count and the first rows
#   IN FLIGHT        every state/*.meta task, needs-decision, blocked and failed
#                    first, minus the ships already listed under MERGE QUEUE
# The whole card is held to FM_CARD_MAX_BYTES by shortening the lowest-priority
# sections first; the header and OPEN DECISIONS are never cut.
#
# Usage: fm-fleet-card.sh [--max-bytes N]
#   FM_HOME (default: the checkout), FM_STATE_OVERRIDE, FM_DATA_OVERRIDE,
#   FM_CARD_MAX_BYTES (default 5000, about 2.4k tokens), FM_CARD_QUEUED_ROWS
#   (default 5), FM_CARD_TZ (time zone for "asked today"), FM_ASKS_STALE_H
#   (default 36). Always exits 0: a card that cannot be built prints one line.
# fm-session-start.sh runs it; FM_SESSION_START_FLEET_CARD=0 stops that.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
S=${FM_STATE_OVERRIDE:-$FM_HOME/state}
D=${FM_DATA_OVERRIDE:-$FM_HOME/data}
MAX=${FM_CARD_MAX_BYTES:-5000}
QUEUED_ROWS=${FM_CARD_QUEUED_ROWS:-5}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-bytes) MAX=${2:-$MAX}; shift 2 || shift ;;
    -h | --help) sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) printf 'fm-fleet-card: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$MAX" in '' | *[!0-9]*) MAX=5000 ;; esac
case "$QUEUED_ROWS" in '' | *[!0-9]*) QUEUED_ROWS=5 ;; esac
[ -z "${FM_CARD_TZ:-}" ] || export TZ=$FM_CARD_TZ
export LC_ALL=C

NOW=$(date +%s)
# Midnight today in the card's time zone, from the clock itself.
DAY0=$((NOW - (10#$(date +%H) * 3600 + 10#$(date +%M) * 60 + 10#$(date +%S))))
GEN=$(date -u +%H:%MZ)

metas=()
for f in "$S"/*.meta; do [ -f "$f" ] && metas+=("$f"); done
cursors=()
for f in "$S"/.*.open-decisions-cursor; do [ -f "$f" ] && cursors+=("$f"); done
statuses=()
for f in "${metas[@]+"${metas[@]}"}"; do [ -f "${f%.meta}.status" ] && statuses+=("${f%.meta}.status"); done
for f in "${cursors[@]+"${cursors[@]}"}"; do
  t=${f##*/.}
  t=${t%.open-decisions-cursor}
  [ -f "$S/$t.status" ] && statuses+=("$S/$t.status")
done

# cap <lines> <bytes>: pass the first line (the section title), then at most N
# body lines and B bytes, and say how much was left out.
cap() {
  awk -v n="$1" -v b="$2" '
    NR == 1 { print; next }
    { body++; if (body <= n && used + length($0) + 1 <= b) { print; used += length($0) + 1 } else left++ }
    END { if (left) printf "- (+%d more row(s) not on the card)\n", left }'
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-card.XXXXXX" 2>/dev/null) || { printf 'FLEET CARD UNAVAILABLE: no scratch directory\n'; exit 0; }
trap 'rm -rf "$TMP"' EXIT

# --- 1. notices ---------------------------------------------------------------
{
  printf 'NOTICES\n'
  if [ -f "$S/.wake-queue" ]; then
    awk -F '\t' -v now="$NOW" '
      NF >= 5 { n++; if (min == "" || $1 < min) min = $1; if (!($4 in seen)) { seen[$4] = 1; u++ } }
      END { printf "- queue: %d row(s), %d distinct key(s), oldest %d min old\n", n, u, (n ? int((now - min) / 60) : 0) }' "$S/.wake-queue"
  else
    printf -- '- queue: no state/.wake-queue\n'
  fi
  if [ -f "$S/.watch-extension.log" ]; then
    tail -n 600 "$S/.watch-extension.log" | awk '
      /inline-ack through=/ { last = $1; thr = $0; sub(/.*through=/, "", thr); sub(/ .*/, "", thr); to = 0 }
      /inline-drain unavailable status=timeout/ { to++ }
      END { printf "- last ack: %s (through %s); drains that timed out after it: %d\n", (last == "" ? "none in the last 600 log lines" : last), (thr == "" ? "-" : thr), to }'
  fi
} | cap 3 400 > "$TMP/1"

# --- 2. open decisions --------------------------------------------------------
{
  if [ "${#statuses[@]}" -gt 0 ]; then
    wc -c "${statuses[@]}" 2>/dev/null | awk '$2 != "total" { print "#SIZE\t" $2 "\t" $1 }'
  fi
  for c in "${cursors[@]+"${cursors[@]}"}"; do
    printf '#CURSOR\t%s\n' "$c"
    cat "$c" 2>/dev/null
  done
} | awk -F '\t' '
  $1 == "#SIZE" { f = $2; sub(/.*\//, "", f); sub(/\.status$/, "", f); size[f] = $3 + 0; next }
  $1 == "#CURSOR" { t = $2; sub(/.*\/\./, "", t); sub(/\.open-decisions-cursor$/, "", t); next }
  /^offset=/ { if (size[t] > substr($0, 8) + 0) lag[t] = 1; next }
  /^(version|ident)=/ || !NF { next }
  NF >= 2 { n++; task[n] = t; key[n] = $1; kind[n] = $2; note[n] = $3 }
  END {
    nl = 0; for (t in lag) nl++
    printf "OPEN DECISIONS (%d, from the drain'"'"'s incremental fold%s)\n", n, (nl ? "; " nl " status log(s) have lines it has not folded yet" : "")
    short = (n > 6)
    for (i = 1; i <= n; i++) {
      if (short) { printf "- %s [%s]\n", task[i], key[i]; continue }
      s = note[i]; if (length(s) > 70) s = substr(s, 1, 69) "~"
      printf "- %s [%s] %s: %s\n", task[i], key[i], kind[i], s
    }
  }' > "$TMP/2"

# --- 3 + 8. merge queue and tasks in flight: one awk over metas and status logs ---
awk -v now="$NOW" '
  function age(t) { if (t == "") return "?"; t = now - t; if (t < 3600) return int(t / 60) "m"; if (t < 172800) return int(t / 3600) "h"; return int(t / 86400) "d" }
  function rank(v) { return (v == "needs-decision") ? 0 : (v == "blocked") ? 1 : (v == "failed") ? 2 : (v == "working") ? 3 : (v == "paused") ? 4 : (v == "done") ? 5 : 6 }
  FNR == 1 { f = FILENAME; sub(/.*\//, "", f); id = f; sub(/\.(meta|status)$/, "", id); ismeta = (f ~ /\.meta$/); if (ismeta) ids[id] = 1 }
  ismeta { p = index($0, "="); if (p) meta[id, substr($0, 1, p - 1)] = substr($0, p + 1); next }
  /[^[:space:]]/ { last[id] = $0 }
  END {
    for (id in ids) {
      l = last[id]; v = l; sub(/[ :\[].*/, "", v); if (l == "") v = "-"
      at = ""; if (match(l, /\[at=[0-9]+\]/)) at = substr(l, RSTART + 4, RLENGTH - 5)
      note = l; sub(/^[^:]*: */, "", note); gsub(/[\t\r]/, " ", note)
      pr = ""; num = ""; if (match(l, /https:\/\/[^ ]*\/pull\/[0-9]+/)) { pr = substr(l, RSTART, RLENGTH); num = pr; sub(/.*\//, "", num) }
      if (pr != "") gsub(/https:\/\/[^ ]*\/pull\/[0-9]+/, "#" num, note)
      if (length(note) > 60) note = substr(note, 1, 59) "~"
      k = meta[id, "kind"]; mo = meta[id, "mode"]; yo = meta[id, "yolo"]
      tag = k; if (mo != "") tag = tag "/" mo; if (yo == "on") tag = tag " yolo"
      who = (yo == "on" ? "(yolo: firstmate merges when green)" : "(needs the captain'"'"'s word)")
      if (k == "ship" && v == "done" && pr != "" && !(pr in seenpr)) { seenpr[pr] = 1; printf "M\t%s %s %s\n", pr, id, who; continue }
      if (k == "ship" && v == "done" && l ~ /ready in branch /) { br = l; sub(/.*ready in branch /, "", br); sub(/[ ,;(].*/, "", br); printf "M\tbranch %s %s %s\n", br, id, who; continue }
      printf "F\t%d\t%012d\t- %s [%s] %s %s: %s\n", rank(v), 999999999999 - (at + 0), id, tag, v, age(at), note
    }
  }' "${metas[@]+"${metas[@]}"}" "${statuses[@]+"${statuses[@]}"}" </dev/null > "$TMP/inflight" 2>/dev/null
awk -F '\t' '$1 == "M" { r[++n] = "- " $2 } END { printf "MERGE QUEUE (%d ship(s) ready: PR or local branch)\n", n; for (i = 1; i <= n; i++) print r[i]; if (!n) print "- none" }' "$TMP/inflight" | cap 6 800 > "$TMP/3"

# --- 4. holds and 5. captain asks ----------------------------------------------
if [ -f "$D/backlog.md" ]; then
  awk '
    /^## / { sec = substr($0, 4) }
    sec != "Done" && /^- \[ \] / && /\(hold: / { n++; t = substr($0, 7); id = t; sub(/ - .*/, "", id); ti = substr(t, length(id) + 4); sub(/ \((repo|kind|since|hold):.*/, "", ti); if (length(ti) > 70) ti = substr(ti, 1, 69) "~"; h[n] = "- " id ": " ti }
    END { printf "HELD FOR CAPTAIN (%d in the backlog; bin/fm-tasks-axi.sh list)\n", n; for (i = n; i > 0; i--) print h[i] }' "$D/backlog.md" | cap 4 500 > "$TMP/4"
else
  printf 'HELD FOR CAPTAIN (no data/backlog.md)\n' > "$TMP/4"
fi
if [ -f "$D/captain-asks.tsv" ]; then
  awk -F '\t' -v now="$NOW" -v day0="$DAY0" -v stale="$(( ${FM_ASKS_STALE_H:-36} * 3600 ))" '
    $5 == "open" && now - $2 < stale { n++; t = $6; if (length(t) > 90) t = substr(t, 1, 89) "~"; a[n] = sprintf("%012d\t- %s", $3, t) }
    $3 >= day0 { today++ }
    END {
      for (i = 2; i <= n; i++) { x = a[i]; j = i - 1; while (j > 0 && a[j] < x) { a[j + 1] = a[j]; j-- } a[j + 1] = x }
      printf "CAPTAIN ASKS (%d open; %d asked or repeated today)\n", n, today + 0
      for (i = 1; i <= n; i++) { r = a[i]; sub(/^[^\t]*\t/, "", r); print r }
    }' "$D/captain-asks.tsv" | cap 5 600 > "$TMP/5"
else
  printf 'CAPTAIN ASKS (no data/captain-asks.tsv in this home)\n' > "$TMP/5"
fi

# --- 6. last Lavish review rounds -----------------------------------------------
{
  unhandled=0
  results=()
  for r in "$S/procevent-inbox"/lavish-*.result; do
    [ -f "$r" ] || continue
    results+=("$r")
    [ -e "${r%.result}.handled" ] || unhandled=$((unhandled + 1))
  done
  printf 'PAGE ANSWERS (%d result(s) with no handled marker)\n' "$unhandled"
  if [ "${#results[@]}" -gt 0 ]; then
    stat -c '%Y	%n' "${results[@]}" 2>/dev/null | sort -rn | head -n 40 | awk -F '\t' -v now="$NOW" '
      function age(t) { t = now - t; if (t < 3600) return int(t / 60) "m"; if (t < 172800) return int(t / 3600) "h"; return int(t / 86400) "d" }
      { f = $2; base = f; sub(/\.result$/, "", base); hf = base ".handled"; handled = ((getline junk < hf) >= 0); close(hf)
        st = ""
        while ((getline line < f) > 0) if (line ~ /^  status: /) st = substr(line, 11)
        close(f)
        if (st != "feedback" && st != "ended") next
        src = base; sub(/.*\//, "", src)
        printf "- %s %s %s%s\n", age($1), src, st, (handled ? "" : " UNHANDLED")
      }'
  fi
} 2>/dev/null | cap 5 700 > "$TMP/6"

# --- 7. queued work ---------------------------------------------------------------
if [ -f "$D/backlog.md" ]; then
  awk -v rows="$QUEUED_ROWS" '
    /^## / { sec = substr($0, 4); next }
    sec == "Queued" && /^- \[ \] / && !/\(hold: / { n++; if (n <= rows) { t = substr($0, 7); id = t; sub(/ - .*/, "", id); ti = substr(t, length(id) + 4); sub(/ \((repo|kind|since|hold):.*/, "", ti); if (length(ti) > 60) ti = substr(ti, 1, 59) "~"; q[n] = "- " id ": " ti } }
    END { printf "QUEUED (%d ready to dispatch; first %d; bin/fm-tasks-axi.sh ready)\n", n, (n < rows ? n : rows); for (i = 1; i <= n && i <= rows; i++) print q[i] }' "$D/backlog.md" | cap "$QUEUED_ROWS" 700 > "$TMP/7"
else
  printf 'QUEUED (no data/backlog.md)\n' > "$TMP/7"
fi

# --- 8. in flight ---------------------------------------------------------------------
{
  printf 'IN FLIGHT (not already under MERGE QUEUE; bin/fm-crew-state.sh <id>)\n'
  awk -F '\t' '$1 == "F"' "$TMP/inflight" | sort -t "$(printf '\t')" -k2,2n -k3,3 | cut -f4-
} | cap 12 1300 > "$TMP/8"

# --- assemble under the ceiling -----------------------------------------------------------
# Shorten from the lowest priority up: a section drops to its title and a note,
# never the header or OPEN DECISIONS.
HEADER="FLEET CARD (generated $GEN; ceiling $MAX B)"
total() { local t=$((${#HEADER} + 1)) f; for f in "$@"; do t=$((t + $(wc -c < "$TMP/$f"))); done; printf '%s\n' "$t"; }
for n in 8 7 6 5 4 3 1; do
  [ "$(total 1 2 3 4 5 6 7 8)" -le "$MAX" ] && break
  rows=$(($(wc -l < "$TMP/$n") - 1))
  { head -n 1 "$TMP/$n"; [ "$rows" -le 0 ] || printf -- '- (%d row(s) shortened away to fit %d B; see the command in the title)\n' "$rows" "$MAX"; } > "$TMP/$n.cut"
  mv "$TMP/$n.cut" "$TMP/$n"
done
printf '%s\n' "$HEADER"
cat "$TMP/1" "$TMP/2" "$TMP/3" "$TMP/4" "$TMP/5" "$TMP/6" "$TMP/7" "$TMP/8"
exit 0
