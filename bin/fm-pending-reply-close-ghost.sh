#!/usr/bin/env bash
# fm-pending-reply-close-ghost.sh - guarded operator close of a ghost
# pending-reply record.
#
# Usage: fm-pending-reply-close-ghost.sh <pending-reply-id|pending-reply-key> --reason <text> [--min-age-days <n>]
#
# A pending-reply record whose endpoint is retired or unresolvable (no task
# metadata, a dead local agent, an unreachable remote host) can never receive
# the correlated report that resolves it, and fm-send refuses to resend to it,
# so its escalation decision stays open forever. This command closes it: the
# record is resolved via=ghost-close and the keyed decision is closed with the
# owned note of fm_pending_reply_resolved_note plus the reason, so the open
# decision really drops out of the fold. It refuses without an explicit
# non-empty --reason, refuses an unknown id, and refuses while the endpoint is
# live and resolvable. An already-closed record is reported and left as it is.
# A reachable remote host whose secondmate endpoint cannot be proven dead (the
# state read timed out or was unreadable) closes only when the task shows no
# sign of life after the request and the request is older than --min-age-days
# (default FM_PENDING_REPLY_GHOST_MIN_AGE_DAYS, else 7), or the read failed
# twice in a row; there is no force.
# bin/fm-pending-reply-lib.sh (fm_pending_reply_close_ghost) owns the policy.
# FM_HOME must be set explicitly, like fm-send.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; refusing to resolve pending replies without an explicit firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }

id='' reason='' have_reason=0 min_age=''
while [ $# -gt 0 ]; do
  case "$1" in
    --reason)
      [ $# -ge 2 ] || { echo "error: --reason needs a value" >&2; exit 1; }
      reason=$2
      have_reason=1
      shift 2
      ;;
    --min-age-days)
      [ $# -ge 2 ] || { echo "error: --min-age-days needs a value" >&2; exit 1; }
      case "$2" in ''|*[!0-9]*) echo "error: --min-age-days needs a whole number of days" >&2; exit 1 ;; esac
      min_age=$2
      shift 2
      ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    -*) echo "error: unknown option $1" >&2; exit 1 ;;
    *)
      [ -z "$id" ] || { echo "error: only one pending-reply id is accepted" >&2; exit 1; }
      id=$1
      shift
      ;;
  esac
done
[ -n "$id" ] || { echo "error: a pending-reply id is required (usage: fm-pending-reply-close-ghost.sh <id> --reason <text>)" >&2; exit 1; }
[ "$have_reason" = 1 ] || { echo "error: --reason <text> is required to close a ghost pending reply" >&2; exit 1; }

# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

corr=${id#pending-reply-}
rec=$(fm_pending_reply_path "$STATE" "$corr")
if [ -f "$rec" ] && [ "$(fm_pending_reply_get "$rec" phase)" = resolved ]; then
  fm_pending_reply_close_escalation "$STATE" "$corr" || true
  echo "pending reply $corr is already resolved; nothing to close"
  exit 0
fi
FM_PENDING_REPLY_CLOSE_VERDICT=''
fm_pending_reply_close_ghost "$STATE" "$corr" "$reason" "$min_age"
echo "closed ghost pending reply $corr (task $(fm_pending_reply_get "$rec" task_id)): $FM_PENDING_REPLY_CLOSE_VERDICT"
