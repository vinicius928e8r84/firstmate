#!/usr/bin/env bash
# fm-claude-budget.sh - the daily Claude budget and its above_budget flag.
#
# Usage:
#   fm-claude-budget.sh [--end <YYYY-MM-DDTHH:MM:SSZ>]   compute, record, print a summary
#   fm-claude-budget.sh --flag                           print the recorded flag
#   fm-claude-budget.sh --advice [scout]                 print the dispatch advice
#
# Daily budget = the Claude all_models quota still remaining (percent, from
# `quota-axi --json`) divided by the days left until the end date, so the
# remaining quota lasts to the renewal. The end date is, in order: --end,
# $FM_CLAUDE_BUDGET_END, the first non-comment line of config/claude-budget-end,
# else 2026-11-01T22:00:00Z.
#
# The day's allowance is fixed at the first run of each UTC day (the baseline:
# remaining% and days left at that moment, so a day's allowance does not shrink
# as the day is spent). above_budget is 1 when the quota spent since that
# baseline exceeds the allowance. A run with no readable quota keeps the
# previous record (its flag ages out through --flag) and notes status=no-quota;
# a run after the end date records status=end-passed and above_budget=0.
#
# Records (both under this home, written atomically or appended):
#   state/claude-budget.state   key=value, the flag the dispatch step reads
#   data/claude-budget.log      one TSV row per run:
#                               epoch remaining% days budget%/day spent% above
#
# --flag prints exactly one of: above_budget | within_budget | unknown. A record
# older than FM_CLAUDE_BUDGET_MAX_AGE seconds (default 7200, two hourly runs) or
# a missing one is `unknown`, so a dead cron never pins a stale verdict.
# --advice [scout] prints nothing unless the flag is above_budget, then the one
# advice line bin/fm-dispatch-resolve.sh relays (this script owns its text).
# bin/fm-dispatch-resolve.sh reads it as ADVICE only: when above budget,
# non-HIGH-risk proofs and all scouts should run on Sonnet 5.5 while HIGH-risk
# reviews stay on Opus 5.5. It never changes the resolved profile and an
# explicit captain model choice always wins.
#
# Hourly from cron, with the PATH the quota-axi binary needs:
#   7 * * * * FM_HOME=<home> <code-root>/bin/fm-claude-budget.sh >> <home>/state/.claude-budget.cron.log 2>&1
#
# Environment: FM_HOME (default: the code root), FM_STATE_OVERRIDE,
# FM_DATA_OVERRIDE, FM_CONFIG_OVERRIDE, FM_CLAUDE_BUDGET_NOW (fixed epoch,
# tests). quota-axi output is data only: nothing from it but the percent is
# kept, and no credential is read or printed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE_FILE="$STATE/claude-budget.state"
LOG_FILE="$DATA/claude-budget.log"
DEFAULT_END=2026-11-01T22:00:00Z
MAX_AGE=${FM_CLAUDE_BUDGET_MAX_AGE:-7200}
case "$MAX_AGE" in ''|*[!0-9]*) MAX_AGE=7200 ;; esac

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

now_epoch() {
  case "${FM_CLAUDE_BUDGET_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s' "$FM_CLAUDE_BUDGET_NOW" ;;
  esac
}

