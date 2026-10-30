#!/usr/bin/env bash
# fm-resil.sh - the resilience loops that need a clock: replay of an unconfirmed secondmate steer and automatic
# relaunch of a stopped worker. The watcher runs `tick` detached; every
# action is one line in state/.resil.log (when, task, cause, action, outcome), so the effect is a grep away.
#
# Usage: fm-resil.sh resend            replay unconfirmed secondmate steers
#        fm-resil.sh relaunch          relaunch workers that stopped
#        fm-resil.sh tick              both, each on its own interval, under one lock
#        fm-resil.sh card-close <key>  drop a card (bin/fm-resil-lib.sh) that the captain answered
#
# resend  bin/fm-send.sh saves the exact arguments of a remote secondmate steer whose delivery stayed unknown
#         (state/resil/resend/<corr>.args). Here, while the pending-reply record is still undelivered, the same
#         command that fm-send printed - FM_PENDING_REPLY_EXISTING_CORR=<corr> fm-send.sh <arguments>, which the
#         remote inbox deduplicates onto the record that may have landed - runs again 1, 4 and 15 minutes after the
#         previous try (FM_RESIL_RESEND_SCHEDULE="60 240 900"). A delivered, resolved or missing record ends it.
#         After the last try one card (key send-<corr>) goes on the captain's page; the watcher's own escalation of
#         the unknown delivery stays as it is.
# relaunch  A worker is STOPPED when all of these hold: it is a local ship or scout (never a secondmate, which has
#         its own loop); its newest status event is neither done, failed, paused, needs-decision nor blocked and
#         it has no open decision; the pane does not read busy; and there is proof it stopped - its agent process is
#         gone (the crew-state read says the agent or its target is gone) or the last record of its Claude session
#         ends in an API error. Once it has been stopped for FM_RESIL_STOPPED_SECS (600) it is relaunched through
#         the normal verified path, bin/fm-control.sh <id> relaunch --note ..., which deletes nothing, up to four
#         times, 2, 4, 8 and 16 minutes after the previous point (FM_RESIL_RELAUNCH_SCHEDULE="120 240 480 960");
#         when the last wait passes with the worker still stopped one card (key stopped-<id>) goes on the page.
#         A worker seen not stopped for 30 minutes starts over. state/HOLD pauses the loop without counting.
# Both are off with FM_RESIL=0 or a config/resil-off file. Test seams: FM_RESIL_NOW (epoch),
# FM_RESIL_SEND_CMD, FM_RESIL_CONTROL_CMD <id> relaunch --note <text>, FM_RESIL_CREW_STATE_CMD <id>,
# FM_RESIL_APIERR_CMD <worktree> (exit 0 and print the error time when the session ended in an API error),
# Exit: 0 (also when a step could not act), 64 usage.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$HERE/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME
# shellcheck source=bin/fm-resil-lib.sh
. "$HERE/fm-resil-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$HERE/fm-classify-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$HERE/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$HERE/fm-wake-lib.sh"

