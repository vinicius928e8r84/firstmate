#!/usr/bin/env bash
# fm-actions.sh - actions ledger with proof: every item an audit or retro asks for gets an owner and a command that
# proves it, so the next audit reads the ledger instead of rereading chat.
# Usage: fm-actions.sh add --id <id> --source <audit/date> --owner <who> --proof '<command>'
#        fm-actions.sh prove [<id>|--all]     run the stored proof command(s), record the result and state
#        fm-actions.sh list [<state>]         print the ledger (state: pending|done|not-done|no-proof)
#        fm-actions.sh report                 counts plus one line per item; reads the ledger, runs nothing
# Ledger: <data>/actions.tsv (data = FM_DATA_OVERRIDE or $FM_HOME/data), tab separated, header row, empty cells are "-":
#   id  source  owner  proof  last_result  state  proved_at(epoch)
# Proof is one shell line that exits 0 when the item is done AND in use. `prove` runs it with `bash -c` from FM_HOME,
# stdin closed, under a hard bound (FM_ACTIONS_PROOF_TIMEOUT, default 30 s). State: pending (never proved), done (exit 0),
# not-done (non-zero or timeout), no-proof (the item has no proof command: shown first in report so a proof gets written).
# Read-only is enforced as far as a shell line can be: `add` and `prove` refuse a proof that writes (redirect other than
# /dev/null, rm/mv/cp/tee/sed -i, git push/commit/checkout/reset/merge/rebase/fetch/pull/clean/stash, kill, crontab -r/-e,
# curl -X/-d, gh -X/--method) or that touches a protected surface (RunPod, AdsPower, Opera, Anki, the PC: ssh/scp/powershell/.exe).
# Prefer git cat-file/merge-base, grep -q, test -x, crontab -l and `gh api` GETs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$DATA/actions.tsv"
HEADER=$(printf 'id\tsource\towner\tproof\tlast_result\tstate\tproved_at')
PROOF_TIMEOUT="${FM_ACTIONS_PROOF_TIMEOUT:-30}"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

clean_field() {  # <value> -> value with tabs/newlines flattened, "-" when empty
  local v
  v=$(printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/^ *//; s/ *$//')
  printf '%s' "${v:--}"
}

# 0 when the proof line is allowed; otherwise prints why on stdout and returns 1.
proof_refusal() {  # <proof>
  local p=$1 stripped
  stripped=$(printf '%s' "$p" | sed -E 's/[0-9]?>>?[[:space:]]*\/dev\/null//g; s/[0-9]>&[0-9]//g')
  if printf '%s' "$p" | grep -Eiq 'runpod|adspower|opera|anki|powershell|\.exe|(^|[[:space:];&|(])(ssh|scp|rsync)[[:space:]]'; then
    echo "touches a protected surface (RunPod, AdsPower, Opera, Anki, the PC)"; return 1
  fi
  if printf '%s' "$stripped" | grep -Eq '>'; then
    echo "contains a redirect that writes"; return 1
  fi
  if printf '%s' "$stripped" | grep -Eq '(^|[[:space:];&|(])(rm|mv|cp|tee|kill|pkill|dd|truncate|chmod|chown|systemctl|touch|mkdir)[[:space:]]|sed[[:space:]]+(-[a-zA-Z]*i)|git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(push|commit|checkout|reset|merge|rebase|fetch|pull|clean|stash|add|branch|tag)([[:space:]]|$)|crontab[[:space:]]+-[re]|curl[[:space:]].*(-X|-d|--data)|gh[[:space:]].*(-X|--method|-f[[:space:]]|-F[[:space:]])'; then
    echo "is not read-only"; return 1
  fi
  return 0
}

ensure_ledger() {
  mkdir -p "$DATA" || die "cannot create $DATA"
  [ -f "$LEDGER" ] || printf '%s\n' "$HEADER" > "$LEDGER" || die "cannot create $LEDGER"
}

ledger_has() {  # <id>
  awk -F'\t' -v id="$1" 'NR > 1 && $1 == id { found = 1 } END { exit !found }' "$LEDGER"
}

ledger_row() {  # <id> -> the row
  awk -F'\t' -v id="$1" 'NR > 1 && $1 == id { print; exit }' "$LEDGER"
}

ledger_update() {  # <id> <last_result> <state> <epoch>
  local tmp
  tmp=$(mktemp "$LEDGER.XXXXXX") || die "cannot write beside $LEDGER"
  awk -F'\t' -v OFS='\t' -v id="$1" -v res="$2" -v st="$3" -v at="$4" \
    'NR > 1 && $1 == id { $5 = res; $6 = st; $7 = at } { print }' "$LEDGER" > "$tmp" || { rm -f "$tmp"; die "update failed"; }
  mv -f "$tmp" "$LEDGER"
}

cmd_add() {
  local id='' source='' owner='' proof='' why
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) [ $# -ge 2 ] || die "--id needs a value"; id=$2; shift 2 ;;
      --source) [ $# -ge 2 ] || die "--source needs a value"; source=$2; shift 2 ;;
      --owner) [ $# -ge 2 ] || die "--owner needs a value"; owner=$2; shift 2 ;;
      --proof) [ $# -ge 2 ] || die "--proof needs a value"; proof=$2; shift 2 ;;
      *) die "unknown add option $1" ;;
    esac
  done
  case "$id" in ''|*[!A-Za-z0-9._-]*) die "--id must be non-empty letters, digits, . _ -" ;; esac
  [ -n "$source" ] || die "--source is required"
  [ -n "$owner" ] || die "--owner is required"
  if [ -n "$proof" ]; then
    why=$(proof_refusal "$proof") || die "proof for $id refused: $why"
  fi
  ensure_ledger
  ledger_has "$id" && die "item $id already exists"
  proof=$(clean_field "$proof")
  printf '%s\t%s\t%s\t%s\t-\t%s\t-\n' "$id" "$(clean_field "$source")" "$(clean_field "$owner")" "$proof" \
    "$([ "$proof" = - ] && echo no-proof || echo pending)" >> "$LEDGER" || die "append failed"
  echo "added $id"
}

