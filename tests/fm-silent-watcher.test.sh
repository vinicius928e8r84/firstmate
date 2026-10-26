#!/usr/bin/env bash
# Tests for bin/fm-silent-watcher.sh: healthy, dead watcher, stale beat, stale queue, HOLD, debounce, recovery.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); SW=$ROOT/bin/fm-silent-watcher.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state" "$T/data/tools"
cat > "$T/data/tools/fm-asks.sh" <<'A'
#!/usr/bin/env bash
echo "$*" >> "$FM_HOME/asks.calls"
A
chmod +x "$T/data/tools/fm-asks.sh"
# notify() POSTs to the webhook named under $HOME/.config/fm, so no run of this test
# may see a real HOME: a stub curl records any POST that would have gone out, and the
# runs use a private HOME that does hold a webhook config, so only FM_SW_NO_NOTIFY
# keeps the stub from being called.
mkdir -p "$T/bin" "$T/home/.config/fm"
printf 'http://127.0.0.1:9/hook\n' > "$T/home/.config/fm/watcher-webhook.url"
printf 'test-key\n' > "$T/home/.config/fm/watcher-webhook.key"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/curl.calls"\n' "$T" > "$T/bin/curl"
chmod +x "$T/bin/curl"
PATH="$T/bin:$PATH"; export PATH
NOW=2000000000; fail=0
run() { HOME=$T/home FM_SW_NO_NOTIFY=1 FM_HOME=$T FM_SW_NOW=$NOW FM_SW_PGREP="$1" bash "$SW"; echo $?; }
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
# every scenario above alerted or recovered; none may have reached the webhook
check no-webhook-post "$([ -f "$T/curl.calls" ] && wc -l < "$T/curl.calls" || echo 0)" 0
exit $fail
