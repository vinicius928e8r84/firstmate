#!/usr/bin/env bash
# fm-lane-guard.sh - mechanical guards for the worker-creation lane and the pod job queue (daily speed audits
# 2026-10-27 item 7 and 2026-10-28 item 2). Pure shell: no model call, never wakes an agent by itself.
# Usage: fm-lane-guard.sh scan [slot|spawn|pod]      (default: all three; prints one line per NEW alert)
#        fm-lane-guard.sh record-spawn-failure <task-id> <exit-code> [kind] [project] [backend] [harness]
# Guards:
#   slot   a `treehouse get` slot request that holds no slot yet - no child subshell - and is older than
#          FM_SLOT_REQUEST_MAX_SEC (3600) is ended by its EXACT pid (SIGTERM then SIGCONT, since a request stopped on
#          its tty never handles a queued TERM; SIGKILL only if it survives FM_SLOT_REQUEST_GRACE_SEC, 5). A request
#          with a subshell is a live worker lease and is never touched. The pid, argv, start time and owner are
#          re-verified right before each signal, so a recycled pid is never hit. Never pkill, never a process group.
#          Each kill is logged to state/.lane-guard.log and reported as an alert.
#   spawn  bin/fm-spawn.sh records every failed creation (nonzero exit other than the capacity deferral) in
#          state/spawn-failures/; the next scan - FM_LANE_GUARD_INTERVAL in the watcher, default 120 s, so well inside
#          10 minutes - alerts once per failure unless a later spawn of the same task has since published its record.
#   pod    opt-in (config/pod-watch present). A job marker in the pod job queue (FM_POD_QUEUE_DIR, default
#          state/.heavy-queue/<job>.queued, written by data/tools/fm-pod-auto.sh) older than FM_POD_WATCH_QUEUE_SEC
#          (600) while the recorded pod (FM_POD_AUTO_DIR/pod.id, first field of the first line) is not RUNNING gets ONE
#          of: relaunch - POST /pods/<id>/start of that EXISTING pod, only when the RunPod balance reads positive - or a
#          warning (balance not positive or unreadable, pod gone or unreadable, nothing recorded). It never creates a
#          pod, never deletes one, and retries or re-warns at most every FM_POD_WATCH_RETRY_SEC (900).
# Alerts: appended to state/.lane-guard-alerts (outbox), logged, sent to the watcher webhook the way
#   bin/fm-silent-watcher.sh does (FM_SW_NO_NOTIFY=1 disables it), and registered as a captain ask with
#   data/tools/fm-asks.sh add --key lane-guard-<key> when that private tool exists (spawn and pod alerts only).
# The RunPod key (RUNPOD_API_KEY in FM_RUNPOD_ENV, default ~/.config/runpod.env) goes to curl on stdin only and is never printed.
# Env: FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_LG_NOW (epoch, tests) FM_SLOT_REQUEST_MAX_SEC
#   FM_SLOT_REQUEST_GRACE_SEC FM_SLOT_REQUEST_ROOT (tests: only requests whose cwd is under it) FM_POD_API FM_POD_GRAPHQL FM_RUNPOD_ENV FM_POD_AUTO_DIR FM_POD_QUEUE_DIR
#   FM_POD_WATCH_QUEUE_SEC FM_POD_WATCH_RETRY_SEC FM_LG_ASKS (fm-asks path, tests) FM_SW_NO_NOTIFY.
# Exit: 0 nothing new, 1 at least one alert was raised.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
F=${FM_HOME:-$(cd "$HERE/.." && pwd)}
S=${FM_STATE_OVERRIDE:-$F/state}
C=${FM_CONFIG_OVERRIDE:-$F/config}
now() { echo "${FM_LG_NOW:-$(date +%s)}"; }
LOG=$S/.lane-guard.log; OUT=$S/.lane-guard-alerts
SLOT_MAX=${FM_SLOT_REQUEST_MAX_SEC:-3600}; SLOT_GRACE=${FM_SLOT_REQUEST_GRACE_SEC:-5}
ASKS=${FM_LG_ASKS:-$F/data/tools/fm-asks.sh}
FAILDIR=$S/spawn-failures
ALERTED=0

