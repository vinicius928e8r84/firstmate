#!/usr/bin/env bash
# Tests for bin/fm-prewindow-check.sh with stand-in ssh (runs the remote script locally), gh, pgrep and ps.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); P=$ROOT/bin/fm-prewindow-check.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME=$T/home FM_SW_NO_NOTIFY=1 PATH=$T/bin:$PATH
mkdir -p "$HOME" "$T/bin"
NOW=1793000000
export FM_PREWINDOW_NOW=$NOW FM_PREWINDOW_RETRY_SLEEP=0 FM_PREWINDOW_RETRIES=3
export FM_PREWINDOW_PC_SSH=pcgood FM_PREWINDOW_MAC_SSH=macgood FM_PREWINDOW_CREDENTIALS=$T/cred.json
export PT_LOG=$T/ssh.log PT_COUNT=$T/ssh.count PT_FAIL_FIRST=0
# ssh: log the call, fail the first PT_FAIL_FIRST calls, always fail for a host named *down, else run the stdin script locally.
cat > "$T/bin/ssh" <<'A'
#!/usr/bin/env bash
echo "$*" >> "$PT_LOG"
case " $* " in *down*) exit 255 ;; esac
n=$(cat "$PT_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$PT_COUNT"
[ "$n" -gt "$PT_FAIL_FIRST" ] || exit 255
exec bash -s
A
cat > "$T/bin/pgrep" <<'A'
#!/usr/bin/env bash
[ "${PT_KEEPER:-1}" = 1 ] && echo 4242
[ "${PT_KEEPER:-1}" = 1 ]
A
cat > "$T/bin/ps" <<'A'
#!/usr/bin/env bash
printf '%s\n' "  100 /usr/sbin/launchd /sbin/launchd" "  200 /Applications/Anki.app/Contents/MacOS/anki /Applications/Anki.app/Contents/MacOS/anki -b /Users/x/Anki"
printf '%s\n' "  300 /Applications/Anki.app/Contents/MacOS/anki /Applications/Anki.app/Contents/MacOS/anki -p Samilly Ribeiro -b /tmp/rehearsal-1"
[ -z "${PT_STRAY:-}" ] || printf '%s\n' "  $PT_STRAY"
A
cat > "$T/bin/gh" <<'A'
#!/usr/bin/env bash
echo "$*" >> "$PT_LOG"
case "$*" in
  *"repos/good/repo/labels"*) printf 'bug\nrehearsal\n' ;;
  *"repos/good/repo/contents"*) printf 'package.json\npnpm-lock.yaml\nsrc\n' ;;
  *"repos/nolabel/repo/labels"*) ;;
  *"repos/nolabel/repo/contents"*) printf 'package.json\npackage-lock.json\n' ;;
  *) exit 1 ;;
