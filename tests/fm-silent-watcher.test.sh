#!/usr/bin/env bash
# Tests for bin/fm-silent-watcher.sh: healthy, dead watcher, stale beat, stale queue, HOLD, debounce, recovery,
# and the one-time exhausted-quota notice (fake quota status, no network, no webhook).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); SW=$ROOT/bin/fm-silent-watcher.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state" "$T/data/tools"
cat > "$T/data/tools/fm-asks.sh" <<'A'
#!/usr/bin/env bash
echo "$*" >> "$FM_HOME/asks.calls"
A
chmod +x "$T/data/tools/fm-asks.sh"
NOW=2000000000; fail=0
export FM_SW_NO_NOTIFY=1 FM_SW_QUOTA_STATUS="echo unknown"   # the first runs must never reach the real webhook; the webhook section below lifts it for a fake curl
run() { FM_HOME=$T FM_SW_NOW=$NOW FM_SW_PGREP="$1" bash "$SW"; echo $?; }
alive="echo 123"; dead="true"
setbeat() { touch -d "@$1" "$T/state/.last-watcher-beat"; }
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got $2 want $3)"; fail=1; fi; }
alerts() { [ -f "$T/state/.silent-watcher-alerts" ] && wc -l < "$T/state/.silent-watcher-alerts" || echo 0; }
# healthy
setbeat $((NOW-60)); printf '%s\tx\n' $((NOW-120)) > "$T/state/.wake-queue"
check healthy "$(run "$alive")" 0; check healthy-no-alert "$(alerts)" 0
# dead watcher -> alert once
check dead "$(run "$dead")" 1; check dead-alert "$(alerts)" 1
grep -q missing "$T/state/.silent-watcher-alerts"; check dead-reason $? 0
check debounce "$(run "$dead")" 1; check debounce-no-spam "$(alerts)" 1
grep -c '^add --key silent-watcher' "$T/asks.calls" | { read -r c; check ask-once "$c" 1; }
# recovery closes incident + ask
check recover "$(run "$alive")" 0; [ -e "$T/state/.silent-watcher.incident" ] && inc=0 || inc=1; check incident-cleared "$inc" 1
grep -q '^done silent-watcher' "$T/asks.calls"; check ask-done $? 0
# stale beat, process alive (hung)
setbeat $((NOW-3600)); check stale-beat "$(run "$alive")" 1; check stale-alert "$(alerts)" 2
setbeat $((NOW-60)); run "$alive" >/dev/null
# stale queue
printf '%s\ta\n%s\tb\n' $((NOW-1800)) $((NOW-30)) > "$T/state/.wake-queue"
check stale-queue "$(run "$alive")" 1; tail -1 "$T/state/.silent-watcher-alerts" | grep -q '2 undelivered'; check queue-reason $? 0
run "$alive" >/dev/null; rm -f "$T/state/.silent-watcher.incident"
# HOLD silences queue check only
touch "$T/state/HOLD"; check hold-queue "$(run "$alive")" 0; check hold-dead "$(run "$dead")" 1
# a usage-limit hold keeps wakes queued on purpose: no queue alarm until it ends
rm -f "$T/state/HOLD" "$T/state/.silent-watcher.incident"
printf 'until=%s\nchecked=%s\n' $((NOW+3600)) "$NOW" > "$T/state/.quota-silence"
check quota-hold-queue "$(run "$alive")" 0
printf 'until=0\nchecked=%s\n' "$NOW" > "$T/state/.quota-silence"
check quota-hold-over "$(run "$alive")" 1
# exhausted weekly quota: ONE ask with the renewal in Fortaleza time, no repeat until the quota reads clear
rm -f "$T/state/.silent-watcher.incident" "$T/asks.calls"; setbeat $((NOW-60)); : > "$T/state/.wake-queue"
RENEW=$((NOW+7200))   # 2033-05-18T05:33:20Z is 02:33:20 in Fortaleza (UTC-3)
asks_n() { [ -f "$T/asks.calls" ] && grep -c "^add --key quota-zero" "$T/asks.calls" || echo 0; }
export FM_SW_QUOTA_STATUS="echo unknown"
check quota-unknown "$(run "$alive")" 0; check quota-unknown-no-ask "$(asks_n)" 0
export FM_SW_QUOTA_STATUS="echo exhausted $RENEW"
check quota-zero "$(run "$alive")" 0; check quota-zero-ask "$(asks_n)" 1
grep -q "18/05 às 02:33 (Fortaleza)" "$T/asks.calls"; check quota-zero-fortaleza $? 0
check quota-zero-again "$(run "$alive")" 0; check quota-zero-no-repeat "$(asks_n)" 1
export FM_SW_QUOTA_STATUS="echo unknown"
run "$alive" >/dev/null; check quota-unreadable-no-repeat "$(asks_n)" 1
export FM_SW_QUOTA_STATUS="echo clear"
run "$alive" >/dev/null; grep -q '^done quota-zero' "$T/asks.calls"; check quota-clear-closes-ask $? 0
export FM_SW_QUOTA_STATUS="echo exhausted $((RENEW+604800))"
run "$alive" >/dev/null; check quota-next-week-asks-again "$(asks_n)" 2

