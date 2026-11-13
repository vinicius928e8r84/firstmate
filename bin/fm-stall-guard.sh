#!/usr/bin/env bash
# fm-stall-guard.sh - front-stall guard: wake MAIN, with no model, when the fleet
# has gone quiet in one of three ways nobody would otherwise notice.
#
# Usage:
#   fm-stall-guard.sh [check]   evaluate; print ONE line when a stall is newly alarmed (watcher check)
#   fm-stall-guard.sh scan      evaluate; also queue one durable `check` wake per new stall (cron, no watcher needed)
#   fm-stall-guard.sh status    evaluate read-only; print every current stall and what is already alarmed
#   fm-stall-guard.sh arm       write state/stall-guard.check.sh and register it (fm-check-register.sh)
#   fm-stall-guard.sh disarm    remove the check shim, its trust binding, and the guard's records
#   fm-stall-guard.sh --help    print this help
#
# Reasons (the three stalls). Each reads durable state only, never a screen:
#   coord   A coordinator (state/<id>.meta kind=secondmate, local home) whose own data/backlog.md
#           "## In flight" has open items, and whose newest state/<id>.status line (its `[at=<epoch>]`,
#           else the file mtime) is older than FM_STALL_COORD_SECS (default 7200 = 2 h).
#   alta    A risk-ALTA item that is in flight (in the main backlog "## In flight", or a meta with
#           `risk=alta`) and not already `done`, whose endpoint has had no live agent for longer than
#           FM_STALL_ALTA_SECS (default 3600 = 1 h). ALTA is marked by `risk=alta` in the task meta or by
#           "risco ALTA" / "risk: ALTA" in the item's backlog line or indented note. "No live agent" is
#           fm_backend_agent_state dead|missing, or no meta at all; ambiguous/unreadable/unverified is
#           NOT proof and never counts. The 1 h runs from the first pass that saw it dead
#           (state/.stall-guard/alta__<id>), so the guard must run on a cadence.
#   watcher The watcher is down: no live holder in state/.watch.lock, or a beacon
#           (state/.last-watcher-beat) older than FM_STALL_BEAT_MAX (default 900), for at least
#           FM_STALL_WATCHER_SECS (default 600). A brief hand-off gap is shorter and never alarms.
#           Skipped while state/HOLD exists. A watcher cannot report its own death, so cover this
#           reason with `scan` from cron, e.g.:  */5 * * * * FM_HOME=<home> <home>/bin/fm-stall-guard.sh scan
#
# Contract (idempotent, one warning per stall):
#   * A stall alarms once. Its record in state/.stall-guard/<reason>__<id> carries alerted=<epoch>, and
#     later passes stay silent for it however long it lasts.
#   * When movement returns (new coordinator status, agent alive again, watcher beating) the record is
#     deleted and the warning falls silent; a later, new stall alarms again.
#   * The line names the reason, the id and the evidence:
#       stall-guard: coord mmc-sm: no status for 2h13m (2 open items; last: done ...) | alta x: ...
#     In `check` the watcher turns the line into a `check:` wake. `scan` also appends a durable wake row
#     (key stall:<reason>:<id>) so a drain sees it even with no watcher.
#   * Read-only toward the fleet: it never touches endpoints, projects, processes, or worktrees; it
#     writes only state/.stall-guard/ and (arm/disarm/scan) the check shim and the wake queue.
#
# Env: FM_HOME, FM_STATE_OVERRIDE, FM_STALL_NOW (epoch, tests), FM_STALL_COORD_SECS, FM_STALL_ALTA_SECS,
#   FM_STALL_BEAT_MAX, FM_STALL_WATCHER_SECS, FM_STALL_AGENT_CMD (command `<backend> <target>` printing the
#   agent state, tests), FM_STALL_AGENT_TIMEOUT (seconds per probe, default 8).
# Exit: 0 evaluated (alarm or not), 2 usage, 1 arm/disarm failure.
# Undo: bin/fm-stall-guard.sh disarm  (and remove the cron line if one was added).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BACKLOG="$FM_HOME/data/backlog.md"
GUARD_DIR="$STATE/.stall-guard"
CHECK_ID=stall-guard
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LINE=480