esac
A
chmod +x "$T"/bin/*
cred() { printf '{"claudeAiOauth":{"accessToken":"SECRET-TOKEN","refreshToken":"SECRET-REFRESH","expiresAt":%s}}\n' "$1" > "$T/cred.json"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2' want '$3')"; fail=1; fi; }
count() { printf '%s\n' "$1" | grep -c -- "$2"; }

cred $(( (NOW + 10 * 3600) * 1000 ))
out=$("$P" pc 2>&1); rc=$?
check pc-ok-exit "$rc" 0
check pc-three-passes "$(count "$out" '^[1-3]\. PASS')" 3
check pc-result "$(printf '%s\n' "$out" | tail -1)" "RESULT: PASS"
check no-secret "$(count "$out" 'SECRET')" 0

# Intermittent link: first two tries fail, the third answers.
: > "$T/ssh.count"; export PT_FAIL_FIRST=2
out=$("$P" pc 2>&1); rc=$?
check retry-recovers "$rc" 0
check retry-reports-try "$(count "$out" 'try 3 of 3')" 1
export PT_FAIL_FIRST=0; : > "$T/ssh.count"

# Link never answers: ssh is tried RETRIES times, everything host-bound fails, exit 1.
: > "$PT_LOG"
out=$(FM_PREWINDOW_PC_SSH=pcdown "$P" pc 2>&1); rc=$?
check down-exit "$rc" 1
check down-tries "$(wc -l < "$PT_LOG" | tr -d ' ')" 3
check down-all-fail "$(count "$out" '^[1-3]\. FAIL')" 3
check down-result "$(printf '%s\n' "$out" | tail -1)" "RESULT: FAIL (3 failed)"

# WSL keeper missing.
out=$(PT_KEEPER=0 "$P" pc 2>&1); rc=$?
check keeper-missing-exit "$rc" 1
check keeper-missing-line "$(count "$out" 'FAIL WSL keeper')" 1

# Login: expired and unreadable.
cred $(( (NOW + 3600) * 1000 ))
out=$("$P" pc 2>&1); rc=$?
check login-short-exit "$rc" 1
check login-short-line "$(count "$out" 'FAIL Claude login')" 1
check login-short-no-secret "$(count "$out" 'SECRET')" 0
rm -f "$T/cred.json"
out=$("$P" pc 2>&1); rc=$?
check login-absent "$(count "$out" 'FAIL Claude login: no readable expiresAt')" 1
cred $(( (NOW + 10 * 3600) * 1000 ))

# Repo readiness.
out=$("$P" pc --repo good/repo --label rehearsal 2>&1); rc=$?
check repo-ok-exit "$rc" 0
check repo-ok-lines "$(count "$out" '^[1-5]\. PASS')" 5
out=$("$P" pc --repo good/repo --label nope 2>&1); rc=$?
check repo-label-missing "$(count "$out" 'FAIL repo labels: missing: nope')" 1
out=$(FM_PREWINDOW_LABELS=bug,gone "$P" pc --repo good/repo 2>&1)
check repo-label-env "$(count "$out" 'FAIL repo labels: missing: gone')" 1
out=$("$P" pc --repo nolabel/repo 2>&1); rc=$?
check repo-bad-exit "$rc" 1
check repo-no-labels "$(count "$out" 'FAIL repo labels: nolabel/repo has no labels')" 1
check repo-no-pnpm "$(count "$out" 'FAIL pnpm project')" 1
out=$("$P" pc --repo gone/repo 2>&1)
check repo-gh-error "$(count "$out" 'FAIL repo labels: gh could not read')" 1
out=$("$P" pc 2>&1)
check repo-not-named-skips "$(count "$out" 'repo labels')" 0

# Mac: nothing stray, then a forgotten test Anki (listed, main Anki and Samilly profile excluded).
out=$("$P" mac 2>&1); rc=$?
check mac-ok-exit "$rc" 0
check mac-no-keeper-check "$(count "$out" 'WSL keeper')" 0
check mac-clean "$(count "$out" 'PASS stray test processes')" 1
out=$(PT_STRAY="999 /tmp/anki-test/anki /tmp/anki-test/anki --base /tmp/anki-test" "$P" mac 2>&1); rc=$?
check mac-stray-exit "$rc" 1
check mac-stray-listed "$(count "$out" 'FAIL stray test processes: 1 left running (not killed): 999 anki')" 1
check mac-stray-no-samilly "$(count "$out" 'Samilly')" 0
check mac-stray-no-300 "$(count "$out" ' 300 ')" 0
# Usage errors and help.
"$P" >/dev/null 2>&1; check no-host-exit "$?" 2
"$P" tablet >/dev/null 2>&1; check bad-host-exit "$?" 2
FM_PREWINDOW_MAC_SSH='' "$P" mac >/dev/null 2>&1; check mac-no-target-exit "$?" 1
out=$("$P" --help); check help-exit "$?" 0
check help-usage "$(count "$out" '^Usage: fm-prewindow-check.sh')" 1
exit "$fail"