# --- the webhook notice: failure status is logged, a streak falls back to ONE inbox note, success clears it
W=$(mktemp -d); trap 'rm -rf "$T" "$W"' EXIT
mkdir -p "$W/home/.config/fm" "$W/bin"
printf 'https://hooks.example.test/automations/webhook/6a797cf0-1404-5ea3-b2e6-f36749c0c971' > "$W/home/.config/fm/watcher-webhook.url"
printf 'crs_secretkeyvalue' > "$W/home/.config/fm/watcher-webhook.key"
cat > "$W/bin/curl" <<'C'
#!/usr/bin/env bash
out=; while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; esac; shift; done
printf '%s' "${FAKE_BODY:-}" > "$out"; printf '%s' "${FAKE_CODE:-200}"; [ "${FAKE_CODE:-200}" -lt 300 ]
C
cat > "$W/inbox.sh" <<'I'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/inbox.notes"
I
chmod +x "$W/bin/curl" "$W/inbox.sh"
nrun() { # <now> <pgrep>: one watcher run with the fake webhook; FAKE_CODE/FAKE_BODY select the reply
  setbeat $(($1 - 60))
  HOME=$W/home PATH=$W/bin:$PATH FM_HOME=$T FM_SW_NOW=$1 FM_SW_PGREP="$2" FM_SW_QUOTA_STATUS="echo unknown" FM_NOTIFY_INBOX=$W/inbox.sh FM_NOTIFY_FALLBACK_GAP=3600 env -u FM_SW_NO_NOTIFY bash "$SW" >/dev/null; }
notes() { [ -f "$T/inbox.notes" ] && wc -l < "$T/inbox.notes" || echo 0; }
rm -f "$T/state/.silent-watcher.incident" "$T/state/HOLD" "$T/state/.quota-silence" "$T/state/.silent-watcher.log" "$T/inbox.notes"
setbeat $((NOW-60)); : > "$T/state/.wake-queue"
export FAKE_CODE=400 FAKE_BODY='{"success":false,"error":"Automation 6a797cf0-1404-5ea3-b2e6-f36749c0c971 is disabled"}'
nrun $NOW "$dead"                                  # alert: failure 1
grep -q 'notify failed http=400 .*is disabled' "$T/state/.silent-watcher.log"; check fail-logs-status $? 0
check fail-1-no-note "$(notes)" 0
nrun $((NOW+300)) "$alive"                         # recovered notice: failure 2
nrun $((NOW+600)) "$dead"                          # alert: failure 3 -> degraded, one note
check fail-3-one-note "$(notes)" 1
grep -q 'falhou 3 vezes' "$T/inbox.notes"; check note-says-streak $? 0
nrun $((NOW+900)) "$alive"; nrun $((NOW+1200)) "$dead"   # inside the one-hour gap: no second note
check gap-no-second-note "$(notes)" 1
nrun $((NOW+4500)) "$alive"; nrun $((NOW+4800)) "$dead"  # past the gap: the next alert is also queued
check gap-over-note "$(notes)" 2
grep -q 'Alerta do vigia \[alert\]' "$T/inbox.notes"; check fallback-carries-alert $? 0
! grep -rq 'secretkey\|6a797cf0' "$T/state" "$T/inbox.notes"; check no-secret-or-id-leak $? 0
export FAKE_CODE=200 FAKE_BODY=''
nrun $((NOW+5100)) "$alive"                        # a delivered notice clears the streak
[ ! -e "$T/state/.webhook-notify.fails" ] && [ ! -e "$T/state/.webhook-notify.degraded" ]; check success-clears-streak $? 0
grep -q 'notify recovered' "$T/state/.silent-watcher.log"; check success-logs-recovery $? 0
# --- simulated zero quota, end to end: real fm-quota-silence.sh over a fake quota-axi, the webhook dead (the
# --- owner's automation disabled), then fixed. The owner's notice must not die with the channel.
mkdir -p "$T/config"; printf 'claude\n' > "$T/config/quota-silence"
fake_axi() { # <pct>: one claude row, all_models at <pct>% remaining, five_hour window resetting at RESET_ISO
  local runway=through_reset; [ "$1" -ne 0 ] || runway=exhausted_now
  cat > "$W/bin/quota-axi" <<SH
#!/usr/bin/env bash
cat <<'JSON'
{"schemaVersion":5,"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":"$RESET_ISO","percentRemaining":$1}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":$1,"limitingWindowIds":["five_hour"],"runway":{"status":"$runway"}}]}}]}
JSON
SH
  chmod +x "$W/bin/quota-axi"
}
RESET_EPOCH=$(( $(date +%s) + 7200 )); RESET_ISO=$(date -u -d "@$RESET_EPOCH" +%Y-%m-%dT%H:%M:%S.000000+00:00)
qrun() { # <now>: a healthy watcher run reading the real quota probe through the fake quota-axi and fake curl
  setbeat $(($1 - 60))
  HOME=$W/home PATH=$W/bin:$PATH FM_HOME=$T FM_SW_NOW=$1 FM_SW_PGREP="$alive" FM_QUOTA_SILENCE_AXI=$W/bin/quota-axi FM_NOTIFY_INBOX=$W/inbox.sh env -u FM_SW_NO_NOTIFY -u FM_SW_QUOTA_STATUS bash "$SW" >/dev/null; }