log() { mkdir -p "$S"; echo "$(date -u -d "@$(now)" +%FT%TZ) $*" >> "$LOG"; }
notify() { # <event> <message>; same webhook and opt-out as bin/fm-silent-watcher.sh
  local u k m
  u=$(cat "$HOME/.config/fm/watcher-webhook.url" 2>/dev/null); k=$(cat "$HOME/.config/fm/watcher-webhook.key" 2>/dev/null)
  { [ -n "$u" ] && [ -n "$k" ] && [ -z "${FM_SW_NO_NOTIFY:-}" ]; } || return 0
  m=$(printf %s "$2" | tr -d '"\\')
  timeout 20 curl -fsS -X POST "$u" -H "Authorization: Bearer $k" -H "Content-Type: application/json" \
    --data "{\"event\":\"$1\",\"message\":\"$m\"}" >/dev/null 2>&1 || log "notify failed"
}
alert() { # <key> <ask:0|1> <message>
  local key=$1 ask=$2 msg=$3
  mkdir -p "$S"
  printf '%s\t%s\n' "$(now)" "$msg" >> "$OUT"
  log "ALERT $msg"
  notify lane-guard "$msg"
  [ "$ask" = 1 ] && [ -x "$ASKS" ] && FM_HOME=$F "$ASKS" add --key "lane-guard-$key" "$msg" >/dev/null 2>&1
  printf '%s\n' "$msg"
  ALERTED=1
}

