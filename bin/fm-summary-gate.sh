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
# hour. Treat only an explicit `suppress` as silence: an unknown kind or any
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

last_summary() {
  local at
  at=$(cat "$MARK" 2>/dev/null || true)
  case "$at" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$at" ;; esac
}

write_mark() {  # <epoch>
  local tmp
  mkdir -p "$STATE" || die "cannot create $STATE"
  tmp=$(mktemp "$STATE/.last-summary.XXXXXX") || die "cannot write $STATE"
  printf '%s\n' "$1" > "$tmp" && mv "$tmp" "$MARK" || { rm -f "$tmp"; die "cannot write $MARK"; }
}

lock_acquire() {
  local tries=0 age
  mkdir -p "$STATE" || die "cannot create $STATE"
  while ! mkdir "$LOCK" 2>/dev/null; do
    # A holder that died leaves a lock nobody will release: steal one idle for 30s.
    age=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || date +%s) ))
    [ "$age" -lt 30 ] || { rmdir "$LOCK" 2>/dev/null || true; continue; }
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || die "could not lock $LOCK"
    sleep 0.05
  done
  trap lock_release EXIT
}
lock_release() { rmdir "$LOCK" 2>/dev/null || true; }

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
    last=$(last_summary)
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
    last=$(last_summary)
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
