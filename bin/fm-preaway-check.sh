#!/usr/bin/env bash
# fm-preaway-check.sh - checklist to run before the captain goes away (daily speed audit 2026-10-28 item 4).
# Pure shell: no model call, no sudo, never creates a pod, prints no secret.
# Usage: fm-preaway-check.sh
# Output: a numbered checklist, one `N. OK|MISSING|UNKNOWN <what>: <detail>` line per check, then a plain-text block
#   "Steps that need the captain" naming each MISSING item with an exact Fortaleza (America/Fortaleza) clock time.
# Checks:
#   1 Claude login   ~/.claude/.credentials.json claudeAiOauth.expiresAt only; MISSING under FM_PREAWAY_LOGIN_MIN_HOURS (6) left
#   2 RunPod balance data/tools/fm-pod-budget.sh status when present; MISSING when the balance is not positive
#   3 Free slots     bin/fm-capacity.sh free_lanes; MISSING at 0, UNKNOWN when it reports no target
#   4 PC             `ssh <FM_PREAWAY_PC_SSH, default pc-aux> true`, 10 s timeout (the host of the pc-aux2 secondmate)
#   5 Mac            `ssh <FM_PREAWAY_MAC_SSH> true`, 10 s timeout; UNKNOWN while no Mac ssh target is documented or set
#   6 Claude budget  bin/fm-claude-budget.sh --flag; MISSING when above_budget
# Env: FM_HOME FM_STATE_OVERRIDE FM_PREAWAY_CREDENTIALS (default ~/.claude/.credentials.json) FM_PREAWAY_NOW (epoch, tests)
#   FM_PREAWAY_GRACE_MIN (minutes from now for the clock times, default 20) FM_PREAWAY_SSH_TIMEOUT (10)
#   FM_PREAWAY_PC_SSH FM_PREAWAY_MAC_SSH FM_PREAWAY_POD_BUDGET FM_PREAWAY_CAPACITY FM_PREAWAY_CLAUDE_BUDGET (script paths, tests).
# Exit: 0 nothing MISSING, 1 at least one MISSING.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
F=${FM_HOME:-$(cd "$HERE/.." && pwd)}
CRED=${FM_PREAWAY_CREDENTIALS:-$HOME/.claude/.credentials.json}
NOW=${FM_PREAWAY_NOW:-$(date +%s)}
LOGIN_MIN_H=${FM_PREAWAY_LOGIN_MIN_HOURS:-6}
GRACE=${FM_PREAWAY_GRACE_MIN:-20}
SSH_T=${FM_PREAWAY_SSH_TIMEOUT:-10}
POD=${FM_PREAWAY_POD_BUDGET:-$F/data/tools/fm-pod-budget.sh}
CAP=${FM_PREAWAY_CAPACITY:-$HERE/fm-capacity.sh}
BUD=${FM_PREAWAY_CLAUDE_BUDGET:-$HERE/fm-claude-budget.sh}
N=0; MISSING=0; STEPS=()
clock() { TZ=America/Fortaleza date -d "@$1" +%H:%M; }
DEADLINE=$(clock $((NOW + GRACE * 60)))
line() { # status what detail [step]
  N=$((N + 1)); printf '%d. %s %s: %s\n' "$N" "$1" "$2" "$3"
  if [ "$1" = MISSING ]; then MISSING=1; [ -z "${4:-}" ] || STEPS+=("$4"); fi
}
ssh_check() { # label target step-text
  local label=$1 target=$2
  [ -n "$target" ] || { line UNKNOWN "$label" "no ssh target documented; set FM_PREAWAY_${label^^}_SSH"; return; }
  # shellcheck disable=SC2086
  if timeout "$SSH_T" ssh -o BatchMode=yes -o ConnectTimeout="$SSH_T" $target true </dev/null >/dev/null 2>&1; then
    line OK "$label" "ssh $target answers"
  else
    line MISSING "$label" "ssh $target did not answer in ${SSH_T}s" "$3"
  fi
}

