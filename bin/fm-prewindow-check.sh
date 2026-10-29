#!/usr/bin/env bash
# fm-prewindow-check.sh - read-only pass/fail checklist to run before a rehearsal window on the PC or the Mac.
# Pure shell: no model call, no sudo. It only reads: it never starts, signals or kills a process, never writes on the host,
# never prints a token or any other secret, and never touches the browser or Anki profile 'Samilly Ribeiro' or the main Anki.
# Usage: fm-prewindow-check.sh <pc|mac> [--ssh <target>] [--repo <owner/name>] [--label <name>]... [-h|--help]
#   --ssh     ssh destination (words are split, so `-p 2222 user@host` works); overrides FM_PREWINDOW_PC_SSH / FM_PREWINDOW_MAC_SSH
#   --repo    also check that GitHub repo's readiness (needs gh)
#   --label   a label the repo must have (repeatable; also FM_PREWINDOW_LABELS, comma separated)
# Output: one `N. PASS|FAIL <what>: <detail>` line per check, then `RESULT: PASS` or `RESULT: FAIL (<n> failed)`.
# Checks:
#   ssh reachability  `ssh <target> true`, FM_PREWINDOW_RETRIES attempts (default 4) FM_PREWINDOW_RETRY_SLEEP seconds apart (5),
#                     because the PC link is intermittent. The checks below that need the host FAIL as "host unreachable" when this fails.
#   WSL keeper (pc)   a process whose command line matches the pgrep -f pattern FM_PREWINDOW_WSL_KEEPER (default `sleep infinity`)
#                     is running on the PC, which is what keeps WSL from shutting down. Prints its pid only.
#   Claude login      the host's credentials file (FM_PREWINDOW_CREDENTIALS, default ~/.claude/.credentials.json on the host) has an
#                     expiresAt at least FM_PREWINDOW_LOGIN_MIN_HOURS (6) away. Only the expiry number leaves the host, never a token;
#                     a host that keeps the login elsewhere (a macOS keychain) fails as "no readable expiresAt".
#   repo readiness    with --repo: `gh api` shows the repo has at least one label (and every --label one) and a pnpm project at its root
#                     (package.json plus pnpm-lock.yaml or pnpm-workspace.yaml).
#   stray processes   (mac) lists, never kills, processes whose command line matches the egrep pattern FM_PREWINDOW_STRAY_PATTERN
#                     (default `anki-test|rehearsal`); any match fails. Command lines naming 'Samilly' are never listed, and the main Anki
#                     does not match the default. Only pid and process name are printed.
# Env: FM_PREWINDOW_PC_SSH (default pc-aux) FM_PREWINDOW_MAC_SSH (no default) FM_PREWINDOW_SSH_TIMEOUT (10, per ssh try)
#   FM_PREWINDOW_NOW (epoch, tests) FM_PREWINDOW_GH_TIMEOUT (20)
# Exit: 0 every check passed, 1 at least one failed, 2 usage error.
set -uo pipefail

usage() { sed -n '2,/^# Exit:/s/^# \{0,1\}//p' "$0"; }

HOST=""; TARGET_OVERRIDE=""; REPO=""
LABELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --ssh) [ $# -ge 2 ] || { echo "fm-prewindow-check: --ssh needs a value" >&2; exit 2; }; TARGET_OVERRIDE=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || { echo "fm-prewindow-check: --repo needs a value" >&2; exit 2; }; REPO=$2; shift 2 ;;
    --label) [ $# -ge 2 ] || { echo "fm-prewindow-check: --label needs a value" >&2; exit 2; }; LABELS+=("$2"); shift 2 ;;
    pc|mac) [ -z "$HOST" ] || { echo "fm-prewindow-check: one host only" >&2; exit 2; }; HOST=$1; shift ;;
    *) echo "fm-prewindow-check: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done
