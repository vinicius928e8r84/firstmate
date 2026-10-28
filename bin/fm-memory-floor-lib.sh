# shellcheck shell=bash
# fm-memory-floor-lib.sh - the free-memory floor below which no new agent
# session may be opened on this machine.
#
# Every worker session costs memory (a measured fleet of 48 agent sessions held
# 9.5 GB and filled the swap), so opening one on a host that is already out of
# memory only makes every session slower and kills the supervision watcher. The
# floor is the captain's fleet rule 3 (2 GB available); bin/fm-spawn.sh calls
# fm_memory_floor_check before it creates anything, for every kind of launch.
#
# FM_SPAWN_MIN_FREE_MB overrides the floor in megabytes (default 2048): 0 turns
# the check off, and a very large value forces a refusal, which is how tests
# drive both outcomes. FM_MEMINFO_OVERRIDE names a /proc/meminfo-shaped file
# that replaces the probe so tests can fake an available-memory figure.
# Available memory is MemAvailable on Linux and free+inactive+speculative pages
# on macOS. A host whose figure cannot be read is not blocked.

FM_MEMORY_FLOOR_EXIT=76

# fm_memory_available_mb: print the available memory in whole megabytes, or
# nothing when it cannot be read.
fm_memory_available_mb() {
  local meminfo=${FM_MEMINFO_OVERRIDE:-/proc/meminfo} value
  if [ -r "$meminfo" ]; then
    value=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1024; exit }' "$meminfo" 2>/dev/null)
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    value=$(vm_stat 2>/dev/null | awk '
      /page size of/ { gsub(/[^0-9]/, "", $8); size = $8 }
      /^Pages free/ || /^Pages inactive/ || /^Pages speculative/ { gsub(/\./, "", $NF); pages += $NF }
      END { if (size > 0) printf "%d", pages * size / 1048576 }')
  fi
  case "$value" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$value"
}

# fm_memory_floor_check <what>
# Return 0 when a new session may open. Otherwise print one refusal line naming
# <what> to stderr and return $FM_MEMORY_FLOOR_EXIT.
fm_memory_floor_check() {
  local what=$1 floor=${FM_SPAWN_MIN_FREE_MB:-2048} available
  case "$floor" in ''|*[!0-9]*) floor=2048 ;; esac
  [ "$floor" -gt 0 ] || return 0
  available=$(fm_memory_available_mb)
  [ -n "$available" ] || return 0
  [ "$available" -lt "$floor" ] || return 0
  echo "error: spawn refused: only ${available} MB of memory is available and a new agent session needs at least ${floor} MB free, so $what was not launched; close finished workers (bin/fm-close-done.sh) or wait for memory to free, then dispatch again (override: FM_SPAWN_MIN_FREE_MB)" >&2
  return "$FM_MEMORY_FLOOR_EXIT"
}