COORD_SECS=${FM_STALL_COORD_SECS:-7200}
ALTA_SECS=${FM_STALL_ALTA_SECS:-3600}
BEAT_MAX=${FM_STALL_BEAT_MAX:-900}
WATCHER_SECS=${FM_STALL_WATCHER_SECS:-600}
AGENT_TIMEOUT=${FM_STALL_AGENT_TIMEOUT:-8}

usage() { sed -n '2,/^# Undo:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

die_usage() { printf 'fm-stall-guard: %s\n' "$1" >&2; usage >&2; exit 2; }

now_epoch() {
  case "${FM_STALL_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_STALL_NOW" ;;
  esac
}

meta_get() {  # <meta-file> <key> -> last value
  local line value=''
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1"
  printf '%s' "$value"
}

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

human() {  # seconds -> 2h13m / 45m
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60)); else printf '%dm' $((s / 60)); fi
}

# last_status <id> -> prints "<epoch>\t<state>\t<text>" of the newest status line, or nothing.
last_status() {
  local f="$STATE/$1.status" line at m
  [ -s "$f" ] || return 0
  line=$(grep -v '^[[:space:]]*$' "$f" | tail -n 1)
  [ -n "$line" ] || return 0
  at=$(printf '%s' "$line" | sed -n 's/.*\[at=\([0-9][0-9]*\)\].*/\1/p' | tail -n 1)
  [ -n "$at" ] || at=$(file_mtime "$f")
  [ -n "$at" ] || return 0
  m=${line%%[ :[]*}
  printf '%s\t%s\t%s\n' "$at" "$m" "$(printf '%s' "$line" | cut -c1-90)"
}

# backlog_inflight <file> -> the "## In flight" section (header excluded).
backlog_inflight() {
  [ -f "$1" ] || return 1
  awk '/^## /{ on = ($0 == "## In flight"); next } on' "$1"
}

# --- records ---------------------------------------------------------------

rec_get() {  # <key-file> <field>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

rec_write() {  # <key-file> <first> <ref> <alerted>
  mkdir -p "$GUARD_DIR" 2>/dev/null || return 1
  printf 'first=%s\nref=%s\nalerted=%s\n' "$2" "$3" "$4" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}

# SEEN lists the record names whose condition holds this pass; the rest are cleared.
SEEN=''
FINDINGS=''   # lines "<reason> <id>: <evidence>" newly alarmed this pass (one per line)
PENDING=''    # record files to mark alerted after delivery: "<file>\t<first>\t<ref>"

# consider <reason> <id> <holds:0|1> <since-epoch-or-empty> <threshold> <ref> <evidence>
consider() {
  local reason=$1 id=$2 holds=$3 since=$4 threshold=$5 ref=$6 evidence=$7 file first rref alerted now
  file="$GUARD_DIR/${reason}__$id"
  [ "$holds" = 1 ] || return 0
  SEEN="$SEEN ${reason}__$id "
  now=$(now_epoch)
  first=$(rec_get "$file" first); rref=$(rec_get "$file" ref); alerted=$(rec_get "$file" alerted)
  # A different reference (e.g. a newer coordinator status) is a new stall.
  if [ -n "$first" ] && [ "$rref" != "$ref" ]; then first=''; alerted=''; fi
  [ -n "$first" ] || first=$now
  [ -n "$since" ] || since=$first
  if [ "$FM_STALL_READONLY" != 1 ]; then
    [ -f "$file" ] && [ "$rref" = "$ref" ] || rec_write "$file" "$first" "$ref" "${alerted:-}"
  fi
  [ $((now - since)) -ge "$threshold" ] || return 0
  if [ -n "$alerted" ]; then
    [ "$FM_STALL_VERBOSE" != 1 ] || FINDINGS="$FINDINGS${reason} $id: $evidence [already alarmed]"$'\n'
    return 0
  fi
  FINDINGS="$FINDINGS${reason} $id: $evidence"$'\n'
  PENDING="$PENDING$file"$'\t'"$first"$'\t'"$ref"$'\n'
}

# --- reason: coordinator -------------------------------------------------

eval_coord() {
  local meta id home n st at age ev
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(meta_get "$meta" kind)" = secondmate ] || continue
    [ -z "$(meta_get "$meta" remote_host)" ] || continue
    id=$(basename "$meta" .meta)
    home=$(meta_get "$meta" home)
    [ -n "$home" ] && [ -f "$home/data/backlog.md" ] || continue
    n=$(backlog_inflight "$home/data/backlog.md" | grep -c '^- \[ \] ')
    [ "${n:-0}" -gt 0 ] || continue
    st=$(last_status "$id")
    if [ -n "$st" ]; then at=${st%%$'\t'*}; else at=$(file_mtime "$meta"); st=$'\t\t'"(no status line)"; fi
    [ -n "$at" ] || continue
    age=$(( $(now_epoch) - at ))
    ev="no status for $(human "$age") ($n open item$([ "$n" = 1 ] || echo s); last: ${st##*$'\t'})"
    consider coord "$id" "$([ "$age" -ge "$COORD_SECS" ] && echo 1 || echo 0)" "$at" "$COORD_SECS" "$at" "$ev"
  done
}

# --- reason: risk ALTA without a live session ----------------------------

agent_state() {  # <backend> <target>
  if [ -n "${FM_STALL_AGENT_CMD:-}" ]; then
    $FM_STALL_AGENT_CMD "$1" "$2" 2>/dev/null
    return
  fi
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh" 2>/dev/null || { printf unreadable; return; }
  fm_run_timed "$AGENT_TIMEOUT" env FM_HOME="$FM_HOME" bash -c \
    '. "$1/fm-backend.sh" && fm_backend_agent_state "$2" "$3"' _ "$SCRIPT_DIR" "$1" "$2" 2>/dev/null \
    || printf unreadable
}

alta_ids() {
  local meta id
  {
    backlog_inflight "$BACKLOG" 2>/dev/null | awk '
      function flush() { if (id != "" && hit) print id }
      /^- \[ \] / { flush(); id = $4; hit = 0 }
      /^- \[ \] |^[ \t]+/ { if (tolower($0) ~ /(risco|risk)[:= ]+alta/) hit = 1 }
      END { flush() }'
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      case "$(meta_get "$meta" risk)" in [Aa][Ll][Tt][Aa]) basename "$meta" .meta ;; esac
    done
  } | sort -u
}

eval_alta() {
  local id meta st state backend target dead ev
  for id in $(alta_ids); do
    meta="$STATE/$id.meta"
    [ "$(meta_get "$meta" kind)" != secondmate ] || continue
    st=$(last_status "$id")
    case "$(printf '%s' "$st" | cut -f2)" in done) continue ;; esac
    dead=0; ev=''
    if [ ! -f "$meta" ]; then
      dead=1; ev="no session record (no state/$id.meta)"
    else
      backend=$(meta_get "$meta" backend); backend=${backend:-tmux}
      target=$(meta_get "$meta" window)
      state=$(agent_state "$backend" "$target")
      case "$state" in
        dead|missing) dead=1; ev="no live agent ($state on $backend ${target:-?}) for over $(human "$ALTA_SECS")" ;;
      esac
    fi
    if [ -n "$st" ]; then ev="$ev; last status $(human $(( $(now_epoch) - $(printf '%s' "$st" | cut -f1) ))) ago"; fi
    consider alta "$id" "$dead" "" "$ALTA_SECS" "alta" "${ev:-}"
  done
}

