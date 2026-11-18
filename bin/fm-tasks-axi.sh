#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/fm-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
#
# Duplicate warning: `add` (or `create`) first compares the new title, as a set
# of lowercase words, with every delivered task - the live Done rows and the
# markdown archive beside the backlog - and prints one stderr line per delivered
# task whose title overlaps at least FM_TASKS_DUP_THRESHOLD percent (default 60,
# Jaccard) naming its id and title. The add still proceeds: a warning, never a
# refusal, so the captain decides and nothing legitimate is blocked. Set
# FM_TASKS_DUP_CHECK=0 to skip the comparison.
#
# Otherwise the exit status is tasks-axi's own, unless decoding a read fails;
# in that case the decoder's nonzero status is returned.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

# Warn (stderr only) when a new title overlaps a delivered task's title.
fm_tasks_dup_warn() {  # <args of the add command...>
  local title='' skip=0 a pos=() archive live
  [ "${FM_TASKS_DUP_CHECK:-1}" != 0 ] || return 0
  shift
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
      --kind|--repo|--body|--body-file|--blocked-by|--pr|--report|--priority|--prefix) skip=1 ;;
      --*) ;;
      *) pos+=("$a") ;;
    esac
  done
  [ "${#pos[@]}" -gt 0 ] || return 0
  title=${pos[${#pos[@]}-1]}
  [ "${#pos[@]}" -ge 2 ] || case " $* " in *" --mint "*) ;; *) return 0 ;; esac
  if [ -n "${FM_BACKLOG_AXI_FILE:-}" ]; then
    archive="$(dirname "$FM_BACKLOG_AXI_FILE")/done-archive.md"
  else
    archive="$DATA/done-archive.md"
  fi
  live=$(tasks-axi list --state "done" --limit 1000 2>/dev/null || true)
  {
    printf '%s\n' "$live" | awk -F, '/^  [^ ]/ && NF >= 5 { id=$1; sub(/^ +/, "", id); t=$5; for (i=6;i<=NF;i++) t=t "," $i; print id "\t" t }'
    [ -r "$archive" ] && awk '/^- \[x\] / { l=substr($0,7); i=index(l," - "); if (i>0) { id=substr(l,1,i-1); t=substr(l,i+3); sub(/ \(.*$/, "", t); print id "\t" t } }' "$archive"
  } | awk -F'\t' -v q="$title" -v th="${FM_TASKS_DUP_THRESHOLD:-60}" '
    function toks(s, arr,   n, i, w, parts) {
      s = tolower(s); gsub(/[^a-z0-9]+/, " ", s); n = split(s, parts, " ")
      for (i = 1; i <= n; i++) { w = parts[i]; if (length(w) >= 2 || w ~ /^[0-9]$/) arr[w] = 1 }
    }
    function size(arr,   k, c) { c = 0; for (k in arr) c++; return c }
    BEGIN { toks(q, Q); nq = size(Q) }
    {
      delete R; toks($2, R); nr = size(R)
      inter = 0; for (k in Q) if (k in R) inter++
      un = nq + nr - inter
      if (un > 0 && inter * 100 >= th * un && !($1 in seen)) {
        seen[$1] = 1
        printf "fm-tasks-axi: warning: possible duplicate of delivered task %s - \"%s\" - overlaps the new title; confirm with the captain before dispatching (the add proceeded)\n", $1, $2 > "/dev/stderr"
      }
    }'
  return 0
}

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
case "${1:-}" in
  add|create)
    fm_tasks_dup_warn "$@"
    ;;
esac
case "${1:-}" in
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