# ------------------------------------------------------------------ slot requests
proc_start() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }  # starttime, field 22
# Is pid an unchanged `treehouse get` of ours? $2 = expected starttime (empty = do not compare).
is_get_request() {
  local pid=$1 start=${2:-} argv=() st
  [ -r "/proc/$pid/cmdline" ] || return 1
  [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$(id -u)" ] || return 1
  mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || return 1
  [ "${#argv[@]}" -ge 2 ] && [ "$(basename "${argv[0]}")" = treehouse ] && [ "${argv[1]}" = get ] || return 1
  if [ -n "$start" ]; then st=$(proc_start "$pid"); [ "$st" = "$start" ] || return 1; fi
  return 0
}
end_request() { # <pid> <start>: exact pid only
  local pid=$1 start=$2 i
  is_get_request "$pid" "$start" || return 1
  kill -TERM "$pid" 2>/dev/null
  kill -CONT "$pid" 2>/dev/null   # a request stopped on its tty keeps TERM pending until continued
  for i in $(seq 1 $((SLOT_GRACE * 4))); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  if is_get_request "$pid" "$start"; then kill -KILL "$pid" 2>/dev/null; fi
  sleep 0.25
  ! kill -0 "$pid" 2>/dev/null
}
scan_slot() {
  local table cand pid age start cwd parents
  table=$(ps -eo pid=,ppid=,etimes=,comm=,args= 2>/dev/null) || return 0
  # one ps pass, then only candidates (comm treehouse, argv "get") are inspected: a per-process /proc walk costs seconds on a busy host
  cand=$(awk '$4=="treehouse" && $5 ~ /(^|\/)treehouse$/ && $6=="get" {print $1, $3}' <<<"$table")
  [ -n "$cand" ] || return 0
  parents=$(awk '{print $2}' <<<"$table" | sort -u)
  while read -r pid age; do
    [ -n "$pid" ] || continue
    start=$(proc_start "$pid"); [ -n "$start" ] || continue
    is_get_request "$pid" "$start" || continue
    grep -qx "$pid" <<<"$parents" && continue   # has a subshell: a live worker lease, not a stuck request
    [[ ${age:-} =~ ^[0-9]+$ ]] && [ "$age" -gt "$SLOT_MAX" ] || continue
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo unknown)
    [ -z "${FM_SLOT_REQUEST_ROOT:-}" ] || [[ $cwd == "$FM_SLOT_REQUEST_ROOT"/* ]] || continue   # tests: only requests started under this dir
    if end_request "$pid" "$start"; then
      log "slot-request pid=$pid age=${age}s cwd=$cwd: no slot after more than ${SLOT_MAX}s, ended by exact pid"
      alert "slot-$pid" 0 "slot request ended: treehouse get pid=$pid in $cwd held no slot for ${age}s (limit ${SLOT_MAX}s); killed by exact pid, logged in state/.lane-guard.log"
    else
      alert "slot-$pid" 1 "slot request STUCK: treehouse get pid=$pid in $cwd held no slot for ${age}s and could not be ended; end that pid by hand"
    fi
  done <<<"$cand"
}

# ------------------------------------------------------------------ failed creations
record_spawn_failure() { # <id> <rc> [kind project backend harness]
  local id=$1 rc=$2 kind=${3:-} project=${4:-} backend=${5:-} harness=${6:-} f
  [[ $id =~ ^[A-Za-z0-9._-]+$ ]] && [[ $rc =~ ^[0-9]+$ ]] || return 1
  mkdir -p "$FAILDIR" || return 1
  f="$FAILDIR/$id.$(now).$$.fail"
  printf 'id=%s\nrc=%s\nat=%s\nkind=%s\nproject=%s\nbackend=%s\nharness=%s\n' \
    "$id" "$rc" "$(now)" "$kind" "$project" "$backend" "$harness" > "$f.tmp" && mv "$f.tmp" "$f"
}
fget() { sed -n "s/^$2=//p" "$1" | head -1; }
scan_spawn() {
  local f id rc at kind project backend harness meta
  [ -d "$FAILDIR" ] || return 0
  for f in "$FAILDIR"/*.fail; do
    [ -e "$f" ] || continue
    id=$(fget "$f" id); rc=$(fget "$f" rc); at=$(fget "$f" at)
    kind=$(fget "$f" kind); project=$(fget "$f" project); backend=$(fget "$f" backend); harness=$(fget "$f" harness)
    meta=$S/$id.meta
    if [ -e "$meta" ] && [ "$(stat -c %Y "$meta")" -ge "${at:-0}" ]; then   # a later spawn of this task succeeded
      mv "$f" "$f.warned"; continue
    fi
    mv "$f" "$f.warned"
    alert "spawn-$id-$at" 1 "worker creation failed: task $id exited $rc at $(date -u -d "@${at:-0}" +%FT%TZ) (kind=${kind:-?} project=${project:-?} backend=${backend:-?} harness=${harness:-?}); rerun bin/fm-spawn.sh for the error text"
  done
  find "$FAILDIR" -name '*.warned' -mtime +7 -delete 2>/dev/null
}

# ------------------------------------------------------------------ pod job queue
scan_pod() {
  [ -e "$C/pod-watch" ] || return 0
  local qdir=${FM_POD_QUEUE_DIR:-$S/.heavy-queue} adir=${FM_POD_AUTO_DIR:-$F/data/pod-auto}
  local qmax=${FM_POD_WATCH_QUEUE_SEC:-600} retry=${FM_POD_WATCH_RETRY_SEC:-900}
  local api=${FM_POD_API:-https://rest.runpod.io/v1} gql=${FM_POD_GRAPHQL:-https://api.runpod.io/graphql}
  local envf=${FM_RUNPOD_ENV:-$HOME/.config/runpod.env}
  local m oldest_job="" oldest_age=0 age n=0 pod key marker last status bal out code body start_rc

  for m in "$qdir"/*.queued; do
    [ -e "$m" ] || continue
    n=$((n + 1)); age=$(( $(now) - $(stat -c %Y "$m") ))
    if [ "$age" -gt "$oldest_age" ]; then oldest_age=$age; oldest_job=$(basename "$m" .queued); fi
  done
  [ -n "$oldest_job" ] && [ "$oldest_age" -gt "$qmax" ] || return 0

  mkdir -p "$S/.pod-watch"
  pod=$(awk 'NR==1{print $1}' "$adir/pod.id" 2>/dev/null)
  marker=$S/.pod-watch/${pod:-none}
  if [ -e "$marker" ]; then last=$(stat -c %Y "$marker"); [ $(( $(now) - last )) -ge "$retry" ] || return 0; fi

  key=$(sed -n 's/^RUNPOD_API_KEY=//p' "$envf" 2>/dev/null | head -1 | tr -d "\"'")
  if [ -z "$pod" ]; then
    : > "$marker"; alert pod-none 1 "pod queue: job $oldest_job has waited ${oldest_age}s ($n queued) and no pod is recorded in $adir/pod.id; not creating one - start or create a pod by hand"; return 0
  fi
  if [ -z "$key" ]; then
    : > "$marker"; alert "pod-$pod" 1 "pod queue: job $oldest_job has waited ${oldest_age}s ($n queued) and the RunPod key is unreadable, so pod $pod could not be checked or started"; return 0
  fi
  rpc() { # METHOD URL [json]; key on stdin only. Sets code/body.
    local o
    o=$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl -s -m 20 -K - -X "$1" -H 'Content-Type: application/json' \
      ${3:+--data "$3"} -w '\n%{http_code}' "$2" 2>/dev/null)
    code=${o##*$'\n'}; body=${o%$'\n'*}
  }
  rpc GET "$api/pods/$pod"
  if [[ $code =~ ^2 ]]; then status=$(jq -r '.desiredStatus // empty' <<<"$body" 2>/dev/null)
  else
    : > "$marker"
    alert "pod-$pod" 1 "pod queue: job $oldest_job has waited ${oldest_age}s ($n queued) and pod $pod cannot be read (http $code); not creating another - check the pod by hand"
    return 0
  fi
  [ "$status" = RUNNING ] && { rm -f "$marker"; return 0; }   # live pod: the queue is just busy

  rpc POST "$gql" '{"query":"query { myself { clientBalance } }"}'
  bal=$(jq -r '.data.myself.clientBalance // empty' <<<"$body" 2>/dev/null)
  : > "$marker"
  if ! [[ $bal =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    alert "pod-$pod" 1 "pod queue: job $oldest_job has waited ${oldest_age}s ($n queued) and pod $pod is ${status:-unknown}; the RunPod balance could not be read, so it was NOT started"
  elif ! awk -v b="$bal" 'BEGIN{exit !(b>0)}'; then
    alert "pod-$pod" 1 "pod queue: job $oldest_job has waited ${oldest_age}s ($n queued) and pod $pod is ${status:-unknown}; the RunPod balance is \$$bal (not positive), so it was NOT started - add credit"
  else
    rpc POST "$api/pods/$pod/start"
    if [[ $code =~ ^2 ]]; then
      log "pod-queue pod=$pod job=$oldest_job: start requested (balance \$$bal)"
      alert "pod-$pod" 0 "pod queue: job $oldest_job had waited ${oldest_age}s ($n queued) with pod $pod ${status:-unknown}; start requested (balance \$$bal)"
    else
      alert "pod-$pod" 1 "pod queue: job $oldest_job has waited ${oldest_age}s ($n queued) with pod $pod ${status:-unknown}; the start request was refused (http $code)"
    fi
  fi
}

case "${1:-}" in
  record-spawn-failure) shift; [ $# -ge 2 ] || { echo "usage: fm-lane-guard.sh record-spawn-failure <task-id> <exit-code> [kind project backend harness]" >&2; exit 64; }
    record_spawn_failure "$@"; exit $? ;;
  scan)
    mkdir -p "$S"; exec 9>"$S/.lane-guard.lock"; flock -n 9 || exit 0
    case "${2:-all}" in
      slot) scan_slot ;; spawn) scan_spawn ;; pod) scan_pod ;;
      all) scan_slot; scan_spawn; scan_pod ;;
      *) echo "usage: fm-lane-guard.sh scan [slot|spawn|pod]" >&2; exit 64 ;;
    esac
    [ "$ALERTED" = 0 ] ;;
  *) echo "usage: fm-lane-guard.sh scan [slot|spawn|pod] | record-spawn-failure <task-id> <exit-code> [kind project backend harness]" >&2; exit 64 ;;
esac
