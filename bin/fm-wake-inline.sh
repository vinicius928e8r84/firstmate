#!/usr/bin/env bash
# Inline wake drain and turn-end acknowledgement for the main actor.
#
# The model's wake turn used to open with a drain call and close with an ack
# call whose arguments it copied from the drain's WAKE_ACK_REQUIRED line. A
# harness extension that already owns delivery runs both calls instead, so the
# first model call of the turn carries the drain text and the turn-end hook
# acknowledges. This script is the one owner of that pair; bin/fm-wake-drain.sh
# stays the owner of the queue contract (docs/watcher-continuity.md).
#
#   fm-wake-inline.sh drain --ack-out FILE
#       Run bin/fm-wake-drain.sh as the main actor and print what it presented
#       (stdout and stderr merged in order) minus the WAKE_ACK_REQUIRED line,
#       whose arguments go to FILE as "SEQUENCE GENERATION" instead. Exit status
#       is the drain's; on a nonzero status FILE is not written, so a caller
#       falls back to telling the model to drain itself.
#   fm-wake-inline.sh ack SEQUENCE GENERATION
#       Run the exact acknowledgement the drain asked for. Acknowledging rows
#       that are already gone is a harmless no-op, so a repeat is safe.
#
# Output is the drain's own text, so what the model reads is the same filtered
# presentation it read before; nothing is summarized or dropped. An
# unacknowledged wake stays durable, so a caller that never acknowledges (an
# aborted turn, a crash) costs a re-presentation, not a lost wake.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
DRAIN="${FM_WAKE_INLINE_DRAIN:-$SCRIPT_DIR/fm-wake-drain.sh}"

usage() {
  echo "usage: fm-wake-inline.sh drain --ack-out FILE | ack SEQUENCE GENERATION" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
case "$1" in
  drain)
    [ "$#" -eq 3 ] && [ "$2" = --ack-out ] && [ -n "$3" ] || usage
    ack_out=$3
    out=$(mktemp "${TMPDIR:-/tmp}/fm-wake-inline.XXXXXX") || exit 1
    trap 'rm -f -- "$out"' EXIT
    bash "$DRAIN" > "$out" 2>&1
    status=$?
    [ "$status" -eq 0 ] || { cat -- "$out"; exit "$status"; }
    ack_line=$(grep -E '^WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through [0-9]+ --recovery-generation [A-Za-z0-9._-]+$' "$out" | tail -n 1)
    grep -v -E '^WAKE_ACK_REQUIRED: ' "$out"
    if [ -n "$ack_line" ]; then
      seq=${ack_line##*--ack-through }
      seq=${seq%% *}
      generation=${ack_line##*--recovery-generation }
      printf '%s %s\n' "$seq" "$generation" > "$ack_out" || exit 1
    fi
    exit 0
    ;;
  ack)
    [ "$#" -eq 3 ] || usage
    case "$2" in ''|*[!0-9]*) echo "fm-wake-inline: invalid acknowledgement sequence" >&2; exit 2 ;; esac
    case "$3" in ''|*[!A-Za-z0-9._-]*) echo "fm-wake-inline: invalid recovery generation" >&2; exit 2 ;; esac
    exec bash "$DRAIN" --ack-through "$2" --recovery-generation "$3"
    ;;
  *) usage ;;
esac
