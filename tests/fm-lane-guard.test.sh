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
grep -q '^add --key lane-guard-spawn-gone' "$T/asks.calls"; check spawn-ask $? 0
"$LG" scan spawn >/dev/null; check spawn-warn-once "$?" 0
"$LG" record-spawn-failure ok1 1 ship proj herdr pi; : > "$T/state/ok1.meta"   # a later spawn published its record
"$LG" scan spawn >/dev/null; check spawn-recovered-quiet "$?" 0
"$LG" record-spawn-failure '../bad' 1 >/dev/null 2>&1; check spawn-bad-id "$?" 1

# ---- scheduled loops: a refused (75) scheduled spawn is a missed run and is warned about; the helper's alert and clear
rm -f "$T/state/.lane-guard-alerts" "$T/asks.calls" "$T/state/spawn-failures"/*
"$LG" record-spawn-failure sched1 75 ship proj herdr pi daily-audit
out=$("$LG" scan spawn); rc=$?
check scheduled-deferral-warns "$rc" 1
printf '%s' "$out" | grep -q 'scheduled loop daily-audit: worker creation failed: task sched1 exited 75'; check scheduled-deferral-text $? 0
"$LG" record-spawn-failure bad1 1 ship proj herdr pi 'bad loop'; check scheduled-bad-loop-refused "$?" 1
out=$("$LG" alert scheduled-daily-audit 'scheduled loop daily-audit did not start'); rc=$?
check helper-alert-exit "$rc" 1
printf '%s' "$out" | grep -q 'did not start'; check helper-alert-text $? 0
grep -q '^add --key lane-guard-scheduled-daily-audit' "$T/asks.calls"; check helper-alert-ask $? 0
"$LG" clear-alert scheduled-daily-audit; check helper-clear-exit "$?" 0
grep -q '^done lane-guard-scheduled-daily-audit' "$T/asks.calls"; check helper-clear-ask-done $? 0
grep -q 'CLEARED scheduled-daily-audit' "$T/state/.lane-guard.log"; check helper-clear-logged $? 0
rm -f "$T/state/.lane-guard-alerts" "$T/asks.calls"

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