# 1. Claude login: expiresAt (epoch ms) only; the tokens next to it are never read into output.
exp=$(jq -r '.claudeAiOauth.expiresAt // empty' "$CRED" 2>/dev/null)
case "$exp" in
  ''|*[!0-9]*) line MISSING "Claude login" "no readable expiresAt in the credentials file" \
    "Refazer o login do Claude (rodar /login no terminal do Claude) até $DEADLINE (Fortaleza)." ;;
  *)
    left=$(( (exp / 1000 - NOW) ))
    if [ "$left" -ge $((LOGIN_MIN_H * 3600)) ]; then
      line OK "Claude login" "valid until $(clock $((exp / 1000))) Fortaleza ($((left / 3600)) h left)"
    else
      line MISSING "Claude login" "expires $(clock $((exp / 1000))) Fortaleza (under ${LOGIN_MIN_H} h left)" \
        "Refazer o login do Claude (rodar /login no terminal do Claude) até $DEADLINE (Fortaleza); hoje ele vence às $(clock $((exp / 1000)))."
    fi ;;
esac

# 2. RunPod balance (read-only status; the tool never creates a pod here).
if [ -x "$POD" ]; then
  bal=$(timeout 60 "$POD" status 2>/dev/null </dev/null | sed -n 's/.*balance=\([^ ]*\).*/\1/p' | head -1)
  if [ -z "$bal" ]; then
    line UNKNOWN "RunPod balance" "status gave no balance"
  elif awk -v b="$bal" 'BEGIN { exit !(b + 0 > 0) }'; then
    line OK "RunPod balance" "USD $bal"
  else
    line MISSING "RunPod balance" "USD $bal is not positive; no pod is created" \
      "Pôr saldo na RunPod (runpod.io/console/user/billing) até $DEADLINE (Fortaleza); sem saldo nenhuma prova pesada roda enquanto você estiver fora."
  fi
else
  line UNKNOWN "RunPod balance" "data/tools/fm-pod-budget.sh not present"
fi

# 3. Free worker slots.
if [ -x "$CAP" ]; then
  free=$(FM_HOME="$F" "$CAP" 2>/dev/null </dev/null | sed -n '1s/.*free_lanes=\([^ ]*\).*/\1/p')
  case "$free" in
    '') line UNKNOWN "Free slots" "capacity report unreadable" ;;
    unknown) line UNKNOWN "Free slots" "no lane target set (config/lane-capacity absent)" ;;
    0) line MISSING "Free slots" "free_lanes=0" \
      "Liberar vagas de worker (encerrar workers que já entregaram) até $DEADLINE (Fortaleza), ou confirmar que nada novo precisa abrir enquanto você estiver fora." ;;
    *) line OK "Free slots" "free_lanes=$free" ;;
  esac
else
  line UNKNOWN "Free slots" "bin/fm-capacity.sh not present"
fi

# 4-5. Reachability.
ssh_check PC "${FM_PREAWAY_PC_SSH-pc-aux}" "Ligar ou acordar o PC e conferir que o WSL responde por SSH, até $DEADLINE (Fortaleza); não entre no Windows depois desse horário."
ssh_check Mac "${FM_PREAWAY_MAC_SSH-}" "Ligar ou acordar o Mac e conferir que ele responde por SSH, até $DEADLINE (Fortaleza)."

# 6. Claude daily budget (bin/fm-claude-budget.sh owns it).
if [ -x "$BUD" ]; then
  flag=$(FM_HOME="$F" "$BUD" --flag 2>/dev/null </dev/null | head -1)
  case "$flag" in
    within_budget) line OK "Claude budget" "within today's budget" ;;
    above_budget) line MISSING "Claude budget" "above today's budget" \
      "Segurar trabalho que gasta Claude (usar Sonnet nas provas e scouts) pelo resto do dia; confirmar até $DEADLINE (Fortaleza)." ;;
    *) line UNKNOWN "Claude budget" "no fresh budget record" ;;
  esac
else
  line UNKNOWN "Claude budget" "bin/fm-claude-budget.sh not present"
fi

echo
echo "Steps that need the captain"
if [ "${#STEPS[@]}" -eq 0 ]; then
  echo "None: nothing is MISSING."
else
  for s in "${STEPS[@]}"; do echo "- $s"; done
fi
exit "$MISSING"
