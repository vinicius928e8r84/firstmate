#!/usr/bin/env bash
# fm-silent-watcher.sh - out-of-band "silent watcher" alarm (audit 2026-10-23, improvement 2).
# Cron every 5 min. Pure shell: no model call, no token spend, never wakes the captain or any agent.
# Unhealthy when ANY of:
#   missing  - no live $FM_HOME/bin/fm-watch.sh process
#   stale    - state/.last-watcher-beat older than FM_SW_BEAT_MAX (default 900 s = 3x the 300 s guard grace)
#   queue    - state/.wake-queue has lines and the oldest is older than FM_SW_QUEUE_MAX (default 900 s)
#              (skipped while state/HOLD is in force: a held fleet is supposed to be quiet)
# Alert: one per incident (debounced by state/.silent-watcher.incident). The alert is appended to
#   state/.silent-watcher-alerts (outbox, one line per incident) and registered as a captain ask with
#   bin/../data/tools/fm-asks.sh add --key silent-watcher (deterministic; the ask shows in the owner's
#   pending list and in fm-asks diff). Recovery clears the incident and closes the ask.
# No self-heal: re-arming the watcher belongs to the captain's session (fm-watch-arm.sh is session-bound).
# Env: FM_HOME, FM_SW_NOW (epoch, tests), FM_SW_PGREP (command, tests), FM_SW_ASKS (fm-asks path, tests).
# Exit: 0 healthy, 1 unhealthy (alerted or already alerted).
set -uo pipefail
F=${FM_HOME:-/home/factory/firstmate}; S=$F/state
NOW=${FM_SW_NOW:-$(date +%s)}
BEAT_MAX=${FM_SW_BEAT_MAX:-900}; QUEUE_MAX=${FM_SW_QUEUE_MAX:-900}
ASKS=${FM_SW_ASKS:-$F/data/tools/fm-asks.sh}
INC=$S/.silent-watcher.incident; OUT=$S/.silent-watcher-alerts; LOG=$S/.silent-watcher.log
exec 9>"$S/.silent-watcher.lock"; flock -n 9 || exit 0
log() { echo "$(date -u -d "@$NOW" +%FT%TZ) $*" >> "$LOG"; }
notify() { local u k; u=$(cat "$HOME/.config/fm/watcher-webhook.url" 2>/dev/null); k=$(cat "$HOME/.config/fm/watcher-webhook.key" 2>/dev/null); { [ -n "$u" ] && [ -n "$k" ] && [ -z "${FM_SW_NO_NOTIFY:-}" ]; } || return 0; local m; m=$(printf %s "$2" | tr -d '"\\'); timeout 20 curl -fsS -X POST "$u" -H "Authorization: Bearer $k" -H "Content-Type: application/json" --data "{\"event\":\"$1\",\"message\":\"$m\"}" >/dev/null 2>&1 || log "notify failed"; }
reasons=()
if [ -n "${FM_SW_PGREP:-}" ]; then pids=$($FM_SW_PGREP); else pids=$(pgrep -f "^bash $F/bin/fm-watch.sh\$" || true); fi
[ -n "$pids" ] || reasons+=("missing: no fm-watch.sh process")
if [ -e "$S/.last-watcher-beat" ]; then
  age=$(( NOW - $(stat -c %Y "$S/.last-watcher-beat") ))
  [ "$age" -le "$BEAT_MAX" ] || reasons+=("stale: watcher beat ${age}s old (max ${BEAT_MAX}s)")
else reasons+=("stale: no state/.last-watcher-beat"); fi
if [ ! -e "$S/HOLD" ] && [ -s "$S/.wake-queue" ]; then
  oldest=$(awk -F'\t' '$1 ~ /^[0-9]+$/ {print $1}' "$S/.wake-queue" | sort -n | head -1)
  if [ -n "$oldest" ]; then
    qa=$(( NOW - oldest )); n=$(grep -c . "$S/.wake-queue")
    [ "$qa" -le "$QUEUE_MAX" ] || reasons+=("queue: $n undelivered wake(s), oldest ${qa}s (max ${QUEUE_MAX}s)")
  fi
fi
if [ ${#reasons[@]} -eq 0 ]; then
  if [ -e "$INC" ]; then
    log "recovered (incident $(head -1 "$INC"))"; rm -f "$INC"; notify recovered "Vigia do captain voltou ao normal."
    [ -x "$ASKS" ] && FM_HOME=$F "$ASKS" done silent-watcher >/dev/null 2>&1
  fi
  exit 0
fi
msg="Vigia do captain mudo ($(IFS='; '; echo "${reasons[*]}")) desde $(date -u -d "@$NOW" +%FT%TZ). Religar: bin/fm-watch-arm.sh --restart na sessão do captain."
if [ -e "$INC" ]; then exit 1; fi
echo "$NOW" > "$INC"
printf '%s\t%s\n' "$NOW" "$msg" >> "$OUT"
log "ALERT $msg"; notify alert "$msg"
[ -x "$ASKS" ] && FM_HOME=$F "$ASKS" add --key silent-watcher "$msg" >/dev/null 2>&1
exit 1
