#!/usr/bin/env bash
# fm-webhook-notify-lib.sh - the captain's out-of-band webhook notice, with a fallback that cannot go silent.
# Source it (do not run it) from bin/fm-silent-watcher.sh and bin/fm-lane-guard.sh. The caller defines F (the
# firstmate home), S (its state directory), HERE (bin/) and log(); this file defines fm_webhook_notify.
# fm_webhook_notify <event> <message>
#   Posts {"event","message"} to ~/.config/fm/watcher-webhook.url with the bearer key in watcher-webhook.key. No
#   configuration, or FM_SW_NO_NOTIFY set, is a silent skip (return 0). A reply outside 2xx is a failure and is
#   logged as "notify failed http=<code> <short reply>" with every uuid and the key masked.
#   The audit of 2026-11-09 found 199 failures in 199 tries over three days with nobody told, so a failure streak is
#   handled here: after FM_NOTIFY_FAIL_MAX (3) consecutive failures the channel counts as degraded, ONE inbox note is
#   queued for firstmate through bin/fm-inbox.sh (a durable `check` wake) naming the status, and from then on every
#   non-recovery notice is also queued as an inbox note, at most one per FM_NOTIFY_FALLBACK_GAP seconds (3600).
#   The webhook is still tried every time; the first success clears the streak and the degraded mark.
# State (in $S): .webhook-notify.fails (streak), .webhook-notify.degraded (epoch of the one warning),
#   .webhook-notify.fallback-at (epoch of the last fallback note).
# Env: FM_NOTIFY_INBOX (command that takes a note text; tests), FM_NOTIFY_FAIL_MAX, FM_NOTIFY_FALLBACK_GAP,
#   FM_SW_NOW / FM_LG_NOW (epoch; tests), FM_NOTIFY_CURL_MAX (seconds, 20).

fm_notify_now() { echo "${FM_SW_NOW:-${FM_LG_NOW:-$(date +%s)}}"; }

fm_notify_inbox() { # <text>: queue one inbox note for firstmate; best effort
  if [ -n "${FM_NOTIFY_INBOX:-}" ]; then "$FM_NOTIFY_INBOX" "$1" >/dev/null 2>&1; return 0; fi
  [ -x "$HERE/fm-inbox.sh" ] || return 0
  FM_HOME=$F FM_STATE_OVERRIDE=$S "$HERE/fm-inbox.sh" note "$1" >/dev/null 2>&1 || true
}

fm_webhook_notify() { # <event> <message>
  local event=$1 msg=$2 u k m body code rc fails now max gap last note
  u=$(cat "$HOME/.config/fm/watcher-webhook.url" 2>/dev/null); k=$(cat "$HOME/.config/fm/watcher-webhook.key" 2>/dev/null)
  { [ -n "$u" ] && [ -n "$k" ] && [ -z "${FM_SW_NO_NOTIFY:-}" ]; } || return 0
  now=$(fm_notify_now); max=${FM_NOTIFY_FAIL_MAX:-3}; gap=${FM_NOTIFY_FALLBACK_GAP:-3600}
  m=$(printf %s "$msg" | tr -d "\"\\\\")
  body=$(mktemp "${TMPDIR:-/tmp}/fm-webhook.XXXXXX") || return 1
  code=$(timeout "${FM_NOTIFY_CURL_MAX:-20}" curl -sS -X POST "$u" -H "Authorization: Bearer $k" -H "Content-Type: application/json" \
    --data "{\"event\":\"$event\",\"message\":\"$m\"}" -o "$body" -w '%{http_code}' 2>/dev/null) || code=${code:-000}
  case $code in 2??) rc=0 ;; *) rc=1 ;; esac
  if [ "$rc" -eq 0 ]; then
    rm -f "$body"
    if [ -e "$S/.webhook-notify.degraded" ]; then log "notify recovered: the webhook answers again"; fi
    rm -f "$S/.webhook-notify.fails" "$S/.webhook-notify.degraded" "$S/.webhook-notify.fallback-at"
    return 0
  fi
  note=$(head -c 400 "$body" 2>/dev/null | tr -d '\n' | sed -E 's/[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}/<id>/g' | cut -c1-120)
  note=${note//"$k"/<key>}
  rm -f "$body"
  log "notify failed http=${code:-000} ${note}"
  fails=$(cat "$S/.webhook-notify.fails" 2>/dev/null); case $fails in ''|*[!0-9]*) fails=0 ;; esac
  fails=$((fails + 1)); echo "$fails" > "$S/.webhook-notify.fails"
  [ "$fails" -ge "$max" ] || return 1
  if [ ! -e "$S/.webhook-notify.degraded" ]; then
    echo "$now" > "$S/.webhook-notify.degraded"
    fm_notify_inbox "O aviso por webhook ao dono falhou $fails vezes seguidas (http=${code:-000} ${note}). Enquanto ele nao voltar, os alertas do vigia chegam por nota no inbox (no maximo 1 por hora). Corrigir: reativar ou refazer a automacao/URL/chave em ~/.config/fm/watcher-webhook.*. Ultimo aviso nao entregue [$event]: $msg"
    echo "$now" > "$S/.webhook-notify.fallback-at"
    return 1
  fi
  if [ "$event" != recovered ]; then
    last=$(cat "$S/.webhook-notify.fallback-at" 2>/dev/null); case $last in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -ge "$gap" ]; then
      echo "$now" > "$S/.webhook-notify.fallback-at"
      fm_notify_inbox "Alerta do vigia [$event] (o webhook esta fora do ar): $msg"
    fi
  fi
  return 1
}
