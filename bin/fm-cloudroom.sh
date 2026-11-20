#!/usr/bin/env bash
# fm-cloudroom.sh - run firstmate crewmates as Cloudroom cloud threads.
#
# Cloudroom (https://cloudroom.dev) gives every child thread its own cloud
# sandbox and branch, so a Cloudroom crewmate needs neither a terminal backend
# nor a Treehouse worktree. This helper is the shell-callable bridge the
# docs/codex-app-backend.md acceptance contract asks for, built on `room-cli`:
#
#   create  room-cli thread spawn   -> durable thread id in state/<id>.meta
#   send    room-cli thread tell
#   read    room-cli thread show / output / log
#   archive room-cli thread stop / archive
#   return  sync: the worker ends every reply with firstmate status lines;
#           `sync` copies new ones into state/<id>.status, where the watcher
#           and every status reader already look.
#
# A child cannot write this home's files (it runs in another sandbox), so the
# status return channel is parent-side: Cloudroom messages the primary when a
# child finishes a turn, and the primary runs `sync` (or `sync --all`).
#
# Usage:
#   fm-cloudroom.sh doctor
#   fm-cloudroom.sh spawn <id> --repo <git-url|owner/name> --task-file <file>
#                   [--kind ship|scout] [--provider P] [--model M] [--effort E]
#                   [--branch-prefix fm/] [--shared-sandbox]
#   fm-cloudroom.sh sync [<id>|--all]       append new status lines; print them
#   fm-cloudroom.sh peek <id> [--log]       thread state + last reply (or full log)
#   fm-cloudroom.sh send <id> <text>        steer the worker (queued if busy)
#   fm-cloudroom.sh stop <id>               interrupt the current turn
#   fm-cloudroom.sh close <id> [--force]    archive; refuses unless done/failed
#   fm-cloudroom.sh list                    one line per Cloudroom task
#
# Env: FM_HOME (default: repo root), FM_STATE_OVERRIDE, FM_DATA_OVERRIDE,
#      FM_ROOM_CLI (default: room-cli), ROOM_PROJECT_ID.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ROOM="${FM_ROOM_CLI:-room-cli}"
STATUS_RE='^(working|needs-decision|blocked|paused|done|failed|resolved)( \[[^]]*\])?: '

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -eu/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit "${1:-0}"; }

need_jq() { command -v jq >/dev/null 2>&1 || die "jq is required"; }
need_room() {
  command -v "$ROOM" >/dev/null 2>&1 || die "room-cli not found; run firstmate inside a Cloudroom cloud thread (docs/cloudroom-backend.md)"
}
valid_id() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,47}$' || die "invalid task id '$1' (lowercase letters, digits, dashes)"; }
meta_of() { printf '%s/%s.meta' "$STATE" "$1"; }
meta_get() { [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | tail -n 1 || true; }

thread_of() {  # <id> -> thread id; dies unless this is a Cloudroom task
  local meta; meta=$(meta_of "$1")
  [ -f "$meta" ] || die "no task '$1' in $STATE"
  [ "$(meta_get "$meta" backend)" = cloudroom ] || die "task '$1' is not a Cloudroom task"
  local thr; thr=$(meta_get "$meta" cloudroom_thread_id)
  [ -n "$thr" ] || die "task '$1' has no cloudroom_thread_id"
  printf '%s' "$thr"
}

cloud_tasks() {  # ids of every Cloudroom task in this home
  local m
  for m in "$STATE"/*.meta; do
    [ -f "$m" ] || continue
    [ "$(meta_get "$m" backend)" = cloudroom ] || continue
    m=${m##*/}; printf '%s\n' "${m%.meta}"
  done
}