# --- reason: watcher down ------------------------------------------------

eval_watcher() {
  local pid beat_age beat_at down=0 now since ev
  [ ! -e "$STATE/HOLD" ] || return 0
  now=$(now_epoch)
  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  beat_at=$(file_mtime "$STATE/.last-watcher-beat" || true)
  if [ -n "$beat_at" ]; then beat_age=$((now - beat_at)); else beat_age=''; fi
  case "$pid" in ''|*[!0-9]*) ev="no watcher lock holder" ; down=1 ;; *)
    if kill -0 "$pid" 2>/dev/null; then ev="watcher pid $pid alive"; else ev="watcher pid $pid is gone"; down=1; fi ;;
  esac
  if [ "$down" = 0 ] && [ -n "$beat_age" ] && [ "$beat_age" -ge "$BEAT_MAX" ]; then
    down=1; ev="$ev but its beacon is stale"
  fi
  [ "$down" = 1 ] || { consider watcher watcher 0 "" 0 watcher ""; return 0; }
  since=''
  if [ -n "$beat_at" ]; then since=$beat_at; ev="$ev; last beat $(human "$beat_age") ago"; else ev="$ev; no beacon"; fi
  consider watcher watcher 1 "$since" "$WATCHER_SECS" "watcher" "$ev"
}

