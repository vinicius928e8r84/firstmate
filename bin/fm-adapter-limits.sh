#!/usr/bin/env bash
# fm-adapter-limits.sh - read and check the adapter time limits table.
#
# Usage:
#   fm-adapter-limits.sh get <name>    print one value in its table unit
#   fm-adapter-limits.sh list          print the table without comments
#   fm-adapter-limits.sh check         verify every knob fits the smallest limit it must stay inside
#
# bin/fm-adapter-limits.tsv is the single owner of the numbers the watcher arm's
# back-off, TERM wait and confirmation window must stay inside: the Claude hook
# timeout, the Pi/omp/OpenCode ready timeout, and their retire allowance. The arm
# (bin/fm-watch-arm.sh, bin/fm-wake-lib.sh) reads its defaults from the table
# through fm_adapter_limit; the Pi, omp and OpenCode adapters are TypeScript and
# JavaScript and keep their own constants, so a change to one of their limits
# starts with the table row and the check below.
#
# check enforces, in the table's units:
#   arm_confirm_cap + arm_backoff_cap <= claude_hook_timeout
#       (a stretched window plus the wait before the next start stays inside the hook)
#   arm_confirm_base <= adapter_ready_timeout
#       (an unloaded start is never terminated by the adapters before its window ends)
#   arm_term_wait + arm_term_cleanup <= adapter_retire_allowance
#       (a terminated arm is gone before the adapters give up waiting for it)
# and exits 1 naming the failed inequality otherwise. A missing row is an error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-adapter-limits-lib.sh
. "$SCRIPT_DIR/fm-adapter-limits-lib.sh"

usage() { sed -n 2,26p "$0"; }

# ms_of <name>: the row's value in milliseconds.
ms_of() {
  local v u
  v=$(fm_adapter_limit "$1") || return 1
  u=$(fm_adapter_limit_field "$1" 3)
  case "$u" in
    s) printf '%s\n' $((v * 1000)) ;;
    ms) printf '%s\n' "$v" ;;
    *) echo "fm-adapter-limits: $1 has unit '$u', expected s or ms" >&2; return 1 ;;
  esac
}

check() {
  local rc=0 a b c
  for n in claude_hook_timeout adapter_ready_timeout adapter_retire_allowance arm_confirm_base arm_confirm_cap arm_backoff_cap arm_term_wait arm_term_cleanup; do
    [ -n "$(fm_adapter_limit "$n")" ] || { echo "fm-adapter-limits: missing row $n" >&2; rc=1; }
  done
  [ "$rc" = 0 ] || return 1
  a=$(( $(ms_of arm_confirm_cap) + $(ms_of arm_backoff_cap) )); b=$(ms_of claude_hook_timeout)
  [ "$a" -le "$b" ] || { echo "FAIL arm_confirm_cap + arm_backoff_cap = ${a}ms exceeds claude_hook_timeout ${b}ms" >&2; rc=1; }
  a=$(ms_of arm_confirm_base); b=$(ms_of adapter_ready_timeout)
  [ "$a" -le "$b" ] || { echo "FAIL arm_confirm_base ${a}ms exceeds adapter_ready_timeout ${b}ms" >&2; rc=1; }
  a=$(( $(ms_of arm_term_wait) + $(ms_of arm_term_cleanup) )); c=$(ms_of adapter_retire_allowance)
  [ "$a" -le "$c" ] || { echo "FAIL arm_term_wait + arm_term_cleanup = ${a}ms exceeds adapter_retire_allowance ${c}ms" >&2; rc=1; }
  [ "$rc" != 0 ] || echo "adapter limits ok"
  return "$rc"
}

case "${1:-}" in
  get) [ $# -eq 2 ] || { usage >&2; exit 2; }
       v=$(fm_adapter_limit "$2"); [ -n "$v" ] || { echo "fm-adapter-limits: no row $2" >&2; exit 1; }
       printf '%s\n' "$v" ;;
  list) grep -v '^[[:space:]]*\(#\|$\)' "$FM_ADAPTER_LIMITS_FILE" ;;
  check) check ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
