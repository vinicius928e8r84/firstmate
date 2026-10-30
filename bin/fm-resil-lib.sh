#!/usr/bin/env bash
# fm-resil-lib.sh - shared pieces of the resilience loops (automatic retry at spawn and send,
# relaunch of a stopped worker, finished-lane close, the captain's single page).
#
# Source it; it has no side effects on source.
#   fm_resil_log <state-dir> <task> <cause> <action> <outcome>
#       append one line to <state-dir>/.resil.log:
#         <UTC time> task=<task> cause=<cause> action=<action> outcome=<outcome>
#       so "what did the loops do" is a grep. Best effort: never fails the caller.
#   fm_resil_schedule_delay <schedule> <n>
#       the n-th (1-based) space-separated delay of a schedule, empty past its end.
#   fm_resil_off <config-dir>
#       true (0) when the loops are switched off: FM_RESIL=0 or a config/resil-off file.
#   fm_resil_card_put <state-dir> <key> <owner> <summary>
#   fm_resil_card_drop <state-dir> <key>
#       a card is one thing waiting for the captain that has no backlog hold of its own (a permanent
#       spawn error, a worker that stayed stopped). It lives in <state-dir>/resil/cards/<key>.card and
#       bin/fm-daily-page.sh puts it on the captain's page; the loop that wrote it drops it when the cause
#       clears. A key is [A-Za-z0-9._-]+.
#   fm_resil_resend_save <state-dir> <corr> <home> <state-override-or-empty> <steer argument>...
#   fm_resil_resend_clear <state-dir> <corr>
#       the steer script saves the exact arguments of an unconfirmed secondmate steer under
#       <state-dir>/resil/resend/<corr>.args (NUL separated: home, state override, arguments) so that
#       bin/fm-resil.sh resend can replay the printed correlation-reusing command; a confirmed delivery clears it.
#   fm_resil_pr_state <pr-url>
#       prints merged, closed, open or unknown for a GitHub PR url and exits 0 only when it is merged; the one
#       reader shared by the finished-lane closer and the captain page's ghost closer.
# Switch-off and schedules are documented once, in docs/configuration.md "Resilience loops".

FM_RESIL_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fm_resil_log() {  # <state-dir> <task> <cause> <action> <outcome>
  local dir=${1:-} task=${2:-} cause=${3:-} action=${4:-} outcome=${5:-}
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  cause=${cause//$'\n'/ }; outcome=${outcome//$'\n'/ }
  printf '%s task=%s cause=%s action=%s outcome=%s\n' "$(date -u +%FT%TZ)" "${task:--}" "${cause:--}" "${action:--}" "${outcome:--}" \
    >> "$dir/.resil.log" 2>/dev/null || true
  return 0
}

fm_resil_schedule_delay() {  # <schedule> <n>
  local -a items
  read -r -a items <<<"${1:-}"
  printf '%s' "${items[$((${2:-1} - 1))]:-}"
}

fm_resil_off() {  # <config-dir>
  [ "${FM_RESIL:-1}" = 0 ] || [ -e "${1:-/nonexistent}/resil-off" ]
}

fm_resil_card_put() {  # <state-dir> <key> <owner> <summary>
  local dir=${1:-}/resil/cards key=${2:-} owner=${3:-} summary=${4:-}
  [[ $key =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  mkdir -p "$dir" || return 1
  [ -e "$dir/$key.card" ] && return 0
  summary=${summary//$'\n'/ }
  printf 'key=%s\nowner=%s\nat=%s\nsummary=%s\n' "$key" "$owner" "$(date +%s)" "$summary" > "$dir/.$key.tmp.$$" &&
    mv -f "$dir/.$key.tmp.$$" "$dir/$key.card"
}

fm_resil_card_drop() {  # <state-dir> <key>
  [[ ${2:-} =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  rm -f "${1:-}/resil/cards/$2.card" 2>/dev/null
  return 0
}

fm_resil_resend_save() {  # <state-dir> <corr> <home> <state-override> <arg>...
  local dir=${1:-}/resil/resend corr=${2:-}
  shift 2
  [[ $corr =~ ^[A-Fa-f0-9]{16}$ ]] || return 1
  mkdir -p "$dir" || return 1
  [ -e "$dir/$corr.args" ] && return 0   # a repeated failure keeps its attempt count
  printf '%s\0' "$@" > "$dir/.$corr.tmp.$$" && mv -f "$dir/.$corr.tmp.$$" "$dir/$corr.args" &&
    printf '0 %s\n' "$(date +%s)" > "$dir/$corr.tries"
}

fm_resil_resend_clear() {  # <state-dir> <corr>
  [[ ${2:-} =~ ^[A-Fa-f0-9]{16}$ ]] || return 0
  rm -f "${1:-}/resil/resend/$2.args" "${1:-}/resil/resend/$2.tries" 2>/dev/null
  fm_resil_card_drop "${1:-}" "send-$2"
}

fm_resil_pr_state() {  # <pr-url>
  local out rc
  # shellcheck disable=SC2016  # expands inside the child bash
  out=$(timeout 20 bash -c '
    . "$1"
    fm_pr_url_parse "$2" && [ "$FM_PR_PROVIDER" = github ] || { echo unknown; exit 1; }
    owner=${FM_PR_PATH%%/*}; repo=${FM_PR_PATH#*/}
    fm_pr_github_read_record "$owner" "$repo" "$FM_PR_NUMBER" || { echo unknown; exit 1; }
    [ "$FM_PR_RECORD_MERGED" = true ] && { echo merged; exit 0; }
    echo "$FM_PR_RECORD_STATE" | tr "[:upper:]" "[:lower:]"; exit 1
  ' _ "$FM_RESIL_LIB_DIR/fm-pr-lib.sh" "$1" 2>/dev/null); rc=$?
  printf '%s\n' "${out:-unknown}" | head -n1
  return "$rc"
}
