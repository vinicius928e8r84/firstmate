#!/usr/bin/env bash
# fm-summary-gate.sh - the quiet-orchestrator gate: at most one non-urgent
# summary to the captain per hour.
#
# Usage:
#   fm-summary-gate.sh decide <kind>   exit 0 and print `send`, or exit 1 and print `suppress`
#   fm-summary-gate.sh status          print the last summary time and the seconds until the next is allowed
#   fm-summary-gate.sh mark            record a summary as sent now (one that went out without `decide`)
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

cmd=${1:-}
case "$cmd" in
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
  *) die "usage: fm-summary-gate.sh decide <kind> | status | mark" ;;
esac