prove_one() {  # <id>
  local row id proof rc result state why
  row=$(ledger_row "$1")
  [ -n "$row" ] || die "no such item $1"
  id=$1
  proof=$(printf '%s' "$row" | awk -F'\t' '{ print $4 }')
  if [ "$proof" = - ]; then
    ledger_update "$id" no-proof no-proof "$(date +%s)"
    echo "$id: no-proof"
    return 0
  fi
  if ! why=$(proof_refusal "$proof"); then
    ledger_update "$id" "refused: $why" not-done "$(date +%s)"
    echo "$id: REFUSED ($why)"
    return 0
  fi
  rc=0
  ( cd "$FM_HOME" 2>/dev/null && fm_run_timed "$PROOF_TIMEOUT" bash -c "$proof" </dev/null >/dev/null 2>&1 ) || rc=$?
  case "$rc" in
    0) result=PASS; state="done" ;;
    124) result="TIMEOUT(${PROOF_TIMEOUT}s)"; state=not-done ;;
    *) result="FAIL(exit $rc)"; state=not-done ;;
  esac
  ledger_update "$id" "$result" "$state" "$(date +%s)"
  echo "$id: $result"
}

cmd_prove() {
  local target=${1:---all} id
  ensure_ledger
  if [ "$target" = --all ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      prove_one "$id"
    done <<EOF
$(awk -F'\t' 'NR > 1 { print $1 }' "$LEDGER")
EOF
  else
    prove_one "$target"
  fi
}

cmd_list() {
  local want=${1:-}
  ensure_ledger
  case "$want" in ''|pending|done|not-done|no-proof) ;; *) die "unknown state $want" ;; esac
  awk -F'\t' -v want="$want" 'NR == 1 || want == "" || $6 == want { print }' "$LEDGER"
}

cmd_report() {
  ensure_ledger
  awk -F'\t' '
    NR == 1 { next }
    { n[$6]++; total++; rows[$6] = rows[$6] sprintf("%s\t%s\t%s\t%s\t%s\n", label($6), $1, $3, $2, $5) }
    function label(s) { return s == "done" ? "FEITO" : s == "not-done" ? "NAO" : s == "no-proof" ? "SEM-PROVA" : "SEM-RODADA" }
    END {
      printf "ACTIONS total=%d done=%d not-done=%d no-proof=%d pending=%d\n", total, n["done"], n["not-done"], n["no-proof"], n["pending"]
      printf "%s", rows["no-proof"]; printf "%s", rows["pending"]; printf "%s", rows["not-done"]; printf "%s", rows["done"]
    }' "$LEDGER"
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  prove) shift; cmd_prove "$@" ;;
  list) shift; cmd_list "$@" ;;
  report) cmd_report ;;
  -h|--help|'') usage ;;
  *) die "unknown command $1 (add|prove|list|report)" ;;
esac
