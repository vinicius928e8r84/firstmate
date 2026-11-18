#!/usr/bin/env bash
# fm-summary-gate.sh - the quiet-orchestrator gate: at most one non-urgent
# summary to the captain per hour.
#
# Usage:
#   fm-summary-gate.sh decide <kind>   exit 0 and print `send`, or exit 1 and print `suppress`
#   fm-summary-gate.sh status          print the last summary time and the seconds until the next is allowed
#   fm-summary-gate.sh mark            record a summary as sent now (one that went out without `decide`)
#   fm-summary-gate.sh compose <kind>  stdin = the draft message; stdout = exactly what to send the captain
#
# <kind> is one of:
#   summary                   a routine progress or monitoring summary: rate limited
#   merge-ready               a PR or branch ready for the captain's merge call
#   blocker                   a real blocker or failure
#   decision                  a decision, approval, credential, or other call that is the captain's
# Only `summary` is ever suppressed. merge-ready, blocker, and decision always
# print `send` and exit 0, and never move the mark, so an urgent message can
# neither be held back nor use up the hour's summary.
#
# `decide summary` is an atomic check-and-mark under a lock: it prints `send`
# and records now as the last summary time only when no summary went out in the
# last FM_SUMMARY_GATE_SECS seconds (default 3600), otherwise it prints
# `suppress` and the summary stays unsent (fold it into the next one). The mark
# lives in state/.last-summary as one epoch, so a restarted session keeps the
# hour; a mark that is unreadable, not a number, or dated in the future counts
# as no summary yet. Treat only an explicit `suppress` as silence: an unknown kind or any
# error exits 2 and the caller must send, so a broken gate can never swallow a
# message the captain needs.
#
# `compose <kind>` is the one path a captain-bound message takes. Send exactly
# its stdout; empty stdout with exit 1 means say nothing. It (1) puts every
# still-open worker question (a needs-decision or blocked status line nobody
# resolved, read through bin/fm-classify-lib.sh) first, until it has been shown
# once; (2) drops a draft identical (whitespace aside) to the last one sent, so
# a repeated notice is silent by code; (3) holds a `summary` draft to the hourly
# `decide` rule, while merge-ready, blocker, and decision drafts are never held.
# The last sent draft and question block are hashed in state/.last-sent-msg and
# state/.last-sent-questions. An error exits 2 and the caller must send the
# draft as written.
#
# Environment: FM_HOME (default: the code root), FM_STATE_OVERRIDE,
# FM_SUMMARY_GATE_NOW (fixed epoch, tests).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MARK="$STATE/.last-summary"
LOCK="$STATE/.summary-gate.lock"
GATE_SECS=${FM_SUMMARY_GATE_SECS:-3600}
case "$GATE_SECS" in ''|*[!0-9]*) GATE_SECS=3600 ;; esac

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

now_epoch() {
  case "${FM_SUMMARY_GATE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s' "$FM_SUMMARY_GATE_NOW" ;;
  esac
}

# The last summary epoch, or 0 when there is none. A mark that is unreadable,
# not a number, or dated after <now> (a clock stepped back, a test clock) counts
# as none, so a bad mark can only ever let a summary through, never mute them.
last_summary() {  # <now>
  local at
  at=$(cat "$MARK" 2>/dev/null || true)
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  if [ "$at" -gt "$1" ]; then at=0; fi
  printf '%s' "$at"
}

write_mark() {  # <epoch>
  local tmp
  mkdir -p "$STATE" || die "cannot create $STATE"
  tmp=$(mktemp "$STATE/.last-summary.XXXXXX") || die "cannot write $STATE"
  if ! { printf '%s\n' "$1" > "$tmp" && mv "$tmp" "$MARK"; }; then
    rm -f "$tmp"
    die "cannot write $MARK"
  fi
}

# Modification epoch of <path>, or fail with nothing printed. GNU stat and BSD
# stat disagree on the flag, and each one's wrong-flag form prints a
# filesystem report, so the output is only ever accepted when it is all digits.
path_mtime() {  # <path>
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$m"
}

lock_release() {
  trap - EXIT
  rmdir "$LOCK" 2>/dev/null || true
}

