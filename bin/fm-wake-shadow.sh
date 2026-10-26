#!/usr/bin/env bash
# Shadow log for check and signal wakes.
#
# A cheaper, non-Claude triage of no-op wakes can only be trusted once its verdict
# is compared with what the orchestrating model actually did on the same wake. This
# log is the input half of that comparison: for every check or signal row a drain
# presents, one line with the wake record, the state a triage would read (newest
# status line, its verb, its age, open decisions, backlog section, task kind), and
# the verdict of a deliberately conservative candidate rule. Nothing reads it to
# decide anything; no wake is suppressed, delayed, or reworded because of it.
#
#   fm-wake-shadow.sh record     tab-separated wake rows on stdin (the drain's raw
#                                rows: epoch seq kind key payload); best-effort,
#                                always exit 0 so a logging problem never fails a drain
#   fm-wake-shadow.sh summary    counts by kind, verb, and candidate verdict
#
# Store: $STATE/wake-shadow.jsonl, one JSON object per line, append-only, rotated
# once to wake-shadow.jsonl.1 when it passes FM_WAKE_SHADOW_MAX_BYTES (4 MiB).
#   {"v":1,"at":N,"wake_at":N,"seq":N,"kind":"signal|check","key":"...","actor":"main|branch",
#    "task":"...","task_kind":"...","payload":"...","status_verb":"...","status_line":"...",
#    "status_age_s":N|null,"open_decisions":N,"backlog":"...","repeat":bool,
#    "rule":"v1","candidate":"noop|deliver"}
# `repeat` marks a row that an earlier drain already logged (an unacknowledged
# wake is presented again), so analysis counts each seq once, at its first line.
# Candidate rule v1 says `noop` only for a signal whose newest status line is a
# working or paused line, with no open decision on that task, no captain-relevant
# text, and a recorded task; everything else, every check included, is `deliver`.
# The rule is a hypothesis to measure, not a policy: a later fit replaces it, and
# the model's own outcome joins on `at` through the transcript attribution.
# Off with FM_WAKE_SHADOW=0.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"

LOG_NAME=wake-shadow.jsonl
MAX_BYTES=${FM_WAKE_SHADOW_MAX_BYTES:-4194304}
case "$MAX_BYTES" in ''|*[!0-9]*) MAX_BYTES=4194304 ;; esac
RULE_VERSION=v1

usage() {
  echo "usage: fm-wake-shadow.sh record < rows | summary" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage

if [ "$1" = summary ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  [ -f "$STATE/$LOG_NAME" ] || { echo "wake shadow: no log yet"; exit 0; }
  jq -r 'select(.repeat == false) | [.kind, (.status_verb // "-"), .candidate] | @tsv' "$STATE/$LOG_NAME" \
    | sort | uniq -c | sort -rn
  exit 0
fi
[ "$1" = record ] || usage

record() {
  [ "${FM_WAKE_SHADOW:-1}" != 0 ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" || return 0
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh" || return 0
  local log="$STATE/$LOG_NAME" now actor data backlog size recent
  now=$(date +%s)
  actor=${FM_SUPERVISION_ACTOR:-main}
  data=${FM_DATA_OVERRIDE:-$FM_HOME/data}
  backlog="$data/backlog.md"
  size=$(stat -c %s "$log" 2>/dev/null || stat -f %z "$log" 2>/dev/null || echo 0)
  if [ "${size:-0}" -gt "$MAX_BYTES" ]; then
    mv -f -- "$log" "$log.1" 2>/dev/null || return 0
  fi
  recent=$(tail -n 400 "$log" 2>/dev/null | jq -r 'select(.seq != null) | .seq' 2>/dev/null)
  local epoch seq kind key payload rest task file line verb age mtime opens section task_kind repeat candidate row
  while IFS=$'\t' read -r epoch seq kind key payload rest; do
    case "$kind" in signal|check) ;; *) continue ;; esac
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    task=''; file=''; line=''; verb=''; age=''; opens=0; section=''; task_kind=''
    if [ "$kind" = signal ]; then
      task=${key%.status}
      file="$STATE/$key"
      line=$(last_status_line "$file" 2>/dev/null)
      verb=$(status_line_verb "$line" 2>/dev/null)
      mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || true)
      [ -n "$mtime" ] && age=$((now - mtime))
      opens=$(status_open_decisions "$file" 2>/dev/null | awk 'NF { n++ } END { print n + 0 }')
      task_kind=$(sed -n 's/^kind=//p' "$STATE/$task.meta" 2>/dev/null | head -n 1)
      if [ -f "$backlog" ]; then
        section=$(awk -v id="$task" '/^## / { s = substr($0, 4) } index($0, "- [") == 1 && index($0, "] " id " - ") { print s; exit }' "$backlog")
      fi
    fi
    repeat=false
    printf '%s\n' "$recent" | grep -qx -- "$seq" && repeat=true
    candidate=deliver
    if [ "$kind" = signal ] && [ -n "$task_kind" ] && [ -n "$line" ] && [ "$opens" -eq 0 ]; then
      case "$verb" in
        working|paused) status_is_captain_relevant "$line" || candidate=noop ;;
      esac
    fi
    row=$(jq -c -n \
      --argjson at "$now" --argjson wake_at "${epoch:-0}" --argjson seq "$seq" \
      --arg kind "$kind" --arg key "$key" --arg actor "$actor" --arg task "$task" --arg task_kind "$task_kind" \
      --arg payload "${payload:0:400}" --arg verb "$verb" --arg line "${line:0:240}" --arg age "$age" \
      --argjson opens "$opens" --arg section "$section" --argjson repeat "$repeat" \
      --arg rule "$RULE_VERSION" --arg candidate "$candidate" \
      '{v:1, at:$at, wake_at:$wake_at, seq:$seq, kind:$kind, key:$key, actor:$actor, task:$task, task_kind:$task_kind,
        payload:$payload, status_verb:$verb, status_line:$line,
        status_age_s:(if $age == "" then null else ($age | tonumber) end),
        open_decisions:$opens, backlog:$section, repeat:$repeat, rule:$rule, candidate:$candidate}') || continue
    # One short line per append: O_APPEND keeps concurrent drains from interleaving.
    printf '%s\n' "$row" >> "$log" 2>/dev/null || return 0
    recent=$(printf '%s\n%s' "$recent" "$seq")
  done
  return 0
}

record
exit 0
