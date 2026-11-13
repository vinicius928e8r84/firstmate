#!/usr/bin/env bash
# fm-self-budget.sh - keep the fleet's work on its own repository under a share
# of the week, from measured token usage. No model.
#
# Usage:
#   fm-self-budget.sh measure            read the last 7 days of session transcripts and
#                                        write state/self-work-budget.json
#   fm-self-budget.sh report             one line: the measured share against the ceiling
#   fm-self-budget.sh admit --project <dir> [--scheduled]
#                                        bin/fm-spawn.sh's check before a fresh ship or scout
#
# It reads config/self-work-budget (docs/configuration.md "Self-work budget" owns
# the format). With the file absent every command exits 0 and writes nothing.
#
# Self-work is a session whose working directory is a copy of this repository
# other than a home: a path with a component named like the code root (the
# `repo` key, default the code root's directory name) that is neither this home
# nor a directory holding a .fm-secondmate-home marker. The primary's own turns
# and the secondmates' are therefore not self-work; a worker or scout launched on
# this repository is.
#
# Weight is tokens by relative price: input 1, cache write 2 (1.25 for the
# 5-minute tier when the transcript splits it), cache read 0.1, output 5. Each
# response counts once, by its message id, at the hour of its timestamp.
# Transcripts are Claude Code session files (*.jsonl, one directory per working
# directory) under FM_SELF_BUDGET_SESSIONS, a colon-separated list that defaults
# to ~/.claude/projects; sessions of other harnesses are not measured.
#
# The share is self-work weight over the week's quota when the `week-weight` key
# gives that quota in the same unit, else over everything measured in the window.
#
# measure keeps one cache file per transcript under state/.self-work-budget/,
# reused while the transcript's size and modification time are unchanged, so only
# transcripts that grew are read again. One measure runs at a time.
#
# admit prints nothing and exits 0 when the project is not this repository or
# the share is under the ceiling. Over the ceiling it prints the reason and exits
# 75 in `mode defer`, or exits 0 with a `note:` line in `mode report` and for a
# --scheduled spawn (the captain's recurring loops are counted, never held). A
# missing or stale measurement admits with a `note:` line and starts one measure
# in the background, because a budget that cannot be read is not a reason to
# stop work.
#
# Exit: 0 ok or admitted, 1 config error (a reason on stderr), 2 usage, 75 deferred.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE as in the other bin/
# scripts; FM_SELF_BUDGET_SESSIONS (above); FM_SELF_BUDGET_NOW (epoch, tests);
# FM_SELF_BUDGET_NO_BACKGROUND=1 (admit never starts a measure, tests).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/self-work-budget"
DOC="$STATE/self-work-budget.json"
CACHE="$STATE/.self-work-budget"
WINDOW_S=604800
DEFER_EXIT=75
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"

usage() {
  echo "usage: fm-self-budget.sh measure | report | admit --project <dir> [--scheduled]" >&2
  exit 2
}

now_epoch() {
  case "${FM_SELF_BUDGET_NOW:-}" in '' | *[!0-9]*) date +%s ;; *) printf '%s\n' "$FM_SELF_BUDGET_NOW" ;; esac
}

is_uint() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac; }

