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
export FM_SW_NO_NOTIFY=1 FM_SW_QUOTA_STATUS="echo unknown"
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
grep -c '^add --key silent-watcher' "$T/asks.calls" | { read c; check ask-once "$c" 1; }
# recovery closes incident + ask
check recover "$(run "$alive")" 0; [ -e "$T/state/.silent-watcher.incident" ]; check incident-cleared $? 1
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
exit $fail
