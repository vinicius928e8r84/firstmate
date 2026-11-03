#!/usr/bin/env bash
# fm-quota-silence.sh - read-only probe of the usage-limit state the watcher's
# wake hold (bin/fm-quota-silence-lib.sh) and the Pi limit resume
# (.pi/extensions/fm-cache-keepalive.ts) both use.
#
# Usage: fm-quota-silence.sh status
#
# Reads the account named by config/quota-silence (`claude` when the file is
# absent, so a resume works in a home that never opted into the wake hold) and
# prints one line:
#   exhausted <epoch>   the all_models scope is exhausted until that reset  (exit 0)
#   clear               quota-axi was read and the account is not exhausted (exit 1)
#   unknown             quota-axi is missing, failed, or printed no usable row (exit 2)
# It spends no model tokens and writes nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-silence-lib.sh
. "$SCRIPT_DIR/fm-quota-silence-lib.sh"

case "${1:-}" in
  status) ;;
  -h | --help) sed -n 2,14p "$0"; exit 0 ;;
  *) echo "usage: fm-quota-silence.sh status" >&2; exit 2 ;;
esac

target=$(fm_quota_silence_target)
[ -n "$target" ] || target=claude
command -v jq >/dev/null 2>&1 && command -v "${FM_QUOTA_SILENCE_AXI:-quota-axi}" >/dev/null 2>&1 || { echo unknown; exit 2; }
rc=0
found=$(fm_quota_silence_read "$target") || rc=$?
if [ "$rc" -eq 3 ]; then echo unknown; exit 2; fi
case "$found" in
  '' | *[!0-9]*) echo clear; exit 1 ;;
esac
if [ "$found" -gt "$(date +%s)" ]; then echo "exhausted $found"; exit 0; fi
echo clear
exit 1