lock_acquire() {
  local tries=0 mtime
  mkdir -p "$STATE" || die "cannot create $STATE"
  while ! mkdir "$LOCK" 2>/dev/null; do
    # A holder that died leaves a lock nobody will release: steal one idle for
    # 30s. A lock whose age cannot be read has just been released or taken, so
    # the next pass retries instead of guessing.
    if mtime=$(path_mtime "$LOCK") && [ $(( $(date +%s) - mtime )) -ge 30 ]; then
      rmdir "$LOCK" 2>/dev/null || true
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 200 ] || die "could not lock $LOCK"
    sleep 0.05
  done
  trap lock_release EXIT
}

# <now> -> success iff a summary may go out now; records the mark when it may.
# The caller holds the lock.
summary_may_send() {
  local last
  last=$(last_summary "$1")
  if [ "$last" -gt 0 ] && [ "$(($1 - last))" -lt "$GATE_SECS" ]; then return 1; fi
  write_mark "$1"
}

hash_text() {  # stdin -> checksum of its whitespace-normalised text
  tr -s '[:space:]' ' ' | cksum | cut -d' ' -f1,2
}

# One "- <task> [<key>] (<verb>): <note>" line per still-open worker question.
open_questions() {
  local f task key verb note open
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-classify-lib.sh" || return 1
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    task=$(basename "$f" .status)
    open=$(status_open_decisions "$f") || continue
    while IFS=$'\t' read -r key verb note; do
      case "$verb" in needs-decision|blocked) printf -- '- %s [%s] (%s): %s\n' "$task" "$key" "$verb" "$note" ;; esac
    done <<EOF
$open
EOF
  done
}

compose() {  # <kind>; the draft on stdin
  local kind=$1 draft questions out='' now mh qh
  case "$kind" in summary|merge-ready|blocker|decision) ;; *) die "unknown kind '$kind' (expected summary, merge-ready, blocker, or decision)" ;; esac
  draft=$(cat)
  questions=$(open_questions) || die "cannot read worker status"
  lock_acquire
  now=$(now_epoch)
  if [ -n "$questions" ]; then
    qh=$(printf '%s' "$questions" | hash_text)
    if [ "$qh" != "$(cat "$STATE/.last-sent-questions" 2>/dev/null)" ]; then
      out=$(printf 'Perguntas de worker abertas:\n%s' "$questions")
      printf '%s\n' "$qh" > "$STATE/.last-sent-questions" || die "cannot write $STATE"
    fi
  fi
  if [ -n "$(printf '%s' "$draft" | tr -d '[:space:]')" ]; then
    mh=$(printf '%s' "$draft" | hash_text)
    if [ "$mh" != "$(cat "$STATE/.last-sent-msg" 2>/dev/null)" ]; then
      if [ "$kind" != summary ] || summary_may_send "$now"; then
        printf '%s\n' "$mh" > "$STATE/.last-sent-msg" || die "cannot write $STATE"
        out=${out:+$out$'\n\n'}$draft
      fi
    fi
  fi
  lock_release
  [ -n "$out" ] || exit 1
  printf '%s\n' "$out"
}

cmd=${1:-}
case "$cmd" in
  compose) compose "${2:-}" ;;
  decide)
    kind=${2:-}
    case "$kind" in
      merge-ready|blocker|decision) printf 'send\n'; exit 0 ;;
      summary) ;;
      *) die "unknown kind '$kind' (expected summary, merge-ready, blocker, or decision)" ;;
    esac
    lock_acquire
    now=$(now_epoch)
    last=$(last_summary "$now")
    if [ "$last" -gt 0 ] && [ "$((now - last))" -lt "$GATE_SECS" ]; then
      lock_release
      printf 'suppress\n'
      exit 1
    fi
    write_mark "$now"
    lock_release
    printf 'send\n'
    ;;
  status)
    now=$(now_epoch)
    last=$(last_summary "$now")
    if [ "$last" -eq 0 ]; then
      printf 'last-summary: never\nnext-summary-allowed-in: 0s\n'
    else
      wait=$((GATE_SECS - (now - last)))
      [ "$wait" -gt 0 ] || wait=0
      printf 'last-summary: %s\nnext-summary-allowed-in: %ss\n' "$last" "$wait"
    fi
    ;;
  mark)
    lock_acquire
    write_mark "$(now_epoch)"
    lock_release
    ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    ;;
  *) die "usage: fm-summary-gate.sh decide <kind> | status | mark | compose <kind>" ;;
esac
