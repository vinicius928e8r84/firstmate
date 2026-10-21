#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id>
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# FM_REMOTE_READINESS_DEADLINE, when set to an absolute $SECONDS value, bounds
# every doctor run so the whole sequence ends by then; a run cut off by it
# returns 255 like any transport that could not complete, with
# FM_REMOTE_READINESS_TIMED_OUT=1 so the caller can name the deferral.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/fm-timeout-lib.sh"

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=
FM_REMOTE_READINESS_TIMED_OUT=0

# One doctor run, cut off at FM_REMOTE_READINESS_DEADLINE when one is set.
# Sets FM_REMOTE_READINESS_OUT and returns the doctor's status, or 255 when the
# deadline cut it off.
fm_remote_readiness_run() { # <bin-dir> <secondmate-id> [doctor-args...]
  local bin_dir=$1 id=$2 remaining rc
  shift 2
  if [ -n "${FM_REMOTE_READINESS_DEADLINE:-}" ]; then
    remaining=$((FM_REMOTE_READINESS_DEADLINE - SECONDS))
    if [ "$remaining" -lt 1 ]; then
      FM_REMOTE_READINESS_TIMED_OUT=1
      return 255
    fi
    FM_REMOTE_READINESS_OUT=$(fm_run_timed "$remaining" "$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "$@" < /dev/null 2>&1)
    rc=$?
    if fm_timed_out "$rc"; then
      FM_REMOTE_READINESS_TIMED_OUT=1
      return 255
    fi
    return "$rc"
  fi
  FM_REMOTE_READINESS_OUT=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "$@" < /dev/null 2>&1)
}

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id>
  local bin_dir=$1 id=$2 rc
  FM_REMOTE_READINESS_TIMED_OUT=0

  fm_remote_readiness_run "$bin_dir" "$id"
  rc=$?
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  fm_remote_readiness_run "$bin_dir" "$id" --fix
  rc=$?
  [ "$rc" -ne 255 ] || return 255

  fm_remote_readiness_run "$bin_dir" "$id"
  rc=$?
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