now() { echo "${FM_RESIL_NOW:-$(date +%s)}"; }
log() { fm_resil_log "$STATE" "$@"; }
meta_value() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
rec_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
rec_set() {  # <file> <key> <value>
  local f=$1 k=$2 v=$3
  { grep -v "^$k=" "$f" 2>/dev/null; printf '%s=%s\n' "$k" "$v"; } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# ------------------------------------------------------------------ resend
do_resend() {
  local dir=$STATE/resil/resend args corr rec phase delivered tries last n delay a send_cmd rc out sched n_sched
  local -a argv
  [ -d "$dir" ] || return 0
  sched=${FM_RESIL_RESEND_SCHEDULE-60 240 900}
  read -r -a _s <<<"$sched"; n_sched=${#_s[@]}
  send_cmd=${FM_RESIL_SEND_CMD:-$HERE/fm-send.sh}
  for args in "$dir"/*.args; do
    [ -e "$args" ] || continue
    corr=$(basename "$args" .args)
    rec=$(fm_pending_reply_path "$STATE" "$corr")
    phase=; delivered=
    if [ -f "$rec" ]; then phase=$(fm_pending_reply_get "$rec" phase); delivered=$(fm_pending_reply_get "$rec" delivered_epoch); fi
    if [ ! -f "$rec" ] || [ -n "$delivered" ] || [ "$phase" = resolved ]; then
      fm_resil_resend_clear "$STATE" "$corr"; log "$(fm_pending_reply_get "$rec" task_id)" send-unknown resend-ended "record ${phase:-gone}${delivered:+ delivered}"
      continue
    fi
    case "$phase" in delivery_unknown|escalated) ;; *) continue ;; esac
    read -r n last < "$dir/$corr.tries" 2>/dev/null || { n=0; last=$(now); }
    [[ $n =~ ^[0-9]+$ ]] && [[ $last =~ ^[0-9]+$ ]] || { n=0; last=$(now); }
    if [ "$n" -ge "$n_sched" ]; then
      fm_resil_card_put "$STATE" "send-$corr" "(main)" "O pedido ao secundo $(fm_pending_reply_get "$rec" task_id) segue sem confirmação de entrega depois de $n tentativas automáticas. Reenviar à mão ou deixar como está."
      continue
    fi
    delay=$(fm_resil_schedule_delay "$sched" $((n + 1)))
    [ "$(now)" -ge $((last + delay)) ] || continue
    mapfile -d '' -t argv < "$args" 2>/dev/null || continue
    [ "${#argv[@]}" -ge 3 ] || continue
    # argv = home, state override ('' when none), then the original fm-send arguments
    if [ -n "${argv[1]}" ]; then
      out=$(FM_HOME="${argv[0]}" FM_STATE_OVERRIDE="${argv[1]}" FM_PENDING_REPLY_EXISTING_CORR="$corr" \
        timeout 200 "$send_cmd" "${argv[@]:2}" </dev/null 2>&1); rc=$?
    else
      out=$(FM_HOME="${argv[0]}" FM_PENDING_REPLY_EXISTING_CORR="$corr" \
        timeout 200 "$send_cmd" "${argv[@]:2}" </dev/null 2>&1); rc=$?
    fi
    a=$((n + 1))
    printf '%s %s\n' "$a" "$(now)" > "$dir/$corr.tries"
    if [ "$rc" -eq 0 ]; then
      fm_resil_resend_clear "$STATE" "$corr"
      log "$(fm_pending_reply_get "$rec" task_id)" send-unknown "resend-$a" "delivered"
    else
      log "$(fm_pending_reply_get "$rec" task_id)" send-unknown "resend-$a" "rc=$rc $(printf '%s' "$out" | head -n 1 | cut -c1-120)"
    fi
  done
}

# ------------------------------------------------------------------ relaunch
default_apierr() {  # <worktree> -> 0 and the session's last write time when it ends in an API error
  local wt=$1 dir f
  dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$wt" | sed 's|[^A-Za-z0-9]|-|g')
  f=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -n 1)
  [ -n "$f" ] || return 1
  tail -n 2 "$f" 2>/dev/null | grep -q '"isApiErrorMessage":true' || return 1
  stat -c %Y "$f"
}

# Print "<since-epoch> <why>" and return 0 when lane <id> is stopped; return 1 otherwise.
lane_stopped() {  # <id> <meta>
  local id=$1 meta=$2 sf=$STATE/$id.status cur verb line st src detail wt at cmd
  [ -f "$sf" ] && cur=$(status_current_line "$sf" "$(meta_value "$meta" kind)") || cur=
  status_line_verb "$cur" verb 2>/dev/null || verb=
  case "$verb" in done|failed|needs-decision|blocked|captain-held) return 1 ;; esac
  status_is_paused "$cur" 2>/dev/null && return 1
  [ -z "$(status_open_decisions "$sf" "$(meta_value "$meta" kind)" 2>/dev/null)" ] || return 1
  cmd=${FM_RESIL_CREW_STATE_CMD:-$HERE/fm-crew-state.sh}
  line=$(FM_CREW_STATE_NO_FORGE=1 timeout 40 "$cmd" "$id" 2>/dev/null | head -n 1)
  st=${line#state: }; st=${st%% *}
  src=${line#*source: }; src=${src%% *}
  detail=${line##* · }
  [ "$st" = working ] && [ "$src" != status-log ] && return 1   # busy right now, or a pipeline run owns it
  case "$st" in done|failed|blocked|paused) return 1 ;; esac
  wt=$(meta_value "$meta" worktree)
  case "$detail" in
    *"agent gone"*|*"backend target gone"*) echo "$(now) agent-gone"; return 0 ;;
  esac
  if [ -n "$wt" ]; then
    if [ -n "${FM_RESIL_APIERR_CMD:-}" ]; then at=$("$FM_RESIL_APIERR_CMD" "$wt" 2>/dev/null) || at=
    else at=$(default_apierr "$wt") || at=; fi
    if [ -n "$at" ]; then echo "$at api-error"; return 0; fi
  fi
  return 1
}

do_relaunch() {
  local meta id kind rec since why sched n_sched n last first delay due note ctl out rc a hold
  [ -d "$STATE" ] || return 0
  if fm_hold_active 2>/dev/null; then return 0; fi
  sched=${FM_RESIL_RELAUNCH_SCHEDULE-120 240 480 960}
  read -r -a _s <<<"$sched"; n_sched=${#_s[@]}
  ctl=${FM_RESIL_CONTROL_CMD:-$HERE/fm-control.sh}
  mkdir -p "$STATE/resil/stopped" || return 0
  shopt -s nullglob
  for meta in "$STATE"/*.meta; do
    id=$(basename "$meta" .meta)
    kind=$(meta_value "$meta" kind); [ -n "$kind" ] || kind=ship
    [ "$kind" = secondmate ] && continue
    [ -z "$(meta_value "$meta" remote_host)" ] || continue
    rec=$STATE/resil/stopped/$id
    if ! why=$(lane_stopped "$id" "$meta"); then
      if [ -f "$rec" ]; then   # recovered: start over after a quiet half hour
        [ -n "$(rec_get "$rec" healthy)" ] || rec_set "$rec" healthy "$(now)"
        if [ $(( $(now) - $(rec_get "$rec" healthy) )) -ge "${FM_RESIL_HEALTHY_SECS:-1800}" ]; then
          rm -f "$rec"; fm_resil_card_drop "$STATE" "stopped-$id"; log "$id" stopped recovered "seen working again for ${FM_RESIL_HEALTHY_SECS:-1800}s"
        fi
      fi
      continue
    fi
    since=${why%% *}; why=${why#* }
    if [ ! -f "$rec" ]; then
      printf 'first=%s\nattempts=0\nlast=%s\nwhy=%s\n' "$since" "$(( since + ${FM_RESIL_STOPPED_SECS:-600} ))" "$why" > "$rec" || continue
    fi
    rec_set "$rec" healthy ""
    n=$(rec_get "$rec" attempts); last=$(rec_get "$rec" last); first=$(rec_get "$rec" first)
    [[ $n =~ ^[0-9]+$ ]] && [[ $last =~ ^[0-9]+$ ]] && [[ $first =~ ^[0-9]+$ ]] || { rm -f "$rec"; continue; }
    if [ "$n" -ge "$n_sched" ]; then   # all relaunches used: after the last wait, one card
      delay=$(fm_resil_schedule_delay "$sched" "$n_sched")
      if [ "$(now)" -ge $((last + delay)) ]; then
        fm_resil_card_put "$STATE" "stopped-$id" "(main)" "O worker $id parou ($why) e $n relançamentos automáticos não o puseram de volta a trabalhar. Ver o painel do worker ou dar a tarefa por encerrada."
      fi
      continue
    fi
    delay=$(fm_resil_schedule_delay "$sched" $((n + 1)))
    due=$((last + delay))
    [ "$(now)" -ge "$due" ] || continue
    a=$((n + 1))
    note="Automatic relaunch $a of $n_sched: the agent stopped ($why) about $(( ($(now) - first) / 60 )) minutes ago and did not come back. Continue from the local copy; nothing was removed."
    out=$("$ctl" "$id" relaunch --note "$note" </dev/null 2>&1); rc=$?
    rec_set "$rec" attempts "$a"; rec_set "$rec" last "$(now)"
    if [ "$rc" -eq 0 ]; then log "$id" "stopped-$why" "relaunch-$a" "ok"
    else log "$id" "stopped-$why" "relaunch-$a" "rc=$rc $(printf '%s' "$out" | grep -m1 -E 'error|refus' | cut -c1-140)"; fi
  done
}

# ------------------------------------------------------------------ tick
due_every() {  # <name> <seconds>: true (and stamp) when the step is due
  local stamp=$STATE/resil/.last-$1 last=0
  [ -f "$stamp" ] && last=$(cat "$stamp" 2>/dev/null)
  [[ $last =~ ^[0-9]+$ ]] || last=0
  [ $(( $(now) - last )) -ge "$2" ] || return 1
  now > "$stamp"
}

do_tick() {
  mkdir -p "$STATE/resil" || return 0
  exec 7> "$STATE/resil/.tick.lock"
  flock -n 7 || return 0
  fm_resil_off "$CONFIG" && return 0
  do_resend
  if due_every relaunch "${FM_RESIL_RELAUNCH_INTERVAL:-60}"; then do_relaunch; fi
}

case "${1:-}" in
  resend) fm_resil_off "$CONFIG" || do_resend ;;
  relaunch) fm_resil_off "$CONFIG" || do_relaunch ;;
  tick) do_tick ;;
  card-close) [ -n "${2:-}" ] || { echo "usage: fm-resil.sh card-close <key>" >&2; exit 64; }; fm_resil_card_drop "$STATE" "$2" ;;
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" ;;
  *) echo "usage: fm-resil.sh resend|relaunch|tick|card-close <key>" >&2; exit 64 ;;
esac
exit 0
