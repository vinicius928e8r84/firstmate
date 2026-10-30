#!/usr/bin/env bash
# fm-resil.sh - the resilience loops that need a clock: replay of an unconfirmed secondmate steer. The watcher runs `tick` detached; every
# action is one line in state/.resil.log (when, task, cause, action, outcome), so the effect is a grep away.
#
# Usage: fm-resil.sh resend            replay unconfirmed secondmate steers
#        fm-resil.sh tick              every loop, each on its own interval, under one lock
#        fm-resil.sh card-close <key>  drop a card (bin/fm-resil-lib.sh) that the captain answered
#
# resend  bin/fm-send.sh saves the exact arguments of a remote secondmate steer whose delivery stayed unknown
#         (state/resil/resend/<corr>.args). Here, while the pending-reply record is still undelivered, the same
#         command that fm-send printed - FM_PENDING_REPLY_EXISTING_CORR=<corr> fm-send.sh <arguments>, which the
#         remote inbox deduplicates onto the record that may have landed - runs again 1, 4 and 15 minutes after the
#         previous try (FM_RESIL_RESEND_SCHEDULE="60 240 900"). A delivered, resolved or missing record ends it.
#         After the last try one card (key send-<corr>) goes on the captain's page; the watcher's own escalation of
#         the unknown delivery stays as it is.
# The loops are off with FM_RESIL=0 or a config/resil-off file. Test seams: FM_RESIL_NOW (epoch),
# FM_RESIL_SEND_CMD. Exit (also when a step could not act), 64 usage.
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
}

case "${1:-}" in
  resend) fm_resil_off "$CONFIG" || do_resend ;;
  tick) do_tick ;;
  card-close) [ -n "${2:-}" ] || { echo "usage: fm-resil.sh card-close <key>" >&2; exit 64; }; fm_resil_card_drop "$STATE" "$2" ;;
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" ;;
  *) echo "usage: fm-resil.sh resend|tick|card-close <key>" >&2; exit 64 ;;
esac
exit 0