state_get() {  # <key>
  [ -f "$STATE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATE_FILE" | head -n 1
}

print_flag() {
  local at above now
  at=$(state_get computed_epoch)
  above=$(state_get above_budget)
  now=$(now_epoch)
  case "$at" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  if [ $((now - at)) -gt "$MAX_AGE" ]; then
    printf 'unknown\n'
  elif [ "$above" = 1 ]; then
    printf 'above_budget\n'
  else
    printf 'within_budget\n'
  fi
}

print_advice() {  # [scout]
  local what='non-HIGH-risk proofs run on Sonnet 5.5 (claude-sonnet-5-5) and HIGH-risk reviews stay on Opus 5.5 (claude-opus-5-5)'
  [ "$(print_flag)" = above_budget ] || return 0
  [ "${1:-}" != scout ] || what='this scout runs on Sonnet 5.5 (claude-sonnet-5-5)'
  printf 'advice: Claude daily budget exceeded (spent %s%% of today'"'"'s %s%% allowance, %s%% left for %s days): %s. Advice only: an explicit captain model choice wins and the profile above is unchanged.\n' \
    "$(state_get spent_today_pct)" "$(state_get day_budget_pct)" "$(state_get remaining_pct)" "$(state_get days_left)" "$what"
}

END_ARG=''
while [ $# -gt 0 ]; do
  case "$1" in
    --flag) print_flag; exit 0 ;;
    --advice) print_advice "${2:-}"; exit 0 ;;
    --end)
      [ $# -ge 2 ] || die "--end needs a value"
      END_ARG=$2
      shift 2
      ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"

END=$END_ARG
[ -n "$END" ] || END=${FM_CLAUDE_BUDGET_END:-}
if [ -z "$END" ] && [ -f "$CONFIG/claude-budget-end" ]; then
  END=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$CONFIG/claude-budget-end" | sed -n '/./{p;q;}')
fi
[ -n "$END" ] || END=$DEFAULT_END
printf '%s' "$END" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ||
  die "end date '$END' is not YYYY-MM-DDTHH:MM:SSZ"
END_EPOCH=$(jq -nr --arg e "$END" '$e | fromdateiso8601' 2>/dev/null) || die "end date '$END' is not a real date"

NOW=$(now_epoch)
TODAY=$(jq -nr --argjson n "$NOW" '$n | todate | .[0:10]')

# The Claude all_models remaining percent, or empty when quota-axi is missing,
# fails, or does not know it (a stale or rate-limited read has no number).
read_remaining() {
  local json
  command -v quota-axi >/dev/null 2>&1 || return 0
  json=$(quota-axi --json 2>/dev/null </dev/null) || return 0
  printf '%s' "$json" | jq -r '
    [.providers[]? | select(.provider == "claude")
     | .quotaSemantics.effectiveAvailability[]?
     | select(.scope == "all_models" and .status == "known")
     | .effectivePercentRemaining
     | select(type == "number")] | first // empty' 2>/dev/null
}

write_state() {  # key=value lines on stdin
  local tmp
  mkdir -p "$STATE" || die "cannot create $STATE"
  tmp=$(mktemp "$STATE/.claude-budget.XXXXXX") || die "cannot write $STATE"
  if ! { cat > "$tmp" && mv "$tmp" "$STATE_FILE"; }; then
    rm -f "$tmp"
    die "cannot write $STATE_FILE"
  fi
}

prev_above=$(state_get above_budget)
[ "$prev_above" = 1 ] || prev_above=0
REMAINING=$(read_remaining)

if [ -z "$REMAINING" ]; then
  # Keep the last computed record (and its computed_epoch, so --flag still ages
  # out) and only note the failed attempt.
  {
    printf 'schema=fm-claude-budget.v1\nstatus=no-quota\nattempt_epoch=%s\n' "$NOW"
    if [ -f "$STATE_FILE" ]; then
      sed -e '/^schema=/d' -e '/^status=/d' -e '/^attempt_epoch=/d' "$STATE_FILE"
    else
      printf 'end=%s\nabove_budget=0\n' "$END"
    fi
  } | write_state
  echo "claude-budget: no readable Claude quota; kept above_budget=$prev_above"
  exit 0
fi

DAYS=$(awk -v e="$END_EPOCH" -v n="$NOW" 'BEGIN { d = (e - n) / 86400; if (d < 0) d = 0; printf "%.4f", d }')
if awk -v d="$DAYS" 'BEGIN { exit(d > 0 ? 1 : 0) }'; then
  write_state <<EOF
schema=fm-claude-budget.v1
status=end-passed
computed_epoch=$NOW
end=$END
remaining_pct=$REMAINING
above_budget=0
EOF
  echo "claude-budget: the end date $END has passed; no budget to enforce"
  exit 0
fi

# Allowance baseline: fixed at the first run of the UTC day.
BASE_DAY=$(state_get day)
BASE_REMAINING=$(state_get day_start_remaining_pct)
BASE_DAYS=$(state_get day_start_days_left)
if [ "$BASE_DAY" != "$TODAY" ] || [ -z "$BASE_REMAINING" ] || [ -z "$BASE_DAYS" ]; then
  BASE_DAY=$TODAY
  BASE_REMAINING=$REMAINING
  BASE_DAYS=$DAYS
fi

read -r BUDGET DAY_BUDGET SPENT ABOVE <<EOF
$(awk -v r="$REMAINING" -v d="$DAYS" -v br="$BASE_REMAINING" -v bd="$BASE_DAYS" 'BEGIN {
  budget = r / d
  day_budget = (bd > 0) ? br / bd : budget
  spent = br - r; if (spent < 0) spent = 0
  printf "%.2f %.2f %.2f %d\n", budget, day_budget, spent, (spent > day_budget) ? 1 : 0
}')
EOF

write_state <<EOF
schema=fm-claude-budget.v1
status=ok
computed_epoch=$NOW
end=$END
remaining_pct=$REMAINING
days_left=$DAYS
budget_pct_per_day=$BUDGET
day=$BASE_DAY
day_start_remaining_pct=$BASE_REMAINING
day_start_days_left=$BASE_DAYS
day_budget_pct=$DAY_BUDGET
spent_today_pct=$SPENT
above_budget=$ABOVE
EOF
mkdir -p "$DATA" 2>/dev/null &&
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$NOW" "$REMAINING" "$DAYS" "$BUDGET" "$SPENT" "$ABOVE" >> "$LOG_FILE" 2>/dev/null || true
echo "claude-budget: remaining=${REMAINING}% days_left=$DAYS budget=${BUDGET}%/day today_allowance=${DAY_BUDGET}% spent_today=${SPENT}% above_budget=$ABOVE"
