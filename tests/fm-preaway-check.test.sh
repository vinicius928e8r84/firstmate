#!/usr/bin/env bash
# Tests for bin/fm-preaway-check.sh with stand-in budget, capacity, ssh and credentials.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); P=$ROOT/bin/fm-preaway-check.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME=$T/home FM_SW_NO_NOTIFY=1 FM_HOME=$T PATH=$T/bin:$PATH
mkdir -p "$HOME" "$T/bin"
NOW=1793000000                                           # 04:33 in Fortaleza (UTC-3)
export FM_PREAWAY_NOW=$NOW FM_PREAWAY_GRACE_MIN=20 FM_PREAWAY_CREDENTIALS=$T/cred.json
export FM_PREAWAY_POD_BUDGET=$T/pod FM_PREAWAY_CAPACITY=$T/cap FM_PREAWAY_CLAUDE_BUDGET=$T/bud
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/$1"; chmod +x "$T/$1"; }
stub pod 'echo "balance=12.5 spend_per_hr=0 running=0"'
stub cap 'echo "capacity: free_lanes=3 reason=ok lanes=2 target=5"'
stub bud 'echo within_budget'
cat > "$T/bin/ssh" <<'A'
#!/usr/bin/env bash
case " $* " in *" macbad "*) exit 255 ;; esac
exit 0
A
chmod +x "$T/bin/ssh"
cred() { printf '{"claudeAiOauth":{"accessToken":"SECRET-TOKEN","expiresAt":%s}}\n' "$1" > "$T/cred.json"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2' want '$3')"; fail=1; fi; }

cred $(( (NOW + 10 * 3600) * 1000 ))
export FM_PREAWAY_PC_SSH=pcgood FM_PREAWAY_MAC_SSH=
out=$("$P"); rc=$?
check all-ok-exit "$rc" 0
check six-lines "$(printf '%s\n' "$out" | grep -c '^[1-6]\. ')" 6
check login-ok "$(printf '%s\n' "$out" | grep -c '^1\. OK Claude login')" 1
check mac-unknown "$(printf '%s\n' "$out" | grep -c '^5\. UNKNOWN Mac')" 1
check no-steps "$(printf '%s\n' "$out" | tail -1)" "None: nothing is MISSING."
check no-secret "$(printf '%s' "$out" | grep -c SECRET-TOKEN)" 0

cred $(( (NOW + 2 * 3600) * 1000 ))
stub pod 'echo "balance=-0.11 spend_per_hr=0 running=0"'
stub cap 'echo "capacity: free_lanes=0 reason=full lanes=5 target=5"'
stub bud 'echo above_budget'
export FM_PREAWAY_PC_SSH=macbad FM_PREAWAY_MAC_SSH=macbad
out=$("$P"); rc=$?
check missing-exit "$rc" 1
check six-missing "$(printf '%s\n' "$out" | grep -c '^[1-6]\. MISSING')" 6
steps=$(printf '%s\n' "$out" | sed -n '/^Steps that need/,$p')
check six-steps "$(printf '%s\n' "$steps" | grep -c '^- ')" 6
check deadline-fortaleza "$(printf '%s\n' "$steps" | grep -c 'até 04:53 (Fortaleza)')" 6   # 04:33 + 20 min
check no-secret-missing "$(printf '%s' "$out" | grep -c SECRET-TOKEN)" 0
exit "$fail"