worker_prompt() {  # <id> <kind> <repo> <branch> <task-file>
  local id=$1 kind=$2 repo=$3 branch=$4 task=$5 deliver
  if [ "$kind" = scout ]; then
    deliver="This is a SCOUT task: the deliverable is a written report, not a PR.
Never push and never open a PR. Put the full standalone report (what you did, evidence, file:line references, recommendation) in your final reply, above the status line."
  else
    deliver="This is a SHIP task delivered as a pull request.
Work on branch \`$branch\`. Commit, push that branch, and open one PR with \`gh pr create\`. Never push to the default branch and never merge.
Before done: run the project's own tests/lint for what you changed and make sure they pass."
  fi
  cat <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate (task id: $id).
Work on your own; do not wait for a human. You run in your own Cloudroom cloud sandbox.

# Task
$(cat "$task")

# Setup
Repository: $repo
Clone it fresh into \`\$HOME/fm-$id\` (\`gh repo clone $repo \$HOME/fm-$id\`), cd into it, and work only there. Ignore any copy already under /code: it is a stale snapshot without git history. Install only what the task needs.
$deliver

# Status reporting (mandatory)
You cannot write firstmate's status file. Instead, END EVERY REPLY with one or more status lines, each on its own line, in exactly this form:
  <state> [at=<epoch>]: <one-line note>
States: working, needs-decision, blocked, paused, done, failed, resolved. Get <epoch> from \`date +%s\`.
- Finished: \`done [at=<epoch>]: <conclusion>\` (ship: include the full https:// PR URL).
- A human decision is needed (product choice, destructive action): \`needs-decision [at=<epoch>]: <options>\` and end your turn. The answer arrives as your next message.
- Same obstacle twice: \`blocked [at=<epoch>]: <why>\` and end your turn.
- When a blocker or decision clears, start that reply's status with \`resolved [at=<epoch>]: <how>\`.
Never end a reply without a status line.

# Rules
1. Stay in your sandbox and the repository above. Never touch other repositories.
2. Never commit secrets. Never force-push.
3. Do not start other agents or subagents.
EOF
}

cmd_doctor() {
  local ok=1
  command -v jq >/dev/null 2>&1 && echo "ok: jq" || { echo "missing: jq"; ok=0; }
  if command -v "$ROOM" >/dev/null 2>&1; then
    echo "ok: room-cli ($(command -v "$ROOM"))"
    if "$ROOM" status >/dev/null 2>&1; then echo "ok: room-cli status reachable"; else echo "fail: room-cli status"; ok=0; fi
  else
    echo "missing: room-cli (run inside a Cloudroom cloud thread)"; ok=0
  fi
  [ -n "${ROOM_THREAD_ID:-}" ] && echo "ok: ROOM_THREAD_ID=$ROOM_THREAD_ID" || echo "warn: ROOM_THREAD_ID unset (spawn still works; children attach to this thread)"
  [ -n "${ROOM_PROJECT_ID:-}" ] && echo "ok: ROOM_PROJECT_ID=$ROOM_PROJECT_ID" || echo "warn: ROOM_PROJECT_ID unset"
  [ "$ok" = 1 ]
}

cmd_spawn() {
  local id=${1:-}; [ -n "$id" ] || usage 2; shift
  valid_id "$id"
  local repo='' task='' kind=ship provider=claude-code model='' effort='' prefix=fm/ shared=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo=$2; shift 2 ;;
      --task-file) task=$2; shift 2 ;;
      --kind) kind=$2; shift 2 ;;
      --provider) provider=$2; shift 2 ;;
      --model) model=$2; shift 2 ;;
      --effort) effort=$2; shift 2 ;;
      --branch-prefix) prefix=$2; shift 2 ;;
      --shared-sandbox) shared=1; shift ;;
      *) die "unknown spawn option '$1'" ;;
    esac
  done
  [ -n "$repo" ] || die "spawn needs --repo"
  [ -n "$task" ] && [ -s "$task" ] || die "spawn needs a non-empty --task-file"
  case "$kind" in ship|scout) ;; *) die "--kind must be ship or scout" ;; esac
  need_jq; need_room
  mkdir -p "$STATE" "$DATA/$id"
  local meta; meta=$(meta_of "$id")
  [ ! -e "$meta" ] || die "task '$id' already exists ($meta)"

  local branch="${prefix}${id}" prompt_file="$DATA/$id/cloudroom-prompt.md"
  worker_prompt "$id" "$kind" "$repo" "$branch" "$task" > "$prompt_file"

  local -a args=(thread spawn --provider "$provider" --title "fm-$id" --prompt-file "$prompt_file")
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$effort" ] && args+=(--reasoning-level "$effort")
  [ "$shared" = 1 ] && args+=(--shared-sandbox)

  local out thr
  out=$("$ROOM" "${args[@]}" 2>&1) || die "room-cli spawn failed: $out"
  thr=$(printf '%s\n' "$out" | grep -E '^\{' | tail -n 1 | jq -r '.id // empty' 2>/dev/null || true)
  [ -n "$thr" ] || die "room-cli spawn returned no thread id: $out"

  {
    echo "backend=cloudroom"
    echo "window=$thr"
    echo "cloudroom_thread_id=$thr"
    echo "kind=$kind"
    echo "project=$repo"
    echo "branch=$branch"
    echo "harness=$provider"
    [ -n "$model" ] && echo "model=$model"
    [ -n "$effort" ] && echo "effort=$effort"
    echo "spawned_at=$(date +%s)"
  } > "$meta"
  printf 'working [at=%s]: dispatched to Cloudroom thread %s\n' "$(date +%s)" "$thr" >> "$STATE/$id.status"
  echo "spawned: $id -> $thr (branch $branch, $provider${model:+/$model})"
}

sync_one() {  # <id>: append status lines from the newest reply, once per reply
  local id=$1 thr out reply state hash seen lines
  thr=$(thread_of "$id")
  out=$("$ROOM" thread output "$thr" 2>/dev/null) || { echo "$id: unreadable (room-cli thread output failed)" >&2; return 1; }
  state=$(printf '%s' "$out" | jq -r '.state // "unknown"')
  reply=$(printf '%s' "$out" | jq -r '.reply // ""')
  [ -n "$reply" ] || { echo "$id: $state (no reply yet)"; return 0; }
  hash=$(printf '%s' "$reply" | cksum | cut -d' ' -f1)
  seen="$STATE/$id.cloudroom-seen"
  if [ -f "$seen" ] && grep -qx "$hash" "$seen"; then
    echo "$id: $state (no new reply)"; return 0
  fi
  lines=$(printf '%s\n' "$reply" | sed 's/^[[:space:]]*//' | grep -E "$STATUS_RE" || true)
  if [ -z "$lines" ] && [ "$state" != working ]; then
    lines="blocked [at=$(date +%s)]: worker ended a turn without a status line; read it with fm-cloudroom.sh peek $id"
  fi
  if [ -n "$lines" ]; then
    printf '%s\n' "$lines" >> "$STATE/$id.status"
    printf '%s\n' "$lines" | sed "s/^/$id: /"
  fi
  if [ "$(meta_get "$(meta_of "$id")" kind)" = scout ] && printf '%s\n' "$lines" | grep -q '^done'; then
    mkdir -p "$DATA/$id"
    printf '%s\n' "$reply" > "$DATA/$id/report.md"
    echo "$id: report saved to $DATA/$id/report.md"
  fi
  # Only a finished turn is final; a mid-turn reply may still grow.
  [ "$state" = working ] || echo "$hash" >> "$seen"
}

cmd_sync() {
  need_jq; need_room
  local target=${1:---all} id rc=0
  if [ "$target" = --all ]; then
    for id in $(cloud_tasks); do sync_one "$id" || rc=1; done
  else
    sync_one "$target" || rc=1
  fi
  return "$rc"
}

cmd_peek() {
  need_jq; need_room
  local id=${1:-}; [ -n "$id" ] || usage 2
  local thr; thr=$(thread_of "$id")
  "$ROOM" thread show "$thr" | jq -r '"thread: \(.id)  state: \(.state)  status: \(.status)  title: \(.title)"'
  if [ "${2:-}" = --log ]; then
    "$ROOM" thread log "$thr" | jq -r '.messages[] | "[\(.role)] \(.text)"'
  else
    "$ROOM" thread output "$thr" | jq -r '.reply // "(no reply yet)"'
  fi
}

cmd_send() {
  need_room
  local id=${1:-}; [ $# -ge 2 ] || usage 2; shift
  local thr; thr=$(thread_of "$id")
  "$ROOM" thread tell "$thr" "$*"
}

cmd_stop() {
  need_room
  local thr; thr=$(thread_of "${1:-}")
  "$ROOM" thread stop "$thr"
}

cmd_close() {
  need_room
  local id=${1:-} force=${2:-}; [ -n "$id" ] || usage 2
  local thr last; thr=$(thread_of "$id")
  last=$(grep -E "$STATUS_RE" "$STATE/$id.status" 2>/dev/null | tail -n 1 || true)
  case "$last" in
    done*|failed*) ;;
    *) [ "$force" = --force ] || die "task '$id' is not done or failed (last: ${last:-none}); pass --force to archive anyway" ;;
  esac
  "$ROOM" thread archive "$thr" >/dev/null
  mkdir -p "$STATE/closed"
  mv "$(meta_of "$id")" "$STATE/closed/$id.meta"
  [ -f "$STATE/$id.status" ] && mv "$STATE/$id.status" "$STATE/closed/$id.status"
  rm -f "$STATE/$id.cloudroom-seen"
  echo "closed: $id ($thr archived)"
}

cmd_list() {
  local id meta last
  for id in $(cloud_tasks); do
    meta=$(meta_of "$id")
    last=$(grep -E "$STATUS_RE" "$STATE/$id.status" 2>/dev/null | tail -n 1 || true)
    printf '%s\t%s\t%s\t%s\n' "$id" "$(meta_get "$meta" cloudroom_thread_id)" "$(meta_get "$meta" kind)" "${last:-no status}"
  done
}

sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
  doctor) cmd_doctor ;;
  spawn) cmd_spawn "$@" ;;
  sync) cmd_sync "$@" ;;
  peek) cmd_peek "$@" ;;
  send) cmd_send "$@" ;;
  stop) cmd_stop "$@" ;;
  close) cmd_close "$@" ;;
  list) cmd_list ;;
  -h|--help|help) usage 0 ;;
  *) usage 2 ;;
esac
