#!/usr/bin/env bash
# Tests for bin/fm-lane-guard.sh: stuck `treehouse get` reaper (real processes), failed-creation warning (real
# fm-spawn failure + fixture records), pod job queue relaunch/warn (real local HTTP server standing in for RunPod).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); LG=$ROOT/bin/fm-lane-guard.sh
T=$(mktemp -d); pids=()
cleanup() { for p in "${pids[@]}"; do pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
export FM_SLOT_REQUEST_ROOT=$T HOME=$T/home FM_SW_NO_NOTIFY=1 FM_HOME=$T FM_STATE_OVERRIDE=$T/state FM_CONFIG_OVERRIDE=$T/config
mkdir -p "$HOME" "$T/state" "$T/config" "$T/data/tools" "$T/bin" "$T/work" "$T/work2" "$T/work3"
cat > "$T/data/tools/fm-asks.sh" <<'A'
#!/usr/bin/env bash
echo "$*" >> "$FM_HOME/asks.calls"
A
chmod +x "$T/data/tools/fm-asks.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2' want '$3')"; fail=1; fi; }
alerts() { [ -f "$T/state/.lane-guard-alerts" ] && wc -l < "$T/state/.lane-guard-alerts" || echo 0; }
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo dead; }

# ---- slot requests: a fake `treehouse` is bash run under that name; the script `get` in its cwd is the request
ln -s "$(command -v bash)" "$T/bin/treehouse"
mkfifo "$T/hold"                                                # read on it blocks without forking a child
printf 'read -t 300 x <> "%s"\n' "$T/hold" > "$T/work/get"      # childless request: holds no slot
printf 'sleep 300; true\n' > "$T/work2/get"                     # has a subshell child: a live lease
printf "trap '' TERM\nread -t 300 x <> \"%s\"\n" "$T/hold" > "$T/work3/get"   # ignores TERM: needs the KILL escalation
( cd "$T/work" && exec "$T/bin/treehouse" get ) & stuck=$!; pids+=("$stuck")
( cd "$T/work2" && exec "$T/bin/treehouse" get ) & lease=$!; pids+=("$lease")
( cd "$T/work3" && exec "$T/bin/treehouse" get ) & hard=$!; pids+=("$hard")
( exec sleep 300 ) & other=$!; pids+=("$other")                 # unrelated process, never touched
sleep 1
check setup-alive "$(alive $stuck)$(alive $lease)$(alive $hard)" alivealivealive
FM_SLOT_REQUEST_MAX_SEC=3600 "$LG" scan slot >/dev/null; check young-untouched "$(alive $stuck)" alive
sleep 2
out=$(FM_SLOT_REQUEST_MAX_SEC=2 FM_SLOT_REQUEST_GRACE_SEC=1 "$LG" scan slot); rc=$?
check slot-exit "$rc" 1
sleep 0.5
check stuck-ended "$(alive $stuck)" dead
check term-ignoring-ended "$(alive $hard)" dead
check lease-untouched "$(alive $lease)" alive
check other-untouched "$(alive $other)" alive
grep -q "pid=$stuck " "$T/state/.lane-guard.log"; check kill-logged $? 0
printf '%s' "$out" | grep -q "pid=$stuck "; check kill-alert-names-pid $? 0
check slot-alerts "$(alerts)" 2
FM_SLOT_REQUEST_MAX_SEC=2 "$LG" scan slot >/dev/null; check slot-rescan-quiet "$?" 0

# ---- failed creation: a real fm-spawn failure records, the next scan warns once
rm -f "$T/state/.lane-guard-alerts"
"$ROOT/bin/fm-spawn.sh" gone /nonexistent/proj --mode local-only --yolo off >/dev/null 2>&1; spawn_rc=$?
check spawn-fails "$([ "$spawn_rc" -ne 0 ] && echo yes)" yes
ls "$T"/state/spawn-failures/gone.*.fail >/dev/null 2>&1; check spawn-recorded $? 0
out=$("$LG" scan spawn); rc=$?
check spawn-warn-exit "$rc" 1
printf '%s' "$out" | grep -q 'worker creation failed: task gone exited'; check spawn-warn-text $? 0
[ ! -e "$T/asks.calls" ] || ! grep -q 'lane-guard-spawn-gone' "$T/asks.calls"; check spawn-no-ask-row $? 0
grep -q '^key=spawn-gone$' "$T/state/resil/cards/spawn-gone.card"; check spawn-card $? 0
"$LG" scan spawn >/dev/null; check spawn-warn-once "$?" 0
"$LG" record-spawn-failure ok1 1 ship proj herdr pi; : > "$T/state/ok1.meta"   # a later spawn published its record
"$LG" scan spawn >/dev/null; check spawn-recovered-quiet "$?" 0
"$LG" record-spawn-failure '../bad' 1 >/dev/null 2>&1; check spawn-bad-id "$?" 1