[ -n "$HOST" ] || { echo "fm-prewindow-check: say pc or mac (try --help)" >&2; exit 2; }
if [ -n "$REPO" ]; then
  case "$REPO" in */*) ;; *) echo "fm-prewindow-check: --repo wants owner/name" >&2; exit 2 ;; esac
fi
if [ -n "${FM_PREWINDOW_LABELS:-}" ]; then
  IFS=',' read -r -a extra <<<"$FM_PREWINDOW_LABELS"
  LABELS+=("${extra[@]}")
fi

case "$HOST" in
  pc) TARGET=${TARGET_OVERRIDE:-${FM_PREWINDOW_PC_SSH-pc-aux}} ;;
  mac) TARGET=${TARGET_OVERRIDE:-${FM_PREWINDOW_MAC_SSH-}} ;;
esac
NOW=${FM_PREWINDOW_NOW:-$(date +%s)}
SSH_T=${FM_PREWINDOW_SSH_TIMEOUT:-10}
RETRIES=${FM_PREWINDOW_RETRIES:-4}
RETRY_SLEEP=${FM_PREWINDOW_RETRY_SLEEP:-5}
GH_T=${FM_PREWINDOW_GH_TIMEOUT:-20}
LOGIN_MIN_H=${FM_PREWINDOW_LOGIN_MIN_HOURS:-6}
KEEPER=${FM_PREWINDOW_WSL_KEEPER:-sleep infinity}
STRAY=${FM_PREWINDOW_STRAY_PATTERN:-anki-test|rehearsal}
CRED=${FM_PREWINDOW_CREDENTIALS:-}

N=0; FAILED=0
line() { # PASS|FAIL what detail
  N=$((N + 1)); printf '%d. %s %s: %s\n' "$N" "$1" "$2" "$3"
  [ "$1" = PASS ] || FAILED=$((FAILED + 1))
}
# Run a script on the host over stdin so a pattern never shows up in the remote command line it is matched against.
rsh() { # script
  # shellcheck disable=SC2086
  timeout "$SSH_T" ssh -o BatchMode=yes -o ConnectTimeout="$SSH_T" $TARGET bash -s <<<"$1" 2>/dev/null
}

# 1. ssh reachability, with retries.
UP=0
if [ -z "$TARGET" ]; then
  line FAIL "ssh reachability" "no ssh target; set FM_PREWINDOW_$(printf '%s' "$HOST" | tr '[:lower:]' '[:upper:]')_SSH or pass --ssh"
else
  tries=0
  while [ "$tries" -lt "$RETRIES" ]; do
    tries=$((tries + 1))
    if rsh true >/dev/null; then UP=1; break; fi
    [ "$tries" -lt "$RETRIES" ] && sleep "$RETRY_SLEEP"
  done
  if [ "$UP" = 1 ]; then
    line PASS "ssh reachability" "$HOST answers (try $tries of $RETRIES)"
  else
    line FAIL "ssh reachability" "$HOST did not answer in $RETRIES tries"
  fi
fi
down() { line FAIL "$1" "host unreachable"; }

# 2. The process that keeps WSL up (PC only).
if [ "$HOST" = pc ]; then
  if [ "$UP" != 1 ]; then down "WSL keeper"
  else
    pid=$(rsh "pat=$(printf '%q' "$KEEPER"); pgrep -f -- \"\$pat\" | head -1" | tr -cd '0-9')
    if [ -n "$pid" ]; then line PASS "WSL keeper" "process matching '$KEEPER' is running (pid $pid)"
    else line FAIL "WSL keeper" "no process matching '$KEEPER'; WSL may shut down"; fi
  fi
fi

# 3. Claude login: the expiry number only.
if [ "$UP" != 1 ]; then down "Claude login"
else
  exp=$(rsh "cred=$(printf '%q' "$CRED"); [ -n \"\$cred\" ] || cred=\$HOME/.claude/.credentials.json; tr -d ' \\n' < \"\$cred\" 2>/dev/null | grep -o '\"expiresAt\":[0-9]*' | head -1 | cut -d: -f2" | tr -cd '0-9')
  if [ -z "$exp" ]; then
    line FAIL "Claude login" "no readable expiresAt on $HOST"
  else
    left=$(( exp / 1000 - NOW ))
    if [ "$left" -ge $((LOGIN_MIN_H * 3600)) ]; then
      line PASS "Claude login" "valid for $((left / 3600)) h more"
    else
      line FAIL "Claude login" "expires in $((left / 3600)) h (need ${LOGIN_MIN_H} h); log in again"
    fi
  fi
fi

# 4. Test repo readiness (only when named).
if [ -n "$REPO" ]; then
  have=$(timeout "$GH_T" gh api "repos/$REPO/labels" --paginate --jq '.[].name' </dev/null 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then
    line FAIL "repo labels" "gh could not read labels of $REPO"
  else
    missing=()
    for l in "${LABELS[@]}"; do
      [ -n "$l" ] || continue
      printf '%s\n' "$have" | grep -Fxq -- "$l" || missing+=("$l")
    done
    if [ -z "$have" ]; then line FAIL "repo labels" "$REPO has no labels"
    elif [ "${#missing[@]}" -gt 0 ]; then line FAIL "repo labels" "missing: ${missing[*]}"
    else line PASS "repo labels" "$(printf '%s\n' "$have" | grep -c .) labels present"; fi
  fi
  root=$(timeout "$GH_T" gh api "repos/$REPO/contents" --jq '.[].name' </dev/null 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then
    line FAIL "pnpm project" "gh could not read the root of $REPO"
  elif printf '%s\n' "$root" | grep -Fxq package.json \
    && { printf '%s\n' "$root" | grep -Fxq pnpm-lock.yaml || printf '%s\n' "$root" | grep -Fxq pnpm-workspace.yaml; }; then
    line PASS "pnpm project" "package.json with a pnpm lock or workspace at the root"
  else
    line FAIL "pnpm project" "root of $REPO lacks package.json plus pnpm-lock.yaml or pnpm-workspace.yaml"
  fi
fi

# 5. Forgotten test processes on the Mac: list only.
if [ "$HOST" = mac ]; then
  if [ "$UP" != 1 ]; then down "stray test processes"
  else
    # ps is snapshotted before grep runs, so the pattern never matches its own process.
    found=$(rsh "pat=$(printf '%q' "$STRAY"); snap=\$(ps -axo pid=,comm=,args= 2>/dev/null); printf '%s\\n' \"\$snap\" | grep -E -- \"\$pat\" | grep -v Samilly | awk '{ n = split(\$2, p, \"/\"); print \$1, p[n] }'")
    if [ -z "$found" ]; then
      line PASS "stray test processes" "none matching '$STRAY'"
    else
      line FAIL "stray test processes" "$(printf '%s\n' "$found" | grep -c .) left running (not killed): $(printf '%s' "$found" | tr '\n' ';')"
    fi
  fi
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL ($FAILED failed)"
exit 1
