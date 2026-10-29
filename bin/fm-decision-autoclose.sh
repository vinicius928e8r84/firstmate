#!/usr/bin/env bash
# fm-decision-autoclose.sh - close ghost OPEN DECISIONS by fact, never by hand.
#
# Usage: fm-decision-autoclose.sh [--dry-run]
#
# Run by bin/fm-wake-drain.sh (main actor) before it presents OPEN DECISIONS;
# FM_DECISION_AUTOCLOSE=0 turns that call off. Only a status log whose task has
# no state/<task>.meta (torn down or retired) is examined, so a live task's log
# is never read, let alone closed. It uses the whole-file fold, never the
# drain's cursor-backed one, so the drain's own presentation cursor does not
# move. In such a log it closes an open decision when:
#   - the key is pending-reply-<corr> and that record's destination task has no
#     state/<task>.meta: closed through fm_pending_reply_close_ghost;
#   - any other key: it appends `resolved [key=<key>]: auto-closed ...` through the
#     self-announced status append, so the close wakes nobody.
# A task that still has its .meta is never touched, even when its agent looks
# dead: that is stuck-worker recovery, not a ghost. Both closes also need the
# task's data/<task>/ directory (left behind by cleanup), which is the proof the
# task was real: a bare status log or record with no such directory is left alone.
# Prints one `closed: <task> [key=<key>] <reason>` line per close, nothing else;
# --dry-run prints `would-close:` and changes nothing. A per-decision failure is
# skipped and the exit status stays 0, so a drain is never blocked by it.
# FM_HOME and the FM_STATE_OVERRIDE / FM_DATA_OVERRIDE overrides select the home.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DRY=false
case "${1:-}" in
  --dry-run) DRY=true ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  '') ;;
  *) echo "error: unknown argument $1" >&2; exit 1 ;;
esac

# Report or perform one close; $1 is the log's task, $2 the key tag, $3 the reason.
note_close() {
  if [ "$DRY" = true ]; then
    echo "would-close: $1$2 $3"
  else
    echo "closed: $1$2 $3"
  fi
}

exclude=$(status_scan_parent_channel_exclude "$STATE")
for f in "$STATE"/*.status; do
  [ -e "$f" ] || continue
  [ "$f" = "$exclude" ] && continue
  task=$(basename "$f"); task="${task%.status}"
  [ ! -e "$STATE/$task.meta" ] || continue
  open=$(status_open_decisions "$f") || continue
  [ -n "$open" ] || continue
  while IFS=$(printf '\t') read -r key verb _note; do
    [ -n "$key" ] || continue
    tag=''
    [ "$key" = default ] || tag=" [key=$key]"
    case "$key" in
      pending-reply-*)
        corr=${key#pending-reply-}
        rec=$(fm_pending_reply_path "$STATE" "$corr")
        [ -f "$rec" ] || continue
        dest=$(fm_pending_reply_get "$rec" task_id)
        [ -n "$dest" ] || continue
        [ ! -e "$STATE/$dest.meta" ] || continue
        [ -d "$DATA/$dest" ] || continue
        reason="auto-closed: destination $dest is retired (no $dest.meta)"
        if [ "$DRY" = true ]; then
          note_close "$task" "$tag" "$reason"
        elif fm_pending_reply_close_ghost "$STATE" "$corr" "$reason" >/dev/null 2>&1; then
          note_close "$task" "$tag" "$reason"
        fi
        ;;
      *)
        [ -d "$DATA/$task" ] || continue
        reason="auto-closed by fact: task $task is gone (no $task.meta, torn down or retired); $verb can no longer be answered"
        if [ "$DRY" = true ]; then
          note_close "$task" "$tag" "$reason"
          continue
        fi
        rc=0
        fm_wake_status_append_self_announced "$STATE" "$f" "resolved$tag: $reason" >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq 2 ] || note_close "$task" "$tag" "$reason"
        ;;
    esac
  done <<EOF
$open
EOF
done
exit 0
