#!/usr/bin/env bash
# fm-hold.sh - set, clear, or show state/HOLD, the one file that stops the fleet from starting work.
#
# Usage: fm-hold.sh set [--until <epoch|YYYY-MM-DDTHH:MM[:SS]Z>] [--reason <text>]
#        fm-hold.sh clear
#        fm-hold.sh status
#
# While state/HOLD exists and its optional `until=` time has not passed, bin/fm-spawn.sh
# (fresh launch and --relaunch), bin/fm-control.sh relaunch and the watcher's secondmate
# auto-relaunch refuse with exit 75 and a message naming the file. An expired `until=` means
# no HOLD. The file holds optional `until=<epoch or ISO UTC>` and `reason=<text>` lines;
# fm_hold_refuse in bin/fm-wake-lib.sh owns the check, this script only writes and reads the file.
# State is state/ under the effective FM_HOME (FM_STATE_OVERRIDE wins), so set FM_HOME explicitly.
#
# Exit: 0 ok (status: a HOLD is in force); 1 status found no HOLD in force; 2 usage or bad value.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
_fm_wake_require_classify

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
}

die_usage() {
  echo "fm-hold: $1" >&2
  exit 2
}

HOLD_FILE=$(fm_hold_file)

cmd_set() {
  local until_arg='' reason='' epoch tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --until) [ "$#" -ge 2 ] || die_usage "--until needs a value"; until_arg=$2; shift 2 ;;
      --reason) [ "$#" -ge 2 ] || die_usage "--reason needs a value"; reason=$2; shift 2 ;;
      *) die_usage "unknown argument: $1" ;;
    esac
  done
  case "$reason" in *$'\n'*) die_usage "--reason must be one line" ;; esac
  if [ -n "$until_arg" ]; then
    case "$until_arg" in
      *[!0-9]*) epoch=$(fm_utc_iso_to_epoch "$until_arg") || die_usage "--until must be an epoch or YYYY-MM-DDTHH:MM[:SS]Z, got: $until_arg" ;;
      *) epoch=$until_arg ;;
    esac
  fi
  mkdir -p "$(dirname "$HOLD_FILE")" || exit 2
  tmp="$HOLD_FILE.tmp.$$"
  {
    [ -z "${epoch:-}" ] || printf 'until=%s\n' "$epoch"
    [ -z "$reason" ] || printf 'reason=%s\n' "$reason"
  } > "$tmp" || { rm -f "$tmp"; exit 2; }
  mv -f "$tmp" "$HOLD_FILE" || { rm -f "$tmp"; exit 2; }
  echo "HOLD set: $HOLD_FILE"
  cmd_status || true
}

cmd_clear() {
  if [ -e "$HOLD_FILE" ] || [ -L "$HOLD_FILE" ]; then
    rm -f "$HOLD_FILE" || exit 2
    echo "HOLD cleared: $HOLD_FILE"
  else
    echo "no HOLD to clear: $HOLD_FILE"
  fi
}

cmd_status() {
  if fm_hold_active; then
    if [ -n "$FM_HOLD_UNTIL" ]; then
      echo "HOLD in force until $FM_HOLD_UNTIL (epoch) - ${FM_HOLD_REASON:-no reason recorded} [$HOLD_FILE]"
    else
      echo "HOLD in force with no end time - ${FM_HOLD_REASON:-no reason recorded} [$HOLD_FILE]"
    fi
    return 0
  fi
  if [ -e "$HOLD_FILE" ]; then
    echo "no HOLD in force: $HOLD_FILE has expired"
  else
    echo "no HOLD in force"
  fi
  return 1
}

case "${1:-}" in
  set) shift; cmd_set "$@" ;;
  clear) [ "$#" -eq 1 ] || die_usage "clear takes no arguments"; cmd_clear ;;
  status) [ "$#" -eq 1 ] || die_usage "status takes no arguments"; cmd_status ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
