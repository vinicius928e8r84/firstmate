#!/usr/bin/env bash
# Tests for bin/fm-runner-watch.sh against a stand-in `gh` (answers come from files under $T/gh; every call is logged).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); W=$ROOT/bin/fm-runner-watch.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME=$T/home FM_SW_NO_NOTIFY=1 PATH=$T/bin:$PATH FM_RW_NOW=1000000000 GH_STUB=$T/gh
mkdir -p "$HOME" "$T/gh" "$T/bin"
cat > "$T/bin/gh" <<'A'
#!/usr/bin/env bash
# gh api <path>: answers from $GH_STUB, logs every argv, fails for anything that is not a plain GET
echo "$*" >> "$GH_STUB/calls"
[ "$1" = api ] && [ $# -eq 2 ] || exit 64
case $2 in
  */actions/runs\?status=queued*) f=runs ;;
  */actions/runs/*/jobs*) f=jobs ;;
  */actions/runners*) f=runners ;;
  *) exit 1 ;;
esac
[ -f "$GH_STUB/$f.fail" ] && exit 1
cat "$GH_STUB/$f.json"
A
chmod +x "$T/bin/gh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2' want '$3')"; fail=1; fi; }
iso() { date -u -d "@$((FM_RW_NOW - $1))" +%FT%TZ; }
runs() { printf '{"workflow_runs":[{"id":7}]}\n' > "$T/gh/runs.json"; }
jobs_queued() { # <age seconds> [status]
  printf '{"jobs":[{"name":"done-job","status":"completed","created_at":"%s"},{"name":"build","status":"%s","created_at":"%s"}]}\n' \
    "$(iso 9999)" "${2:-queued}" "$(iso "$1")" > "$T/gh/jobs.json"; }
runners() { printf '{"runners":[{"name":"r1","status":"%s"},{"name":"r2","status":"offline"}]}\n' "$1" > "$T/gh/runners.json"; }
run() { out=$("$W" o/r 2>"$T/err"); rc=$?; }

printf '{"workflow_runs":[]}\n' > "$T/gh/runs.json"; runners offline
run; check no-queued-job "$out|$rc" "|0"

runs; jobs_queued 300; runners offline
run; check queued-under-10m-no-runner "$out|$rc" "|0"
jobs_queued 600
run; check queued-exactly-10m "$out|$rc" "|0"

jobs_queued 1500; runners online
run; check queued-over-10m-runner-online "$out|$rc" "|0"

runners offline
run; check over-10m-no-runner-exit "$rc" 3
check over-10m-no-runner-line "$out" 'runner-watch: o/r job "build" queued 25m with no self-hosted runner online'
check one-line "$(printf '%s\n' "$out" | wc -l)" 1

jobs_queued 1500 in_progress
run; check old-but-running-job-ignored "$out|$rc" "|0"

jobs_queued 120
out=$(FM_RW_QUEUE_SEC=60 "$W" o/r 2>/dev/null); rc=$?; check threshold-env "$rc" 3

jobs_queued 1500; : > "$T/gh/runners.fail"
run; check runner-list-unreadable-not-a-warning "$rc|$out" "2|"
rm -f "$T/gh/runners.fail"; : > "$T/gh/runs.fail"
run; check gh-failure "$rc|$out" "2|"; rm -f "$T/gh/runs.fail"
"$W" >/dev/null 2>&1; check usage-no-arg "$?" 2
"$W" justrepo >/dev/null 2>&1; check usage-bad-repo "$?" 2

check only-get-api-calls "$(grep -vc '^api repos/o/r/actions/' "$T/gh/calls")" 0
check no-write-flags "$(grep -cE ' (-X|--method|-f|-F|--field|--input)' "$T/gh/calls")" 0
exit "$fail"