# ---- failed creation, classified by its own error text: transient is retried on a schedule, permanent is one card
rm -f "$T/state/.lane-guard-alerts" "$T/asks.calls"; rm -rf "$T/state/spawn-failures" "$T/state/resil"
cat > "$T/respawn.sh" <<'A'
#!/usr/bin/env bash
{ printf 'cwd=%s attempt=%s home=%s\n' "$PWD" "${FM_SPAWN_RETRY_ATTEMPT:-}" "${FM_HOME:-}"; printf 'arg=%s\n' "$@"; } >> "$FM_HOME/respawn.calls"
A
chmod +x "$T/respawn.sh"; mkdir -p "$T/work-r"
export FM_LG_SPAWN_CMD=$T/respawn.sh FM_SPAWN_RETRY_SCHEDULE="60 240 900"
NOW=$(date +%s); export FM_LG_NOW=$NOW
printf 'error: another Treehouse slot allocation or return is in progress for /p; refusing to race it\n' > "$T/err.transient"
printf 'error: quarantined herdr presentation for dup has a live pane; refusing duplicate launch\n' > "$T/err.permanent"
printf 'error: something nobody has seen before\n' > "$T/err.unknown"
"$LG" record-spawn-failure tr1 1 ship /p herdr pi "$T/err.transient" "$T/work-r" tr1 /p --mode local-only --yolo off
f=$(ls "$T"/state/spawn-failures/tr1.*.fail); grep -q '^class=transient$' "$f"; check class-transient $? 0
grep -q '^attempt=0$' "$f"; check class-attempt-zero $? 0
out=$("$LG" scan spawn); rc=$?; check transient-quiet-before-due "$rc$out" 0
check transient-not-run-early "$([ -e "$T/respawn.calls" ] && echo ran || echo no)" no
export FM_LG_NOW=$((NOW + 61))
out=$("$LG" scan spawn); rc=$?; check transient-retry-silent "$rc$out" 0
grep -q "^cwd=$T/work-r attempt=1 home=$T" "$T/respawn.calls"; check retry-cwd-attempt-home $? 0
[ "$(grep '^arg=' "$T/respawn.calls" | tr '\n' ' ')" = "arg=tr1 arg=/p arg=--mode arg=local-only arg=--yolo arg=off " ]; check retry-args-exact $? 0
grep -q 'task=tr1 cause=transient action=retry-1' "$T/state/.resil.log"; check retry-logged $? 0
"$LG" scan spawn >/dev/null; check retry-not-repeated "$(grep -c '^cwd=' "$T/respawn.calls")" 1
# the first retry failed transiently again (it ran with attempt 1, so its record says 1), next due at 240 s
FM_SPAWN_RETRY_ATTEMPT=1 "$LG" record-spawn-failure tr1 1 ship /p herdr pi "$T/err.transient" "$T/work-r" tr1 /p --mode local-only --yolo off
export FM_LG_NOW=$((NOW + 61 + 239)); "$LG" scan spawn >/dev/null; check second-retry-waits "$(grep -c '^cwd=' "$T/respawn.calls")" 1
export FM_LG_NOW=$((NOW + 61 + 241)); "$LG" scan spawn >/dev/null; check second-retry-runs "$(grep -c '^cwd=' "$T/respawn.calls")" 2
grep -q 'attempt=2' "$T/respawn.calls"; check second-attempt-number $? 0
# attempts used up: one alert, one card, no more retries
FM_SPAWN_RETRY_ATTEMPT=3 "$LG" record-spawn-failure tr1 1 ship /p herdr pi "$T/err.transient" "$T/work-r" tr1 /p
export FM_LG_NOW=$((NOW + 100000)); out=$("$LG" scan spawn); rc=$?
check exhausted-alert-exit "$rc" 1
printf '%s' "$out" | grep -q 'after 3 retries'; check exhausted-alert-text $? 0
grep -q '^key=spawn-tr1$' "$T/state/resil/cards/spawn-tr1.card"; check exhausted-card $? 0
check exhausted-no-more-retries "$(grep -c '^cwd=' "$T/respawn.calls")" 2
# a later spawn of the task publishes its record: the card goes away on the next scan
FM_LG_NOW=$NOW "$LG" record-spawn-failure tr1 1 ship /p herdr pi "$T/err.transient" "$T/work-r" tr1 /p
: > "$T/state/tr1.meta"; touch -d "@$((NOW + 5))" "$T/state/tr1.meta"
FM_LG_NOW=$NOW "$LG" scan spawn >/dev/null; check card-dropped-when-recovered "$([ -e "$T/state/resil/cards/spawn-tr1.card" ] && echo kept || echo gone)" gone
rm -f "$T/state/tr1.meta"
# permanent: no retry, exactly one card and one alert, no captain-ask row
rm -rf "$T/state/resil" "$T/respawn.calls"; export FM_LG_NOW=$NOW
"$LG" record-spawn-failure pe1 1 scout /p herdr pi "$T/err.permanent" "$T/work-r" pe1 /p --mode local-only --yolo off
out=$("$LG" scan spawn); rc=$?
check permanent-alert-exit "$rc" 1
printf '%s' "$out" | grep -q 'refusing duplicate launch'; check permanent-alert-has-error $? 0
grep -q '^key=spawn-pe1$' "$T/state/resil/cards/spawn-pe1.card"; check permanent-card $? 0
check permanent-no-retry "$([ -e "$T/respawn.calls" ] && echo ran || echo no)" no
export FM_LG_NOW=$((NOW + 100000)); "$LG" scan spawn >/dev/null; check permanent-once "$?" 0
# an error nobody classified is not repeated either; a relaunch is never replayed
"$LG" record-spawn-failure un1 1 ship /p herdr pi "$T/err.unknown" "$T/work-r" un1 /p
out=$("$LG" scan spawn); printf '%s' "$out" | grep -q 'task un1'; check unknown-is-permanent $? 0
"$LG" record-spawn-failure rl1 1 ship /p herdr pi "$T/err.transient" "$T/work-r" rl1 /p --relaunch --note x
out=$("$LG" scan spawn); printf '%s' "$out" | grep -q 'task rl1'; check relaunch-not-replayed $? 0
check no-retry-ran-for-those "$([ -e "$T/respawn.calls" ] && echo ran || echo no)" no
unset FM_LG_NOW FM_LG_SPAWN_CMD FM_SPAWN_RETRY_SCHEDULE

