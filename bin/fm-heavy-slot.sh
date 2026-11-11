#!/usr/bin/env bash
# fm-heavy-slot.sh - run a heavy job (an end-to-end suite, a full build) in one
# of this machine's few heavy slots, so two heavy jobs never pile onto a host
# that can only carry one.
#
# Usage:
#   fm-heavy-slot.sh run [--wait SECONDS] [--label TEXT] -- <command...>
#   fm-heavy-slot.sh status
#
# run waits for a free slot, runs the command with its own stdin, stdout, and
# stderr, releases the slot when the command ends, and exits with the command's
# status. With no slot free after --wait seconds (default 3600; 0 tries once) it
# runs nothing and exits 75, the same "try again later" status a deferred spawn
# uses. status prints one line per slot, `slot N: free` or
# `slot N: held by <label> (pid P, since <epoch>)`, and always exits 0.
#
# The slot count is the heavy-slots key of config/lane-capacity in the local
# root Firstmate home (default 1; bin/fm-capacity.sh --heavy-slots owns the
# parse and docs/configuration.md "Lane capacity" owns the schema), so every
# home and every project on this machine shares one count. FM_HEAVY_SLOTS
# overrides it for one call. An unreadable config/lane-capacity runs the job
# with one slot rather than none, and says so on stderr.
#
# Each slot is an flock on a file in one per-user directory (FM_HEAVY_SLOT_DIR,
# default /tmp/fm-heavy-slots-<uid>), shared by every home on the machine and by
# a job started from any worktree. The kernel drops the lock when the holder
# dies, so a crashed job never leaves a slot held, and the command does not
# inherit the lock descriptor, so a daemon it leaves behind cannot keep the
# slot. A host without flock (macOS) runs the command at once and says so on
# stderr: the slot is an optimization against load, never a reason to refuse
# work.
#
# Environment: FM_HEAVY_SLOTS, FM_HEAVY_SLOT_DIR, FM_HEAVY_SLOT_POLL (seconds
# between attempts while waiting, default 2), FM_HEAVY_SLOT_WAIT (the default of
# --wait), plus FM_HOME as in the other bin/ scripts.
#
# Exit status: the command's own on run, 75 when no slot freed within --wait,
# 2 on a usage error.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
SLOT_DIR="${FM_HEAVY_SLOT_DIR:-/tmp/fm-heavy-slots-$(id -u)}"
POLL="${FM_HEAVY_SLOT_POLL:-2}"

usage() {
  echo "usage: fm-heavy-slot.sh run [--wait SECONDS] [--label TEXT] -- <command...>" >&2
  echo "       fm-heavy-slot.sh status" >&2
  exit 2
}

is_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

# slot_count: print how many heavy slots this machine has.
slot_count() {
  local n root cfg
  if [ -n "${FM_HEAVY_SLOTS:-}" ]; then
    if is_uint "$FM_HEAVY_SLOTS" && [ "$((10#$FM_HEAVY_SLOTS))" -gt 0 ]; then
      echo "$((10#$FM_HEAVY_SLOTS))"
      return 0
    fi
    echo "fm-heavy-slot: FM_HEAVY_SLOTS must be a positive integer; using config" >&2
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  [ "$(type -t fm_firstmate_root_home)" = function ] || . "$SCRIPT_DIR/fm-wake-lib.sh" 2>/dev/null
  root=$(fm_firstmate_root_home "$FM_HOME" 2>/dev/null) || root=$FM_HOME
  cfg="$root/config"
  if n=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$cfg" "$SCRIPT_DIR/fm-capacity.sh" --heavy-slots 2>/dev/null) &&
    is_uint "$n" && [ "$n" -gt 0 ]; then
    echo "$n"
    return 0
  fi
  echo "fm-heavy-slot: $cfg/lane-capacity is unreadable; using 1 heavy slot" >&2
  echo 1
}

have_flock() { command -v flock >/dev/null 2>&1; }

# slot_held <file>: 0 when another process holds the slot's lock right now.
slot_held() {
  ( exec 8<>"$1" && ! flock -n 8 ) 2>/dev/null
}

cmd_status() {
  local n i f line
  n=$(slot_count)
  have_flock || { echo "fm-heavy-slot: flock is not installed; slots are not enforced on this host"; return 0; }
  i=1
  while [ "$i" -le "$n" ]; do
    f="$SLOT_DIR/slot.$i"
    if [ -f "$f" ] && slot_held "$f"; then
      line=$(head -1 "$f" 2>/dev/null)
      echo "slot $i: held by ${line:-unknown}"
    else
      echo "slot $i: free"
    fi
    i=$((i + 1))
  done
}

cmd_run() {
  local wait_s=${FM_HEAVY_SLOT_WAIT:-3600} label='' n i f deadline now child rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wait) { [ "$#" -ge 2 ] && is_uint "$2"; } || usage; wait_s=$((10#$2)); shift 2 ;;
      --label) [ "$#" -ge 2 ] || usage; label=$2; shift 2 ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  [ "$#" -gt 0 ] || usage
  is_uint "$wait_s" || wait_s=3600
  is_uint "$POLL" && [ "$POLL" -gt 0 ] || POLL=2
  [ -n "$label" ] || label="${FM_TASK_ID:+$FM_TASK_ID: }$1"
  label=$(printf '%s' "$label" | tr '\n\r\t' '   ' | cut -c1-80)

  if ! have_flock; then
    echo "fm-heavy-slot: flock is not installed; running without a slot" >&2
    exec "$@"
  fi
  n=$(slot_count)
  if ! { mkdir -p "$SLOT_DIR" && chmod 700 "$SLOT_DIR"; } 2>/dev/null; then
    echo "fm-heavy-slot: cannot create $SLOT_DIR; running without a slot" >&2
    exec "$@"
  fi
  deadline=$(( $(date +%s) + wait_s ))
  while :; do
    i=1
    while [ "$i" -le "$n" ]; do
      f="$SLOT_DIR/slot.$i"
      exec 9<>"$f" || { echo "fm-heavy-slot: cannot open $f; running without a slot" >&2; exec "$@"; }
      if flock -n 9; then
        printf '%s (pid %s, since %s)\n' "$label" "$$" "$(date +%s)" > "$f" 2>/dev/null
        echo "fm-heavy-slot: slot $i of $n taken for: $label" >&2
        "$@" 9>&- 0<&0 &
        child=$!
        # shellcheck disable=SC2064 # the child id is fixed once it exists
        trap "kill -TERM $child 2>/dev/null" TERM INT HUP
        rc=0
        wait "$child" || rc=$?
        # a trapped signal ends the first wait early; reap the child itself
        while kill -0 "$child" 2>/dev/null; do wait "$child" || rc=$?; done
        : > "$f" 2>/dev/null
        exit "$rc"
      fi
      exec 9>&-
      i=$((i + 1))
    done
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "deferred: all $n heavy slot(s) on this machine stayed busy for ${wait_s} s ($SLOT_DIR); nothing was run - try again later" >&2
      exit 75
    fi
    sleep "$POLL"
  done
}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  run) shift; cmd_run "$@" ;;
  status) [ "$#" -eq 1 ] || usage; cmd_status ;;
  *) usage ;;
esac
