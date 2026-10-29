#!/usr/bin/env bash
# fm-usage-ledger-lib.sh - one append-only usage line per run, for scripts that keep no trail of their own.
#
# Source it and call, once per run, at the script's exit point:
#   fm_usage_record <script> <outcome> [pr] [kind]
# which appends one tab-separated line to $FM_HOME/data/usage-ledger.tsv
# (FM_USAGE_LEDGER overrides the path; a script that resolves its home into a variable
# other than FM_HOME sets FM_USAGE_HOME to it):
#   epoch, script, pr, kind, outcome
# Fields are single words or short phrases; a tab or newline in one becomes a space,
# and an empty one is written as "-". The ledger exists so that "did anyone use this
# script, and what happened" is a lookup (awk over one file) instead of a reconstruction
# from chat and git (data/numbers-1029/report.md, proposal 1).
#
# Recording is best effort and never changes the caller's exit status or output: it
# writes only when the ledger's directory already exists (a real home has data/; a
# disposable worktree does not, so a run there leaves nothing behind) and it ignores
# every write failure. FM_USAGE_LEDGER_OFF=1 turns it off.
#
# Read it with:  awk -F'\t' '$2 == "fm-pr-merge-main" { n[$5]++ } END { for (o in n) print o, n[o] }' data/usage-ledger.tsv

fm_usage_record() {  # <script> <outcome> [pr] [kind]
  [ -z "${FM_USAGE_LEDGER_OFF:-}" ] || return 0
  local ledger=${FM_USAGE_LEDGER:-}
  if [ -z "$ledger" ]; then
    local home=${FM_USAGE_HOME:-${FM_HOME:-${FM_ROOT_OVERRIDE:-${FM_ROOT:-}}}}
    [ -n "$home" ] || return 0
    ledger=$home/data/usage-ledger.tsv
  fi
  [ -d "${ledger%/*}" ] || return 0
  local f script=${1:-} outcome=${2:-} pr=${3:-} kind=${4:-}
  for f in script outcome pr kind; do
    local v=${!f}
    v=${v//$'\t'/ }
    v=${v//$'\n'/ }
    printf -v "$f" '%s' "${v:--}"
  done
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$script" "$pr" "$kind" "$outcome" >> "$ledger" 2>/dev/null || true
  return 0
}