rm -f "$T/state/".silent-watcher* "$T/state/".webhook-notify.* "$T/state/.quota-exhausted-notified" "$T/state/.quota-notice-pending" "$T/inbox.notes" "$T/asks.calls"
Q0=$(date +%s)
fake_axi 60; FAKE_CODE=400 FAKE_BODY='{"success":false,"error":"Automation x is disabled"}'; export FAKE_CODE FAKE_BODY
qrun $Q0; check qsim-clear-no-ask "$(asks_n)" 0; check qsim-clear-no-note "$(notes)" 0
fake_axi 0
qrun $Q0                                           # quota zero, webhook refuses (http 400)
check qsim-zero-ask "$(asks_n)" 1
grep -q 'Renova em' "$T/asks.calls"; check qsim-zero-ask-renewal $? 0
check qsim-zero-inbox-note-at-once "$(notes)" 1    # first failure: no streak yet, the critical notice still reaches the inbox
grep -q 'NAO saiu pelo webhook' "$T/inbox.notes"; check qsim-note-says-undelivered $? 0
grep -q 'http=400' "$T/state/.silent-watcher.log"; check qsim-logs-status $? 0
[ -e "$T/state/.quota-notice-pending" ]; check qsim-pending-kept $? 0
qrun $((Q0+300)); qrun $((Q0+600))                 # later runs: no second ask, no inbox spam, the webhook is retried
check qsim-no-repeat-ask "$(asks_n)" 1; check qsim-no-repeat-note "$(notes)" 1
[ -e "$T/state/.quota-notice-pending" ]; check qsim-still-pending $? 0
check qsim-retry-not-counted "$(cat "$T/state/.webhook-notify.fails")" 1
export FAKE_CODE=200 FAKE_BODY=''                  # the owner re-enabled the automation
qrun $((Q0+900))
[ ! -e "$T/state/.quota-notice-pending" ]; check qsim-delivered-late-clears-pending $? 0
grep -q 'quota notice delivered late' "$T/state/.silent-watcher.log"; check qsim-logs-late-delivery $? 0
check qsim-late-no-new-ask "$(asks_n)" 1
fake_axi 60
qrun $((Q0+1200))                                  # the quota is back: the ask closes
grep -q '^done quota-zero' "$T/asks.calls"; check qsim-clear-closes-ask $? 0
[ ! -e "$T/state/.quota-exhausted-notified" ]; check qsim-clear-marker-gone $? 0
# a webhook that never recovers: pending is dropped when the quota clears, so the next week starts clean
export FAKE_CODE=400 FAKE_BODY='{}'; fake_axi 0
qrun $((Q0+1500)); [ -e "$T/state/.quota-notice-pending" ]; check qsim-week2-pending $? 0
fake_axi 60; qrun $((Q0+1800)); [ ! -e "$T/state/.quota-notice-pending" ]; check qsim-clear-drops-pending $? 0
exit $fail