# --- run -------------------------------------------------------------------

clear_quiet() {
  local f name
  [ -d "$GUARD_DIR" ] || return 0
  for f in "$GUARD_DIR"/*__*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    case "$SEEN" in *" $name "*) ;; *) rm -f -- "$f" ;; esac
  done
}

append_wake() {  # <key> <text>
  # shellcheck source=bin/fm-wake-lib.sh
  ( FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$SCRIPT_DIR/fm-wake-lib.sh" \
    && fm_wake_append check "$1" "$2" )
}

evaluate() {  # <mode: check|scan|status>
  local mode=$1 line key text out='' row file first ref n kept
  FM_STALL_READONLY=0; FM_STALL_VERBOSE=0
  [ "$mode" != status ] || { FM_STALL_READONLY=1; FM_STALL_VERBOSE=1; }
  [ -d "$STATE" ] || return 0
  if [ "$FM_STALL_READONLY" != 1 ]; then
    mkdir -p "$GUARD_DIR" 2>/dev/null || return 0
    command -v flock >/dev/null 2>&1 && { exec 8>"$STATE/.stall-guard.lock"; flock -n 8 || return 0; }
  fi
  SEEN=''; FINDINGS=''; PENDING=''
  eval_coord; eval_alta; eval_watcher
  [ "$FM_STALL_READONLY" = 1 ] || clear_quiet
  [ -n "$FINDINGS" ] || { [ "$mode" != status ] || echo "stall-guard: no stalls"; return 0; }
  if [ "$mode" = scan ]; then
    # FINDINGS and PENDING are row-aligned in scan mode; a row whose wake could
    # not be queued is dropped so it stays unalarmed and is retried next pass.
    n=0; kept=''
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      n=$((n + 1))
      key="stall:${line%%:*}"; key=${key// /:}
      text="check: stall-guard: $line"
      row=$(printf '%s' "$PENDING" | sed -n "${n}p")
      if append_wake "$key" "$text"; then kept="$kept$row"$'\n'
      else printf 'fm-stall-guard: could not queue a wake for %s\n' "$line" >&2; fi
    done <<EOF
$FINDINGS
EOF
    PENDING=$kept
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    out="${out:+$out | }$line"
  done <<EOF
$FINDINGS
EOF
  out="stall-guard: $out"
  printf '%s\n' "${out:0:$MAX_LINE}"
  [ "$FM_STALL_READONLY" = 1 ] && return 0
  while IFS=$'\t' read -r file first ref; do
    [ -n "$file" ] || continue
    rec_write "$file" "$first" "$ref" "$(now_epoch)"
  done <<EOF
$PENDING
EOF
  return 0
}

# --- arm / disarm ----------------------------------------------------------

arm_stall() {
  local home tmp
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "fm-stall-guard: state directory is unavailable" >&2; return 1; }
  [ ! -L "$CHECK_SHIM" ] || { echo "fm-stall-guard: refusing a symlink at $CHECK_SHIM" >&2; return 1; }
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || { echo "fm-stall-guard: cannot resolve FM_HOME" >&2; return 1; }
  tmp=$(umask 077; mktemp "$STATE/.fm-stall-guard.XXXXXX") || return 1
  printf '%s\n' '#!/usr/bin/env bash' \
    '# Auto-generated by fm-stall-guard.sh - front-stall guard shim.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-stall-guard.sh") check" > "$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$CHECK_SHIM" || { rm -f -- "$tmp"; return 1; }
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    echo "fm-stall-guard: could not register $CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm_stall() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  rm -rf -- "$GUARD_DIR"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check|scan|status) evaluate "${1:-check}" ;;
  arm) arm_stall ;;
  disarm) disarm_stall ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