# Sets PERCENT, MODE, WEEK_WEIGHT, MAX_AGE, REPO. rc 1 with the line named when
# the file is malformed: the captain's ceiling is never guessed.
read_config() {
  local line key value extra lineno=0 seen=' '
  PERCENT='' MODE=report WEEK_WEIGHT='' MAX_AGE=7200 REPO=$(basename "$FM_ROOT")
  [ -r "$CONFIG_FILE" ] || { echo "error: $CONFIG_FILE exists but cannot be read" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%#*}
    read -r key value extra <<< "$line" || true
    [ -n "$key" ] || continue
    if [ -n "$extra" ] || [ -z "$value" ]; then
      echo "error: $CONFIG_FILE line $lineno: '$key' takes one value" >&2
      return 1
    fi
    case "$seen" in *" $key "*) echo "error: $CONFIG_FILE line $lineno: '$key' is repeated" >&2; return 1 ;; esac
    seen="$seen$key "
    case "$key" in
      percent)
        is_uint "$value" && [ "$value" -ge 1 ] && [ "$value" -le 100 ] ||
          { echo "error: $CONFIG_FILE line $lineno: percent needs a whole number from 1 to 100" >&2; return 1; }
        PERCENT=$value
        ;;
      mode)
        case "$value" in report | defer) MODE=$value ;; *) echo "error: $CONFIG_FILE line $lineno: mode is report or defer" >&2; return 1 ;; esac
        ;;
      week-weight)
        is_uint "$value" && [ "$value" -ge 1 ] ||
          { echo "error: $CONFIG_FILE line $lineno: week-weight needs a positive whole number" >&2; return 1; }
        WEEK_WEIGHT=$value
        ;;
      max-age)
        is_uint "$value" && [ "$value" -ge 60 ] ||
          { echo "error: $CONFIG_FILE line $lineno: max-age needs at least 60 seconds" >&2; return 1; }
        MAX_AGE=$value
        ;;
      repo)
        case "$value" in */* | .*) echo "error: $CONFIG_FILE line $lineno: repo is one directory name" >&2; return 1 ;; esac
        REPO=$value
        ;;
      *)
        echo "error: $CONFIG_FILE line $lineno: unknown key '$key'" >&2
        return 1
        ;;
    esac
  done < "$CONFIG_FILE"
  [ -n "$PERCENT" ] || { echo "error: $CONFIG_FILE names no percent" >&2; return 1; }
}

# One transcript -> "<epoch-hour> <weight> <cwd>" lines, tab-separated, one per
# hour and working directory. A response repeats on several lines of a
# transcript with the same id; the last one carries its final usage.
scan_transcript() {  # <file>
  grep -F '"usage"' "$1" 2>/dev/null | jq -r '
    select(.type == "assistant" and (.message.usage | type) == "object" and (.message.id | type) == "string"
           and (.timestamp | type) == "string" and (.cwd | type) == "string")
    | .message.usage as $u
    | (($u.cache_creation.ephemeral_1h_input_tokens // null)) as $w1
    | (($u.cache_creation.ephemeral_5m_input_tokens // null)) as $w5
    | (if $w1 != null or $w5 != null then (($w1 // 0) * 2 + ($w5 // 0) * 1.25)
       else (($u.cache_creation_input_tokens // 0) * 2) end) as $write
    | (($u.input_tokens // 0) + $write + ($u.cache_read_input_tokens // 0) * 0.1 + ($u.output_tokens // 0) * 5) as $weight
    | select($weight > 0)
    | [.message.id, ((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) / 3600 | floor), $weight, .cwd]
    | @tsv' 2>/dev/null |
    awk -F'\t' '
      { hour[$1] = $2; weight[$1] = $3; cwd[$1] = $4 }
      END { for (id in hour) sum[hour[id] "\t" cwd[id]] += weight[id]
            for (k in sum) { split(k, p, "\t"); printf "%s\t%.0f\t%s\n", p[1], sum[k], p[2] } }'
}

# A working directory is self-work when the copy of this repository it sits in
# (the path up to its first component named $REPO) is not a home.
is_self_work() {  # <cwd>
  local copy home_real copy_real
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1/" in */"$REPO"/*) ;; *) return 1 ;; esac
  copy=${1%%/"$REPO"/*}
  [ "$copy" != "$1" ] || copy=${1%/"$REPO"}
  copy="$copy/$REPO"
  home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || home_real=$FM_HOME
  copy_real=$(cd "$copy" 2>/dev/null && pwd -P) || copy_real=$copy
  [ "$copy_real" != "$home_real" ] || return 1
  [ ! -e "$copy/.fm-secondmate-home" ] || return 1
  return 0
}

cmd_measure() {
  local now start_hour dirs dir f key size mtime head rows tmp files=0 self=0 total=0 lock
  command -v jq >/dev/null 2>&1 || { echo "error: fm-self-budget.sh measure needs jq" >&2; return 1; }
  mkdir -p "$CACHE" || { echo "error: cannot create $CACHE" >&2; return 1; }
  lock="$CACHE/.measuring"
  if ! mkdir "$lock" 2>/dev/null; then
    # A lock older than an hour is a measure that died.
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null || true
      mkdir "$lock" 2>/dev/null || { echo "measure already running" >&2; return 0; }
    else
      echo "measure already running" >&2
      return 0
    fi
  fi
  # shellcheck disable=SC2064 # the lock path is fixed now.
  trap "rmdir '$lock' 2>/dev/null || true" EXIT
  now=$(now_epoch)
  start_hour=$(((now - WINDOW_S) / 3600))
  rows="$CACHE/.rows.$$"
  : > "$rows"
  dirs=${FM_SELF_BUDGET_SESSIONS:-$HOME/.claude/projects}
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      files=$((files + 1))
      key="$CACHE/$(basename "$f" .jsonl).$(printf '%s' "$f" | cksum | awk '{ print $1 }').tsv"
      size=$(wc -c < "$f" | tr -d ' ')
      mtime=$(find "$f" -maxdepth 0 -printf '%T@\n' 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
      head="# $size $mtime"
      if [ ! -f "$key" ] || [ "$(sed -n 1p "$key")" != "$head" ]; then
        tmp="$key.tmp.$$"
        { printf '%s\n' "$head"; scan_transcript "$f"; } > "$tmp" && mv "$tmp" "$key"
      else
        touch "$key"
      fi
      sed 1d "$key" >> "$rows"
    done < <(find "$dir" -name '*.jsonl' -type f -mmin "-$((WINDOW_S / 60))" 2>/dev/null)
  done < <(printf '%s\n' "$dirs" | tr ':' '\n')
  find "$CACHE" -name '*.tsv' -type f -mmin "+$((WINDOW_S / 60 + 1440))" -delete 2>/dev/null || true

  local weight cwd per_cwd="$CACHE/.per-cwd.$$" top
  awk -F'\t' -v start="$start_hour" '$1 >= start { sum[$3] += $2 } END { for (c in sum) printf "%.0f\t%s\n", sum[c], c }' "$rows" > "$per_cwd"
  : > "$rows"
  while IFS=$'\t' read -r weight cwd; do
    [ -n "$cwd" ] || continue
    total=$((total + weight))
    if is_self_work "$cwd"; then
      self=$((self + weight))
      printf '%s\t%s\n' "$weight" "$cwd" >> "$rows"
    fi
  done < "$per_cwd"
  top=$(sort -t "$(printf '\t')" -k1,1nr "$rows" | head -5 |
    jq -Rn '[inputs | split("\t") | {weight: (.[0] | tonumber), cwd: .[1]}]')
  rm -f "$rows" "$per_cwd"
  tmp="$DOC.tmp.$$"
  if ! jq -n --argjson now "$now" --argjson window "$WINDOW_S" --argjson self "$self" --argjson total "$total" \
    --argjson files "$files" --arg repo "$REPO" --argjson top "${top:-[]}" \
    '{schema: "fm-self-work-budget.v1", generated_epoch: $now, window_s: $window, repo: $repo,
      self_weight: $self, total_weight: $total, transcripts: $files, top: $top}' > "$tmp" ||
    ! mv "$tmp" "$DOC"; then
    rm -f "$tmp"
    echo "error: could not write $DOC" >&2
    return 1
  fi
  printf 'measured: self=%s total=%s transcripts=%s\n' "$self" "$total" "$files"
}

# Sets SHARE (whole percent, rounded down), BASIS, SELF_W, DENOM, AGE. rc 1 with
# WHY set when there is no usable measurement.
read_measurement() {
  local now gen
  WHY='' SHARE='' BASIS=usage SELF_W='' DENOM='' AGE=''
  [ -f "$DOC" ] || { WHY="no measurement yet"; return 1; }
  command -v jq >/dev/null 2>&1 || { WHY="jq is missing"; return 1; }
  read -r gen SELF_W DENOM < <(jq -r 'select(.schema == "fm-self-work-budget.v1")
    | [.generated_epoch, .self_weight, .total_weight] | map(floor) | @tsv' "$DOC" 2>/dev/null | tr '\t' ' ') || true
  if ! is_uint "${gen:-}" || ! is_uint "${SELF_W:-}" || ! is_uint "${DENOM:-}"; then
    WHY="the measurement is unreadable"
    return 1
  fi
  now=$(now_epoch)
  AGE=$((now - gen))
  [ "$AGE" -le "$MAX_AGE" ] || { WHY="the measurement is ${AGE}s old (max-age $MAX_AGE)"; return 1; }
  if [ -n "$WEEK_WEIGHT" ]; then
    DENOM=$WEEK_WEIGHT
    BASIS=quota
  fi
  if [ "$DENOM" -gt 0 ]; then SHARE=$((SELF_W * 100 / DENOM)); else SHARE=0; fi
}

start_background_measure() {
  [ "${FM_SELF_BUDGET_NO_BACKGROUND:-0}" != 1 ] || return 0
  (nice -n 19 "$SCRIPT_DIR/fm-self-budget.sh" measure > /dev/null 2>&1 &) 2>/dev/null || true
}

cmd_report() {
  if read_measurement; then
    printf 'self-work: share=%s%% ceiling=%s%% basis=%s self=%s of=%s age=%ss mode=%s\n' \
      "$SHARE" "$PERCENT" "$BASIS" "$SELF_W" "$DENOM" "$AGE" "$MODE"
  else
    printf 'self-work: share=unknown ceiling=%s%% mode=%s (%s)\n' "$PERCENT" "$MODE" "$WHY"
  fi
}

cmd_admit() {
  local project='' scheduled=0 rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) [ $# -ge 2 ] || usage; project=$2; shift ;;
      --scheduled) scheduled=1 ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$project" ] || usage
  fm_role_self_repo "$project" "$FM_ROOT" || rc=$?
  [ "$rc" -eq 0 ] || return 0
  if ! read_measurement; then
    start_background_measure
    echo "note: self-work budget not applied: $WHY (config/self-work-budget); admitted"
    return 0
  fi
  [ "$SHARE" -ge "$PERCENT" ] || return 0
  if [ "$MODE" = report ]; then
    echo "note: work on this repository is at ${SHARE}% of the week's $BASIS, over the ${PERCENT}% ceiling (config/self-work-budget, mode report); admitted"
    return 0
  fi
  if [ "$scheduled" -eq 1 ]; then
    echo "note: work on this repository is at ${SHARE}% of the week's $BASIS, over the ${PERCENT}% ceiling (config/self-work-budget); a scheduled loop is admitted"
    return 0
  fi
  echo "work on this repository is at ${SHARE}% of the week's $BASIS, at or over the ${PERCENT}% ceiling in config/self-work-budget"
  return "$DEFER_EXIT"
}

CMD=${1:-}
shift 2>/dev/null || true
case "$CMD" in measure | report | admit) ;; *) usage ;; esac
[ -e "$CONFIG_FILE" ] || exit 0
read_config || exit 1
case "$CMD" in
  measure) [ $# -eq 0 ] || usage; cmd_measure ;;
  report) [ $# -eq 0 ] || usage; cmd_report ;;
  admit) cmd_admit "$@" ;;
esac
