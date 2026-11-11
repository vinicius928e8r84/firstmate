#!/usr/bin/env bash
# fm-lane-active-lib.sh - the ONE owner of which ordinary task records count as
# ACTIVE for the lane and worker caps. Sourced by bin/fm-afk-contract.sh (the
# away spend cap's `live-workers`) and bin/fm-capacity.sh (lanes= and the free
# lane count against config/lane-capacity), so the two can never count
# differently. A secondmate is never counted: each caller filters it first.
#
# A finished worker keeps its state/<id>.meta, and its pane stays open, until
# the owner lands or closes the work, so counting every record counts workers
# that are not running. A record is ACTIVE unless one of these says otherwise:
#   1. its last status event (bin/fm-classify-lib.sh, the same event read the
#      watcher uses) is done, failed, cancelled, a declared paused wait, or a
#      captain-held transfer. A resolved line only closes a decision and is
#      never a state, so it takes the event before it (none before it: active).
#      needs-decision and blocked are NOT ended: the lane still holds a worker
#      that may resume the moment it is answered.
#      An ended record whose busy record (state/<id>.busy-state, bin/fm-busy-lib.sh)
#      says busy since AFTER that event is a worker that resumed, so it stays
#      active; a busy record that does not belong to the current incarnation
#      (gen mismatch, malformed, missing) is no evidence either way.
#   2. its endpoint is positively dead: bin/fm-backend.sh's fm_backend_agent_state
#      answers dead or missing. Any other answer (alive, ambiguous, unreadable,
#      unverified), a record with no target, and a remote record all stay active.
# No status event yet reads as active (a fresh spawn is working). Any doubt
# counts: the cap must never be underestimated.
#
# The read is cheap by design, because bin/fm-spawn.sh calls it: it reads each
# record's last status event and, for a record that survives step 1 only, one
# endpoint probe. It never calls bin/fm-crew-state.sh, which can make
# no-mistakes and forge calls per task.
#
# FM_LANE_ENDPOINT_STATE_BIN lets tests stub the endpoint probe: an executable
# called as `<bin> <backend> <target>` that prints a fm_backend_agent_state word.
#
# Sourceable only; it runs nothing and sets no shell option.

_FM_LANE_ACTIVE_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _FM_LANE_ACTIVE_LIB_DIR="."

# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_LANE_ACTIVE_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$_FM_LANE_ACTIVE_LIB_DIR/fm-busy-lib.sh"

# 0 when the record's busy marker is valid for its current incarnation and says
# busy since after <epoch>.
_fm_lane_busy_after() {  # <state-dir> <id> <epoch>
  local rec ts
  case "$(fm_busy_record_read "$1" "$2" 2>/dev/null)" in busy\ *) ;; *) return 1 ;; esac
  rec=$(fm_busy_record_path "$1" "$2")
  ts=$(sed -n 's/.* ts=\([0-9][0-9]*\).*/\1/p' "$rec" 2>/dev/null | head -1)
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ts" -gt "$3" ]
}

# 0 when <meta>'s endpoint is positively dead (see rule 2 above).
_fm_lane_endpoint_dead() {  # <meta-file>
  local meta=$1 backend target verdict
  command -v fm_backend_agent_state >/dev/null 2>&1 || {
    # shellcheck source=bin/fm-backend.sh
    . "$_FM_LANE_ACTIVE_LIB_DIR/fm-backend.sh" || return 1
  }
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 1
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  if [ -n "${FM_LANE_ENDPOINT_STATE_BIN:-}" ]; then
    verdict=$("$FM_LANE_ENDPOINT_STATE_BIN" "$backend" "$target" 2>/dev/null) || verdict=unreadable
  else
    verdict=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || verdict=unreadable
  fi
  case "$verdict" in dead|missing) return 0 ;; esac
  return 1
}

# 0 when ordinary task <id> in <state-dir> is ACTIVE (rules above).
fm_lane_is_active() {  # <state-dir> <id>
  local state=$1 id=$2 line prev='' verb at ended=0
  line=$(last_status_line "$state/$id.status")
  verb=$(status_line_verb "$line")
  if [ "$verb" = "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}" ]; then
    last_status_line "$state/$id.status" prev >/dev/null
    line=$prev
    verb=$(status_line_verb "$line")
  fi
  case "$verb" in
    done|failed|cancelled) ended=1 ;;
    *) ! status_is_paused_or_captain_held "$line" || ended=1 ;;
  esac
  if [ "$ended" -eq 1 ]; then
    # The last event ended this record; it stays active only if the worker resumed.
    at=$(status_line_at_epoch "$line") || at=$(_fm_status_file_mtime "$state/$id.status") || at=
    case "$at" in ''|*[!0-9]*) return 1 ;; esac
    _fm_lane_busy_after "$state" "$id" "$at" || return 1
  fi
  ! _fm_lane_endpoint_dead "$state/$id.meta"
}
