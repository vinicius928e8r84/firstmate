#!/usr/bin/env bash
# fm-quota-snapshot.sh - append one quota-axi snapshot to state/quota-history.jsonl.
#
# Usage: fm-quota-snapshot.sh [--min-gap SECONDS]
#
# quota-axi keeps no history (~/.cache/quota-axi/quotas.json is one snapshot), so a
# question like "how fast did the Claude week burn between two audits" had no data
# (data/numbers-1029/report.md, "Quota point history"). Each run appends one line:
#   {"ts": <epoch>, "snapshot": <the quota-axi --json document>}
# to $FM_HOME/state/quota-history.jsonl (FM_QUOTA_HISTORY overrides the path), one
# JSON object per line.
#
# Meant to run hourly. It is NOT installed anywhere: a home that wants the history adds its
# own cron line, for example
#   7 * * * * FM_HOME=/path/to/home /path/to/firstmate/bin/fm-quota-snapshot.sh
# --min-gap (default 3000) makes a run that comes sooner than that after the last
# line a no-op, so a doubled cron entry or a retry does not write two lines for one hour.
#
# It only reads quota-axi and writes that one file; it never touches a worker, a
# home record, or a credential, and the snapshot holds only what quota-axi prints.
# A missing quota-axi, a failed call, or output that is not valid quota-axi JSON
# (bin/fm-quota-axi-lib.sh's fm_quota_json_valid) writes nothing and exits 1 with the reason.
# Exit status: 0 appended or skipped inside the gap, 1 nothing could be recorded, 2 usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
HISTORY=${FM_QUOTA_HISTORY:-$FM_HOME/state/quota-history.jsonl}
QUOTA=${FM_QUOTA_AXI:-quota-axi}

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-usage-ledger-lib.sh
. "$SCRIPT_DIR/fm-usage-ledger-lib.sh"
outcome=
trap 'fm_usage_record fm-quota-snapshot "${outcome:-exit-$?}" - snapshot' EXIT

gap=3000
while [ $# -gt 0 ]; do
  case "$1" in
    --min-gap) [ $# -ge 2 ] || { echo "--min-gap needs a value" >&2; exit 2; }; gap=$2; shift 2 ;;
    -h|--help) sed -n 2,23p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$gap" in ''|*[!0-9]*) echo "--min-gap must be a whole number of seconds" >&2; exit 2 ;; esac

now=$(date +%s)
if [ -s "$HISTORY" ]; then
  last=$(tail -n 1 "$HISTORY" | jq -r '.ts // empty' 2>/dev/null)
  case "$last" in
    ''|*[!0-9]*) ;;
    *) if [ $((now - last)) -lt "$gap" ]; then outcome=skipped-gap; exit 0; fi ;;
  esac
fi

command -v "$QUOTA" >/dev/null 2>&1 || { echo "fm-quota-snapshot: $QUOTA is not installed" >&2; outcome=no-quota-axi; exit 1; }
snapshot=$("$QUOTA" --json 2>/dev/null </dev/null) || { echo "fm-quota-snapshot: $QUOTA --json failed" >&2; outcome=quota-failed; exit 1; }
if ! printf '%s' "$snapshot" | fm_quota_json_valid >/dev/null 2>&1; then
  echo "fm-quota-snapshot: $QUOTA --json did not print a valid snapshot" >&2
  outcome=invalid-snapshot
  exit 1
fi
mkdir -p "$(dirname "$HISTORY")" || { outcome=no-directory; exit 1; }
printf '%s' "$snapshot" | jq -c --argjson ts "$now" '{ts: $ts, snapshot: .}' >> "$HISTORY" || { outcome=write-failed; exit 1; }
outcome=appended