# ---- pod job queue against a local fake RunPod
cat > "$T/api.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
d = sys.argv[1]
def rd(n, default=''):
    try: return open(os.path.join(d, n)).read().strip()
    except OSError: return default
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        open(os.path.join(d, 'calls'), 'a').write('GET %s auth=%s\n' % (self.path, 'yes' if 'Bearer secretkey' in self.headers.get('Authorization', '') else 'no'))
        if self.path == '/pods/pod1': self.send(200, {'id': 'pod1', 'desiredStatus': rd('status', 'EXITED')})
        else: self.send(404, {})
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0); self.rfile.read(n)
        open(os.path.join(d, 'calls'), 'a').write('POST %s\n' % self.path)
        if self.path == '/graphql': self.send(200, {'data': {'myself': {'clientBalance': float(rd('balance', '0'))}}})
        elif self.path == '/pods/pod1/start': self.send(200, {})
        else: self.send(404, {})
HTTPServer(('127.0.0.1', int(sys.argv[2])), H).serve_forever()
PY
mkdir -p "$T/api" "$T/auto"; port=$((20000 + RANDOM % 20000))
python3 -I "$T/api.py" "$T/api" "$port" & pids+=("$!")
for _ in $(seq 1 50); do curl -s -m 1 "http://127.0.0.1:$port/pods/x" >/dev/null && break; sleep 0.1; done
export FM_POD_API=http://127.0.0.1:$port FM_POD_GRAPHQL=http://127.0.0.1:$port/graphql FM_RUNPOD_ENV=$T/runpod.env
export FM_POD_AUTO_DIR=$T/auto FM_POD_QUEUE_DIR=$T/state/.heavy-queue FM_POD_WATCH_QUEUE_SEC=600 FM_POD_WATCH_RETRY_SEC=900
mkdir -p "$FM_POD_QUEUE_DIR"; echo "pod1 extra" > "$T/auto/pod.id"; echo 'RUNPOD_API_KEY="secretkey"' > "$T/runpod.env"
rm -f "$T/state/.lane-guard-alerts" "$T/asks.calls"
NOW=$(date +%s); export FM_LG_NOW=$NOW
podscan() { : > "$T/api/calls"; "$LG" scan pod; }
: > "$FM_POD_QUEUE_DIR/job1.queued"; touch -d "@$((NOW-1200))" "$FM_POD_QUEUE_DIR/job1.queued"
echo EXITED > "$T/api/status"; echo 5.0 > "$T/api/balance"
podscan >/dev/null; check optin-off-quiet "$(cat "$T/api/calls")" ""
touch "$T/config/pod-watch"
touch -d "@$((NOW-60))" "$FM_POD_QUEUE_DIR/job1.queued"; podscan >/dev/null; check young-queue-quiet "$(cat "$T/api/calls")" ""
touch -d "@$((NOW-1200))" "$FM_POD_QUEUE_DIR/job1.queued"
echo RUNNING > "$T/api/status"; podscan >/dev/null; check running-no-alert "$?" 0; check running-no-post "$(grep -c POST "$T/api/calls")" 0
# stopped pod + positive balance: START of the existing pod, never a create
echo EXITED > "$T/api/status"; out=$(podscan); rc=$?
check relaunch-exit "$rc" 1
grep -q 'POST /pods/pod1/start' "$T/api/calls"; check relaunch-start-posted $? 0
check relaunch-no-create "$(grep -cE 'POST /pods( |$)|DELETE' "$T/api/calls")" 0
printf '%s' "$out" | grep -q 'start requested'; check relaunch-alert $? 0
grep -q 'auth=yes' "$T/api/calls"; check key-sent-as-bearer $? 0
! grep -rq secretkey "$T/state"; check key-not-in-state $? 0
! printf '%s' "$out" | grep -q secretkey; check key-not-printed $? 0
podscan >/dev/null; check retry-throttled "$(cat "$T/api/calls")" ""
# non-positive balance: warn, no start
rm -rf "$T/state/.pod-watch"; echo -3.2 > "$T/api/balance"; out=$(podscan)
check negative-no-start "$(grep -c 'pod1/start' "$T/api/calls")" 0
printf '%s' "$out" | grep -q 'NOT started'; check negative-warns $? 0
grep -q '^add --key lane-guard-pod-pod1' "$T/asks.calls"; check negative-ask $? 0
rm -rf "$T/state/.pod-watch"; echo 0 > "$T/api/balance"; podscan >/dev/null; check zero-no-start "$(grep -c 'pod1/start' "$T/api/calls")" 0
# no pod recorded: warn only
rm -rf "$T/state/.pod-watch"; rm "$T/auto/pod.id"; out=$(podscan)
printf '%s' "$out" | grep -q 'no pod is recorded'; check no-pod-warns $? 0; check no-pod-no-api "$(cat "$T/api/calls")" ""
# recorded pod gone (404): warn, no create
echo podX > "$T/auto/pod.id"; rm -rf "$T/state/.pod-watch"; out=$(podscan)
printf '%s' "$out" | grep -q 'cannot be read (http 404)'; check gone-warns $? 0
check gone-no-create "$(grep -c POST "$T/api/calls")" 0
# unreadable key: warn, no api call
echo pod1 > "$T/auto/pod.id"; rm -rf "$T/state/.pod-watch"; : > "$T/runpod.env"; out=$(podscan)
printf '%s' "$out" | grep -q 'key is unreadable'; check nokey-warns $? 0; check nokey-no-api "$(cat "$T/api/calls")" ""

# ---- wiring
grep -q 'fm-lane-guard.sh" scan' "$ROOT/bin/fm-watch.sh"; check watcher-runs-guard $? 0
grep -q 'record-spawn-failure' "$ROOT/bin/fm-spawn.sh"; check spawn-records-failure $? 0
exit $fail
