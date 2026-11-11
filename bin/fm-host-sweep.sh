#!/usr/bin/env bash
# fm-host-sweep.sh - constant cleanup of idle agents and leftovers on every machine. Deterministic: no model, no sudo.
#
# Usage: fm-host-sweep.sh [--dry-run|--apply] [--pass full|light|disk] [--armed] [--notify] [--host NAME]... [--idle-hours N] [--tmp-days N]
#          [--clone-days N] [--max-lanes N] [--budget SECS] [--pool-keep N] [--proc-min-age SECS] [--pane-idle-hours N] [--chrome-hours N]
#          [--preview-hours N] [--test-min-age SECS] [--remote-branches] [--no-clones] [--verbose] [--removed-log FILE]
#   default --dry-run (lists what would go and the bytes); --apply removes. One report screen at the end, one block per machine.
#   --pass P            full (default: everything), light (agents, processes, Herdr terminals, Chrome tabs, state/ leftovers: every 30 min)
#                       or disk (branches, worktree pool, /tmp, clones and the awaiting-OK list: once a night). A machine whose load is above
#                       its core count runs only what releases memory (processes, bridges, previews, terminals, tabs, idle agents).
#   --armed             let the rules added by the cleanup expansion (terminals, state/ leftovers, Chrome tabs, bridges, previews, orphan
#                       tests, lavish polls) REMOVE under --apply. Without it they only list `would` (the first pass is always a simulation);
#                       the file <home>/config/host-sweep.rules-armed arms them too, and deleting it disarms them again.
#   --notify            under --apply, append ONE line to the primary's inbox (bin/fm-inbox.sh note) when something was removed or an item
#                       waits for the owner's OK; an empty round writes nothing, an unchanged waiting list is repeated at most once a day
#   --idle-hours N      a finished agent still holding its pane/slot for more than N hours is closed (default 3)
#   --pane-idle-hours N a Herdr terminal with no agent, no live task and a childless idle shell for N hours goes (default 2)
#   --chrome-hours N    a tab of the shared Chrome (port 9222) open that long with no client attached is closed (default 12)
#   --preview-hours N   a preview server of no closed task, with no connection, up that long goes (default 24)
#   --test-min-age SECS an orphan test run (vitest, parent gone) goes after this age (default 3600)
#   --tmp-days N        ended-task /tmp dirs, dead pod logs and CI caches older than N days go (default 3)
#   --clone-days N      a clean fully pushed clone outside projects/ untouched for N days goes (default 30)
#   --budget SECS       wall-clock cap per machine (default 1200): sweeps that cannot start inside it are reported `kept: time budget`;
#                       machines run in parallel, each worker stops at its own budget
#   --pool-keep N       keep at least N free treehouse worktrees per pool (default 3)
#   --remote-branches   also delete remote branches already contained in the remote default branch (outward-facing; off by default)
#   --verbose           also list every `kept` item with the reason it was left alone
#   --removed-log FILE  audit log, default <home>/data/sweep/removed.tsv: `time host category object bytes reason` (the reason carries the proof)
#
# Machines come from config/host-sweep.hosts, one per line: `name kind target root homes [testdir,...]` (# comments):
#   kind    vps (full sweep), pc (ONLY agent processes and Herdr terminals: no teardown, no disk, nothing else), mac (ONLY /tmp task dirs and
#           the listed testdirs, nothing else)
#   target  `local` for this machine, otherwise an ssh destination; the worker is streamed over `ssh ... bash -s`
#   root    firstmate code root on that machine, homes comma separated firstmate homes (main, secondmate homes) whose lanes count
#   Absent file: main (local, this home plus local secondmate homes), creative (creative-vps-factory), pc (pc-aux), mac (FM_SWEEP_MAC_SSH and
#   FM_SWEEP_MAC_TESTDIRS, no default: without a target it is reported `unknown` and nothing runs).
# Extra dead-log globs (pod logs, CI caches) come from config/host-sweep.conf lines `dead-glob <glob>`; `@HOME@` is each home, `@TMP@` the machine's /tmp.
#
# What the worker sweeps on a machine, and the proof each removal needs:
#   lanes     fm-close-finished-lanes.sh --apply (its guards and fm-teardown.sh without --force: unlanded work or an unmerged PR
#             keeps the lane). Then each finished-but-kept ship/scout whose done status is older than --idle-hours has its agent
#             exited with fm-control.sh exit (worktree and endpoint preserved). Herdr panes are only ever closed by those two scripts.
#   procs     orphans (ppid 1 or a systemd parent, older than --proc-min-age) named pi, claude, node, npx, pnpm, vitest or playwright
#             whose cwd is in a worktree of an ended task or a treehouse slot with no live task and no live non-orphan process in it.
#   branches  local branches contained in the default branch (merge-base), patch-equivalent (git cherry shows no `+`) or whose merge into it
#             changes nothing (git merge-tree gives the default's own tree: squash and rebase merges), not checked out, not a live task's; with --remote-branches also origin branches contained in origin's default branch; git worktree prune.
#   pool      free treehouse worktrees: not a task worktree, clean, HEAD in the default branch; removed by `treehouse destroy <path> --yes`
#             with no --include-* flag, leaving --pool-keep free ones.
#   tmp       /tmp/fm-<task-id>* of ended tasks (data or status exists, no live meta), the machine's testdirs children, and dead-globs,
#             all older than --tmp-days with no file newer and no process inside.
#   clones    clean clones outside projects/ with origin, nothing unpushed, no stash, no linked worktree, no ignored file outside regenerable
#             build dirs, untouched --clone-days; unclean ones are listed `kept` and left.
# Added by the cleanup expansion (all pid-proved, none through pkill or a name pattern; each is a `would` until armed, see --armed):
#   panes     Herdr terminals: bin/fm-herdr-session-cleanup.sh --sweep-idle (header there): no agent, no live task, one idle childless shell
#             (the session-start proof) seen idle on every pass for --pane-idle-hours, never the focused or the last pane.
#   procs     (also) orphan vitest runs (parent gone, --test-min-age, cwd of no live task).
#   lavish    orphan `lavish-axi poll` / fm-procevent-lavish.sh poll: the supervising runner is gone, so the page has no listener left.
#   bridges   chrome-devtools-axi bridges (and their chrome-devtools-mcp children) of an ended task's session, or idle --preview-hours with no
#             connection; never a browser process.
#   previews  `http.server` and `servir.mjs` servers of an ended task, or up --preview-hours with no connection and no live task around them.
#   chrome    tabs of the shared Chrome (CDP port FM_SWEEP_CHROME_PORT, default 9222) seen on every pass for --chrome-hours with no CDP client
#             connected, not the last tab, not an owner-profile/app URL; closed over the CDP HTTP endpoint, the browser is never signalled.
#   state     leftovers in <home>/state: watcher markers (.hash- .count- .stale- ...) of the retired non-v3 key scheme, v3 markers of a window
#             no task record names (3 days), .seen-procevent-* of a source no longer in the wake queue (7 days), *.tmp.* older than a day.
#   ask       WAITING FOR THE OWNER's OK, listed (`listed`) and never touched: local branches with commits not in the default branch, dirty free
#             worktrees, data/<id> folders and Claude transcripts older than 30 days, ~/.npm and ~/.cache above 1 GB, tasks parked on a decision.
# kind pc ends nothing but agent processes (the idle-agent exit and the older orphan-agent rule) and Herdr terminals: no teardown, no disk, no
# Chrome, no state/, none of the other process kinds above. The Mac still sweeps nothing but /tmp and its testdirs.
# NEVER: a live task or secondmate (its worktree, tmpdir, branch, processes), unlanded or dirty work, a process or path matching
#   Anki, AdsPower, Opera, Dolphin, python.exe/.exe, port 8766, saas-*, docker, browser profiles, herdr, no-mistakes, lavish, sshd,
#   `claude --resume`, /tmp/fm-main, pmfbkey, rv-segredos-*, another user's processes;
#   Docker is never invoked; a symlink is never followed into a removal. The Mac sweep never leaves /tmp and its testdirs.
#
# Env: FM_HOME; FM_SWEEP_PROC_SCOPE (tests only: the additions' process rules ignore any process whose command and cwd do not match this regex),
#   FM_SWEEP_LOAD / FM_SWEEP_CORES (tests only: stand in for the load average and the core count); FM_SWEEP_HOSTS (hosts file), FM_SWEEP_SSH_CMD (default ssh), FM_SWEEP_MAC_SSH, FM_SWEEP_TMP (default /tmp),
#   FM_SWEEP_HOME_ROOT (clone scan root, default $HOME), FM_SWEEP_SSH_TIMEOUT (10).
# Bash 3.2 compatible (the Mac worker), so no `set -u` and no associative arrays or mapfile.
# Exit: 0 (also when a machine is unreachable: it is reported `unreachable`), 64 usage.
set -o pipefail

SELF="${BASH_SOURCE[0]}"
case "$SELF" in /*) ;; *) SELF="$PWD/$SELF" ;; esac

MODE=orchestrate
apply=0 kind=vps root='' idle_hours=3 tmp_days=3 clone_days=30 max_lanes=20 budget=1200 pool_keep=3 proc_min_age=1800
remote_branches=0 clones=1 verbose=0 removed_log='' only_hosts=() homes=() testdirs=() dead_globs=()
pass=full armed=0 notify=0 pane_idle_hours=2 chrome_hours=12 preview_hours=24 test_min_age=3600 overloaded=0 lanes_closer=1
usage() { sed -n '2,/^set -o pipefail/p' "$SELF" | sed '$d; s/^# \{0,1\}//' >&2; exit 64; }
num() { case "${2-}" in ''|*[!0-9]*) echo "fm-host-sweep: $1 needs a number" >&2; exit 64 ;; esac; }
while [ $# -gt 0 ]; do
  case "$1" in
    --worker) MODE=worker ;;
    --dry-run) apply=0 ;;
    --apply) apply=1 ;;
    --host) shift; only_hosts+=("${1:?}") ;;
    --kind) shift; kind=${1:?} ;;
    --root) shift; root=${1:?} ;;
    --home) shift; homes+=("${1:?}") ;;
    --testdir) shift; testdirs+=("${1:?}") ;;
    --dead-glob) shift; dead_globs+=("${1:?}") ;;
    --idle-hours) shift; num "$1" "${1-}"; idle_hours=$1 ;;
    --tmp-days) shift; num "$1" "${1-}"; tmp_days=$1 ;;
    --clone-days) shift; num "$1" "${1-}"; clone_days=$1 ;;
    --budget) shift; num "$1" "${1-}"; budget=$1 ;;
    --max-lanes) shift; num "$1" "${1-}"; max_lanes=$1 ;;
    --pool-keep) shift; num "$1" "${1-}"; pool_keep=$1 ;;
    --proc-min-age) shift; num "$1" "${1-}"; proc_min_age=$1 ;;
    --pass) shift; case "${1-}" in full|light|disk) pass=$1 ;; *) usage ;; esac ;;
    --armed) armed=1 ;;
    --notify) notify=1 ;;
    --pane-idle-hours) shift; num "$1" "${1-}"; pane_idle_hours=$1 ;;
    --chrome-hours) shift; num "$1" "${1-}"; chrome_hours=$1 ;;
    --preview-hours) shift; num "$1" "${1-}"; preview_hours=$1 ;;
    --test-min-age) shift; num "$1" "${1-}"; test_min_age=$1 ;;
    --remote-branches) remote_branches=1 ;;
    --no-clones) clones=0 ;;
    --verbose) verbose=1 ;;
    --removed-log) shift; removed_log=${1:?} ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

# ============================== worker: runs ON the machine ==============================
# Prints `ITEM<TAB>category<TAB>would|removed|kept|failed<TAB>object<TAB>bytes<TAB>reason`; nothing else on stdout.
tick() {  # FM_SWEEP_DEBUG=1 prints the seconds each sweep took, on stderr
  [ -z "${FM_SWEEP_DEBUG:-}" ] || echo "phase $1: $((SECONDS - TICK0))s" >&2
  TICK0=$SECONDS
}
left() { [ $((DEADLINE - SECONDS)) -ge "$1" ]; }   # at least N seconds of the machine's budget remain
sweep_overloaded() {  # 0 when the load average is above the core count (FM_SWEEP_LOAD / FM_SWEEP_CORES stand in for tests)
  local load cores
  load=${FM_SWEEP_LOAD:-$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')}
  cores=${FM_SWEEP_CORES:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)}
  awk -v l="${load:-0}" -v c="${cores:-1}" 'BEGIN { exit !(l + 0 > c + 0) }'
}
worker_main() {
  local light=1 disk=1
  TICK0=$SECONDS; DEADLINE=$((SECONDS + budget))
  [ "$kind" != mac ] || { sweep_tmp; return 0; }
  case "$pass" in light) disk=0 ;; disk) light=0 ;; esac
  if sweep_overloaded; then
    overloaded=1; disk=0; lanes_closer=0
    emit load kept "-" 0 "load above the core count: only the sweeps that release memory run (no teardown, no disk sweeps)"
  fi
  # the PC: agent processes and their terminals only - no teardown, no disk, no browser, no state/, no other process kinds
  if [ "$kind" = pc ]; then
    lanes_closer=0
    [ "$disk" = 0 ] || emit disk kept "-" 0 "the PC takes no disk sweep (agent processes and terminals only)"
    disk=0
  fi
  if [ "$light" = 1 ]; then
    if left 120; then sweep_lanes; else emit lanes kept "-" 0 "time budget of ${budget}s reached before the lane sweep"; fi; tick lanes
    if left 30; then sweep_procs; [ "$kind" = pc ] || sweep_leftovers; fi; tick procs
    if left 30; then sweep_panes; fi; tick panes
    if [ "$kind" != pc ]; then
      if left 30; then sweep_chrome; fi; tick chrome
      if [ "$overloaded" = 0 ] && left 30; then sweep_statefiles; fi; tick state
    fi
  fi
  if [ "$disk" = 1 ]; then
    if left 60; then sweep_branches; else emit branches kept "-" 0 "time budget reached"; fi; tick branches
    if left 60; then sweep_pool; else emit pool kept "-" 0 "time budget reached"; fi; tick pool
    if left 60; then sweep_tmp; else emit tmp kept "-" 0 "time budget reached"; fi; tick tmp
    if [ "$clones" = 1 ]; then
      if left 60; then sweep_clones; else emit clones kept "-" 0 "time budget reached"; fi; tick clones
    fi
    if [ "$kind" != pc ] && left 60; then sweep_asks; fi; tick asks
  fi
  return 0
}

PROTECT_RE='Anki|anki|AdsPower|adspower|Opera|opera|Dolphin|dolphin|8766|\.exe|saas-|[Dd]ocker|chrom|firefox|[Pp]rofile|\.mozilla|herdr|no-mistakes|lavish|sshd|tailscale|fm-watch'
# The additions target browsers' helper bridges, lavish pollers and the like, so they use the same list without the names they must reach.
PROTECT_CORE_RE='Anki|anki|AdsPower|adspower|Opera|opera|Dolphin|dolphin|8766|\.exe|saas-|[Dd]ocker|[Pp]rofile|\.mozilla|no-mistakes|sshd|tailscale|fm-watch|--resume|pmfbkey|rv-segredos|/tmp/fm-main'
SCRATCH=''
bytes_of() {  # path -> bytes
  local k
  k=$(du -sk "$1" 2>/dev/null | awk '{print $1}')
  echo $(( ${k:-0} * 1024 ))
}
to() { local s=$1; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi; }
emit() { printf 'ITEM\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-0}" "${5:-}"; }
# The operations `act` performs. Anything else is run as the given command.
perform() {
  case "$1" in
    rmtree) rm -rf -- "$2" ;;
    endproc)  # TERM, then KILL after 5 s; succeeds only when the pid is gone
      kill "$2" 2>/dev/null
      for _ in 1 2 3 4 5; do kill -0 "$2" 2>/dev/null || return 0; sleep 1; done
      kill -9 "$2" 2>/dev/null; sleep 1
      ! kill -0 "$2" 2>/dev/null ;;
    endprocs) shift; for _p in "$@"; do perform endproc "$_p" || return 1; done ;;   # a bridge and its helper children, children first
    destroyslot) ( cd "$2" && treehouse destroy "$3" --yes ) ;;   # no --include-* flag: treehouse itself refuses anything not disposable
    *) "$@" ;;
  esac
}
# remove-or-report: <category> <object> <bytes> <reason> <operation...>; a failed operation is reported, never retried harder.
act() {
  local c=$1 o=$2 b=$3 r=$4; shift 4
  if [ "$apply" = 0 ]; then emit "$c" would "$o" "$b" "$r${NOT_ARMED:+ (rules not armed: simulation)}"; return 0; fi
  if perform "$@" >/dev/null 2>&1; then emit "$c" removed "$o" "$b" "$r"; else emit "$c" failed "$o" 0 "$r (command refused)"; fi
}
# act for the rules added by the cleanup expansion: a simulation until armed (--armed or config/host-sweep.rules-armed)
actn() {
  local saved=$apply
  if [ "$armed" = 0 ] && [ "$apply" = 1 ]; then apply=0; NOT_ARMED=1; fi
  act "$@"
  apply=$saved; NOT_ARMED=''
}
meta_val() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }
last_word() { tail -n 1 "$1" 2>/dev/null | cut -d' ' -f1; }
under() {  # path prefix-list-file -> 0 when path is at or below a listed path
  local p=$1 l
  while IFS= read -r l; do [ -n "$l" ] || continue; case "$p" in "$l"|"$l"/*) return 0 ;; esac; done < "$2"
  return 1
}

collect_task_sets() {  # fills $SCRATCH/{live_paths,ended_paths,live_branches,live_ids,ended_ids,project_dirs}
  local h m id k st
  : > "$SCRATCH/live_paths"; : > "$SCRATCH/ended_paths"; : > "$SCRATCH/live_branches"
  : > "$SCRATCH/live_ids"; : > "$SCRATCH/ended_ids"; : > "$SCRATCH/project_dirs"; : > "$SCRATCH/live_task_paths"
  [ -z "$root" ] || echo "$root" >> "$SCRATCH/live_paths"
  for h in "${homes[@]}"; do
    echo "$h" >> "$SCRATCH/live_paths"
    for m in "$h"/state/*.meta; do
      [ -f "$m" ] || continue
      id=$(basename "$m" .meta); k=$(meta_val "$m" kind); st=$(last_word "$h/state/$id.status")
      if [ "$k" = secondmate ] || { [ "$st" != "done" ] && [ "$st" != "failed" ]; }; then
        echo "$id" >> "$SCRATCH/live_ids"
        { meta_val "$m" worktree; meta_val "$m" tasktmp; meta_val "$m" home; } | tee -a "$SCRATCH/live_paths" >> "$SCRATCH/live_task_paths"
        meta_val "$m" branch >> "$SCRATCH/live_branches"
      else
        echo "$id" >> "$SCRATCH/ended_ids"
        meta_val "$m" worktree >> "$SCRATCH/ended_paths"; meta_val "$m" tasktmp >> "$SCRATCH/ended_paths"
      fi
      meta_val "$m" project >> "$SCRATCH/project_dirs"
    done
    for id in "$h"/projects/*; do [ -d "$id/.git" ] && echo "$id" >> "$SCRATCH/project_dirs"; done
  done
  [ -z "$root" ] || echo "$root" >> "$SCRATCH/project_dirs"
  # one snapshot of every process working directory, for the "is anything running in it" tests
  for m in /proc/[0-9]*; do readlink "$m/cwd" 2>/dev/null; done | sed 's/ (deleted)$//' > "$SCRATCH/cwds"
  sed -i.bak '/^$/d' "$SCRATCH"/live_task_paths "$SCRATCH"/live_paths "$SCRATCH"/ended_paths "$SCRATCH"/live_branches "$SCRATCH"/project_dirs 2>/dev/null; rm -f "$SCRATCH"/*.bak
  sort -u -o "$SCRATCH/project_dirs" "$SCRATCH/project_dirs"
}

under_file() {  # dir list-file -> 0 when some listed path is at or below dir
  awk -v d="$1" '$0 == d || index($0, d "/") == 1 { f = 1; exit } END { exit f ? 0 : 1 }' "$2"
}
dir_idle() {  # dir days -> 0 when nothing in it changed for days and no process runs inside
  local d=$1 days=$2
  [ -n "$(find "$d" -mtime "-$days" -print -quit 2>/dev/null)" ] && return 1
  under_file "$d" "$SCRATCH/cwds" && return 1
  return 0
}

# ---- lanes: idle agents holding slots (priority one)
sweep_lanes() {
  local h closer ctl crew out line id meta wt b st age lim
  for h in "${homes[@]}"; do
    closer="$root/bin/fm-close-finished-lanes.sh"; ctl="$root/bin/fm-control.sh"; crew="$root/bin/fm-crew-state.sh"
    [ -x "$closer" ] || { emit lanes kept "$h" 0 "no fm-close-finished-lanes.sh under $root"; continue; }
    left 120 || { emit lanes kept "$h" 0 "time budget reached before this home"; continue; }
    : > "$SCRATCH/lanes_closed"
    out=''
    [ "$lanes_closer" = 0 ] || out=$(FM_HOME="$h" to "$(( DEADLINE - SECONDS > 120 ? DEADLINE - SECONDS : 120 ))" "$closer" "$([ "$apply" = 1 ] && echo --apply || echo --dry-run)" --max "$max_lanes" --budget "$(( DEADLINE - SECONDS - 60 > 60 ? DEADLINE - SECONDS - 60 : 60 ))" 2>&1)
    while IFS= read -r line; do
      case "$line" in
        "closed: "*|"would close: "*)
          id=${line#*: }; id=${id%% *}; meta="$h/state/$id.meta"
          wt=$(meta_val "$meta" worktree); b=0; [ -d "$wt" ] && b=$(bytes_of "$wt")
          echo "$id" >> "$SCRATCH/lanes_closed"
          if [ "$apply" = 1 ]; then emit lanes removed "$h:$id" "$b" "finished lane closed by fm-teardown (landed-work guard passed)"
          else emit lanes would "$h:$id" "$b" "finished lane, fm-teardown would close it"; fi ;;
        "kept: "*) id=${line#*: }; emit lanes kept "$h:${id%% *}" 0 "${id#* }" ;;
      esac
    done <<< "$out"
    # finished lanes that stay (merge pending, hold open) release their agent after the idle window
    for meta in "$h"/state/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta); b=$(meta_val "$meta" kind)
      [ "$b" = secondmate ] && continue
      [ -z "$(meta_val "$meta" remote_host)" ] || continue
      grep -qx "$id" "$SCRATCH/lanes_closed" && continue
      [ -x "$crew" ] || break
      [ "$(last_word "$h/state/$id.status")" = "done" ] || continue   # a crew that finished always logged done; skip the slow state read for the rest
      st=$(FM_HOME="$h" "$crew" "$id" 2>/dev/null | head -n1); st=${st#state: }; st=${st%% *}
      [ "$st" = "done" ] || continue
      lim=$(( idle_hours * 3600 ))
      age=$(( $(date +%s) - $(stat -c %Y "$h/state/$id.status" 2>/dev/null || stat -f %m "$h/state/$id.status" 2>/dev/null || date +%s) ))
      [ "$age" -ge "$lim" ] || continue
      [ -x "$ctl" ] || continue
      act lanes "$h:$id" 0 "finished and idle for $((age / 3600)) h: agent exited with fm-control exit, worktree kept" \
        env FM_HOME="$h" "$ctl" "$id" exit
    done
  done
}

# ---- orphan agent and test processes of ended work
sweep_procs() {
  local line pid ppid age rss args a0 cwd pa slot now_args k live_slots
  [ -d /proc/1 ] || return 0
  # candidates from one snapshot: orphaned (ppid 1 or a systemd parent), old enough, a named kind of process
  for line in $(ps -eo pid=,ppid=,etimes=,rss=,comm= 2>/dev/null | awk -v me="$$" -v min="$proc_min_age" '
      { pid[NR] = $1; pp[NR] = $2; age[NR] = $3; rss[NR] = $4; comm[$1] = $5; row[NR] = $1 }
      END { for (i = 1; i <= NR; i++)
              if (pid[i] != me && age[i] >= min && (pp[i] == 1 || comm[pp[i]] == "systemd") \
                  && comm[pid[i]] ~ /^(pi|claude|node|npx|pnpm|npm|vitest|playwright)$/)
                print pid[i] ":" pp[i] ":" age[i] ":" rss[i] }'); do
    IFS=: read -r pid ppid age rss <<< "$line"
    args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null); [ -n "$args" ] || continue
    a0=${args%% *}; a0=${a0##*/}
    case "$a0" in pi|claude|node|npx|pnpm|npm|vitest|playwright) ;; *) continue ;; esac
    printf '%s' "$args" | grep -Eq "$PROTECT_RE" && continue
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null); cwd=${cwd% (deleted)}
    [ -n "$cwd" ] || continue
    printf '%s' "$cwd" | grep -Eq "$PROTECT_RE" && continue
    under "$cwd" "$SCRATCH/live_paths" && continue
    # a protected process anywhere below it keeps it
    if ps -eo ppid=,args= 2>/dev/null | awk -v p="$pid" '$1 == p' | grep -Eq "$PROTECT_RE|(^| )(pi|claude|herdr|no-mistakes)( |$)"; then continue; fi
    if under "$cwd" "$SCRATCH/ended_paths"; then :
    else
      case "$cwd" in */.treehouse/*/[0-9]*|*/.treehouse/*/[0-9]*/*) ;; *) continue ;; esac
      slot=$(printf '%s' "$cwd" | sed -n 's|\(.*/\.treehouse/[^/]*/[0-9][0-9]*\).*|\1|p')
      [ -n "$slot" ] || continue
      # a slot with any other live non-orphan process in it is somebody's workplace
      live_slots=0
      for k in /proc/[0-9]*; do
        [ "${k#/proc/}" = "$pid" ] && continue
        case "$(readlink "$k/cwd" 2>/dev/null)" in "$slot"|"$slot"/*)
          pa=$(awk '{print $4}' "$k/stat" 2>/dev/null)
          [ "$pa" = 1 ] || { live_slots=1; break; } ;;
        esac
      done
      [ "$live_slots" = 0 ] || continue
    fi
    # re-read right before ending: same pid, same command, still orphaned
    now_args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    [ "$now_args" = "$args" ] || continue
    echo "$pid" >> "$SCRATCH/handled_pids"
    act procs "pid $pid ${args:0:100}" $(( ${rss:-0} * 1024 )) "orphan (ppid $ppid) of an ended task, cwd $cwd, up $((age / 60)) min" endproc "$pid"
  done
}

# ---- branches, merged local and (opt-in) remote ones, stale worktree records
default_branch() {  # repo
  local d
  d=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); d=${d#origin/}
  if [ -z "$d" ]; then for d in main master; do git -C "$1" show-ref --verify --quiet "refs/heads/$d" && { echo "$d"; return; }; done; d=; fi
  echo "$d"
}
sweep_branches() {
  local repo def cur b ahead wts bytes pr
  while IFS= read -r repo; do
    [ -d "$repo/.git" ] || continue
    def=$(default_branch "$repo"); [ -n "$def" ] || { emit branches kept "$repo" 0 "no default branch found"; continue; }
    cur=$(git -C "$repo" branch --show-current 2>/dev/null)
    wts=$(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's|^branch refs/heads/||p')
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      case "$b" in "$def"|"$cur"|main|master|develop|release/*|gh-pages) continue ;; esac
      printf '%s\n' "$wts" | grep -qx "$b" && { emit branches kept "$repo:$b" 0 "checked out in a worktree"; continue; }
      grep -qx "$b" "$SCRATCH/live_branches" && { emit branches kept "$repo:$b" 0 "branch of a live task"; continue; }
      if git -C "$repo" merge-base --is-ancestor "$b" "$def" 2>/dev/null; then pr="merge-base: tip is in $def"
      else
        ahead=$(git -C "$repo" cherry "$def" "$b" 2>/dev/null | grep -c '^+')
        if [ "$ahead" = 0 ]; then pr="git cherry: every commit is patch-equivalent in $def"
        elif [ "$(git -C "$repo" merge-tree --write-tree "$def" "$b" 2>/dev/null | head -1)" = "$(git -C "$repo" rev-parse "$def^{tree}" 2>/dev/null)" ]; then
          pr="git merge-tree: merging it into $def changes nothing (squash or rebase merged)"
        else emit ask listed "branch:$repo:$b" 0 "$ahead commit(s) not in $def"; continue; fi
      fi
      act branches "$repo:$b" 0 "$pr" git -C "$repo" branch -D "$b"
    done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
    if [ "$remote_branches" = 1 ] && git -C "$repo" remote get-url origin >/dev/null 2>&1; then
      while IFS= read -r b; do
        b=${b#origin/}
        case "$b" in "$def"|HEAD|main|master|develop|release/*|gh-pages|'') continue ;; esac
        git -C "$repo" merge-base --is-ancestor "origin/$b" "origin/$def" 2>/dev/null || { emit branches kept "$repo:origin/$b" 0 "not contained in origin/$def"; continue; }
        act branches "$repo:origin/$b" 0 "remote tip is in origin/$def (merge-base)" to 60 git -C "$repo" push origin --delete "$b"
      done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null)
    fi
    pr=$(git -C "$repo" worktree prune -n -v 2>/dev/null | wc -l | tr -d ' ')
    if [ "${pr:-0}" -gt 0 ]; then act branches "$repo:worktree-records" 0 "$pr stale worktree record(s) with a missing directory" git -C "$repo" worktree prune; fi
  done < "$SCRATCH/project_dirs"
}

# ---- free treehouse worktrees
sweep_pool() {
  local repo line path def pool n free bytes seen=''
  command -v treehouse >/dev/null 2>&1 || return 0
  while IFS= read -r repo; do
    [ -d "$repo/.git" ] || continue
    def=$(default_branch "$repo"); [ -n "$def" ] || continue
    free=$(cd "$repo" && treehouse status 2>/dev/null | sed -n 's|^[0-9][0-9]* *available *\(.*\)$|\1|p')
    [ -n "$free" ] || continue
    pool=$(printf '%s\n' "$free" | head -1 | sed 's|/[0-9][0-9]*/[^/]*$||')
    case " $seen " in *" $pool "*) continue ;; esac
    seen="$seen $pool"
    n=$(printf '%s\n' "$free" | grep -c .)
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      path=${path/#\~/$HOME}
      [ "$n" -gt "$pool_keep" ] || { emit pool kept "$path" 0 "pool keeps $pool_keep free worktrees"; continue; }
      under "$path" "$SCRATCH/live_paths" && { emit pool kept "$path" 0 "worktree of a task"; continue; }
      if ! git -C "$path" rev-parse HEAD >/dev/null 2>&1; then emit pool kept "$path" 0 "not a readable worktree"; continue; fi
      if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
        emit ask listed "dirty-worktree:$path" 0 "free worktree with uncommitted changes"; continue
      fi
      git -C "$repo" merge-base --is-ancestor "$(git -C "$path" rev-parse HEAD)" "$def" 2>/dev/null \
        || { emit pool kept "$path" 0 "HEAD not in $def"; continue; }
      bytes=$(bytes_of "$path")
      act pool "$path" "$bytes" "free, clean, HEAD in $def" destroyslot "$repo" "$path"
      n=$((n - 1))
    done <<< "$free"
  done < "$SCRATCH/project_dirs"
}

# ---- /tmp task dirs, test dirs, dead logs and caches
sweep_tmp() {
  local tmp=${FM_SWEEP_TMP:-/tmp} d id h g t base
  [ -d "$tmp" ] || return 0
  collect_ids_for_tmp
  for d in "$tmp"/fm-*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    base=${d##*/}; id=${base#fm-}
    printf '%s' "$d" | grep -Eq "$PROTECT_RE" && continue
    t=''
    if [ "$kind" = mac ]; then t=$id    # the Mac keeps no tasks: every /tmp/fm-* there was made by firstmate tooling
    else
      while IFS= read -r t; do [ -n "$t" ] || continue
        case "$id" in "$t"|"$t"-*) break ;; esac; t=''
      done < "$SCRATCH/ended_ids"
    fi
    [ -n "$t" ] || continue
    grep -qxF "$t" "$SCRATCH/live_ids" && continue
    under "$d" "$SCRATCH/live_task_paths" && continue
    dir_idle "$d" "$tmp_days" || { emit tmp kept "$d" 0 "touched within $tmp_days days or in use"; continue; }
    act tmp "$d" "$(bytes_of "$d")" "tmp of ended task $t, untouched $tmp_days+ days" rmtree "$d"
  done
  for t in "${testdirs[@]}"; do
    [ -d "$t" ] && [ ! -L "$t" ] || continue
    for d in "$t"/*; do
      [ -e "$d" ] && [ ! -L "$d" ] || continue
      printf '%s' "$d" | grep -Eq "$PROTECT_RE" && continue
      dir_idle "$d" "$tmp_days" || { emit tmp kept "$d" 0 "touched within $tmp_days days or in use"; continue; }
      act tmp "$d" "$(bytes_of "$d")" "test folder entry untouched $tmp_days+ days" rmtree "$d"
    done
  done
  [ "$kind" != mac ] || return 0
  for h in "${homes[@]}"; do
    for g in "${dead_globs[@]}"; do
      g=${g//@HOME@/$h}; g=${g//@TMP@/$tmp}
      # shellcheck disable=SC2086
      for d in $g; do
        [ -e "$d" ] && [ ! -L "$d" ] || continue
        printf '%s' "$d" | grep -Eq "$PROTECT_RE" && continue
        under "$d" "$SCRATCH/live_task_paths" && continue
        under_file "$d" "$SCRATCH/live_task_paths" && continue
        dir_idle "$d" "$tmp_days" || { emit tmp kept "$d" 0 "touched within $tmp_days days or in use"; continue; }
        act tmp "$d" "$(bytes_of "$d")" "dead pod log / CI cache ($g), untouched $tmp_days+ days" rmtree "$d"
      done
    done
  done
}
collect_ids_for_tmp() {  # ended ids also include tasks whose meta is gone but data/<id> or state/<id>.status remains
  local h f id
  for h in "${homes[@]}"; do
    for f in "$h"/state/*.status; do
      [ -f "$f" ] || continue; id=$(basename "$f" .status)
      case "$(last_word "$f")" in done|failed) [ -f "$h/state/$id.meta" ] || echo "$id" >> "$SCRATCH/ended_ids" ;; esac
    done
    for f in "$h"/data/*/launch-brief.md; do [ -f "$f" ] || continue; id=$(basename "$(dirname "$f")"); [ -f "$h/state/$id.meta" ] || echo "$id" >> "$SCRATCH/ended_ids"; done
  done
  sort -u -o "$SCRATCH/ended_ids" "$SCRATCH/ended_ids"
}

# ---- old clean clones outside projects/
sweep_clones() {
  local base=${FM_SWEEP_HOME_ROOT:-$HOME} g repo ign lastc age
  [ -d "$base" ] || return 0
  while IFS= read -r g; do
    repo=${g%/.git}
    case "$repo" in */.treehouse/*|*/.cache/*|*/.local/*|*/.npm/*|*/node_modules/*|*/.cargo/*|*/.rustup/*) continue ;; esac
    printf '%s' "$repo" | grep -Eq "$PROTECT_RE" && continue
    grep -qxF "$repo" "$SCRATCH/project_dirs" && continue
    under "$repo" "$SCRATCH/live_paths" && continue
    [ -d "$g" ] && [ ! -L "$repo" ] || continue
    case "$repo" in "$base"|"$base"/) continue ;; esac
    if ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then emit clones kept "$repo" 0 "no origin remote"; continue; fi
    [ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ] || { emit clones kept "$repo" 0 "uncommitted changes"; continue; }
    [ -z "$(git -C "$repo" stash list 2>/dev/null)" ] || { emit clones kept "$repo" 0 "has a stash"; continue; }
    [ -z "$(git -C "$repo" log --branches --not --remotes --oneline -n1 2>/dev/null)" ] || { emit clones kept "$repo" 0 "commits not pushed"; continue; }
    [ "$(git -C "$repo" worktree list 2>/dev/null | wc -l | tr -d ' ')" -le 1 ] || { emit clones kept "$repo" 0 "linked worktrees"; continue; }
    ign=$(git -C "$repo" status --porcelain --ignored 2>/dev/null | sed -n 's/^!! //p' \
      | grep -Ev '(^|/)(node_modules|dist|build|\.next|\.turbo|\.cache|target|__pycache__|\.venv|coverage|\.pytest_cache|\.vite)/?$' | head -1)
    [ -z "$ign" ] || { emit clones kept "$repo" 0 "ignored file outside build dirs: $ign"; continue; }
    lastc=$(git -C "$repo" log -1 --format=%ct 2>/dev/null || echo 0); age=$(( ( $(date +%s) - lastc ) / 86400 ))
    if [ "$age" -lt "$clone_days" ] || ! dir_idle "$repo" "$clone_days"; then emit clones kept "$repo" 0 "used within $clone_days days"; continue; fi
    act clones "$repo" "$(bytes_of "$repo")" "clean, all commits pushed, last commit $age days ago" rmtree "$repo"
  done < <(find "$base" -maxdepth 3 -name .git -not -path '*/.*/*' 2>/dev/null | sort)
}

# ============== cleanup expansion: leftovers of the fleet itself (processes, terminals, Chrome tabs, state/ files, awaiting-OK list) ==============
# Every rule here goes through actn: a simulation until armed. Everything it ends is a single pid it re-read right before ending.

task_class() {  # path -> live | ended | none, from the task records and the ids in the path
  local p=$1 seg id t
  if under "$p" "$SCRATCH/live_task_paths"; then echo live; return; fi
  if under "$p" "$SCRATCH/ended_paths"; then echo ended; return; fi
  for seg in $(printf '%s' "$p" | tr '/' ' '); do
    id=${seg#fm-}
    grep -qxF "$id" "$SCRATCH/live_ids" && { echo live; return; }
  done
  for seg in $(printf '%s' "$p" | tr '/' ' '); do
    id=${seg#fm-}
    while IFS= read -r t; do [ -n "$t" ] || continue
      case "$id" in "$t"|"$t"-*) echo ended; return ;; esac
    done < "$SCRATCH/ended_ids"
  done
  echo none
}
ss_snapshot() {  # one socket table: SS_OK=1 when it could be read
  SS_OK=0
  command -v ss >/dev/null 2>&1 || return 0
  ss -Htanp > "$SCRATCH/ss" 2>/dev/null && SS_OK=1
}
pid_conns() {  # pid -> number of established connections owned by that pid
  awk -v p="pid=$1," '$1 == "ESTAB" && index($0, p) { n++ } END { print n + 0 }' "$SCRATCH/ss"
}
is_my_ancestor() {  # pid -> 0 when it is this process or one of its parents
  local p=$$ q=$1
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    [ "$p" = "$q" ] && return 0
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
  done
  return 1
}
tree_pids() {  # pid -> its descendants whose command is a bridge helper, deepest first (a browser or anything else is never listed)
  ps -eo pid=,ppid=,args= 2>/dev/null | awk -v root="$1" '
    { pp[$1] = $2; a = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", a); args[$1] = a; kids[$2] = kids[$2] " " $1 }
    function walk(p,  n, k, i) { n = split(kids[p], k, " "); for (i = 1; i <= n; i++) { walk(k[i]); if (args[k[i]] ~ /chrome-devtools-mcp|chrome-devtools-axi|npm exec|telemetry\/watchdog/) print k[i] } }
    END { walk(root) }'
}

sweep_leftovers() {  # orphan tests, lavish pollers, bridges, preview servers
  local rows rule pid ppid age rss args cwd now_args sess t cls ok kids reason
  [ -d /proc/1 ] || return 0
  collect_ids_for_tmp
  ss_snapshot
  rows=$(ps -eo uid=,pid=,ppid=,etimes=,rss=,comm=,args= 2>/dev/null | awk -v me="$(id -u)" -v pmin="$proc_min_age" -v tmin="$test_min_age" '
    { uid[NR] = $1; pid[NR] = $2; pp[NR] = $3; age[NR] = $4; rss[NR] = $5; comm[$2] = $6; line[NR] = $0 }
    END { for (i = 1; i <= NR; i++) {
            if (uid[i] != me) continue
            orphan = (pp[i] == 1 || comm[pp[i]] == "systemd"); l = line[i]; c = comm[pid[i]]; r = ""
            if (orphan && age[i] >= tmin && c ~ /^(node|bash|sh|npx|npm|pnpm|vitest)$/ && l ~ /(^| |\/)vitest( |$)|node_modules\/vitest/) r = "tests"
            else if (orphan && age[i] >= pmin && c ~ /^(bash|node|sh)$/ && l ~ /fm-procevent-lavish\.sh poll|lavish-axi[^ ]* poll/) r = "lavish"
            else if (age[i] >= pmin && c == "node" && l ~ /chrome-devtools-axi-bridge/) r = "bridges"
            else if (age[i] >= pmin && c ~ /^(python[0-9.]*|node)$/ && l ~ /http\.server|servir\.mjs/) r = "previews"
            if (r != "") print r, pid[i], pp[i], age[i], rss[i] } }')
  while read -r rule pid ppid age rss; do
    [ -n "$pid" ] || continue
    is_my_ancestor "$pid" && continue
    grep -qxF "$pid" "$SCRATCH/handled_pids" 2>/dev/null && continue   # the older process rule above already judged this pid
    args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null); [ -n "$args" ] || continue
    printf '%s' "$args" | grep -Eq "$PROTECT_CORE_RE" && continue
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null); cwd=${cwd% (deleted)}
    printf '%s' "$cwd" | grep -Eq "$PROTECT_CORE_RE" && continue
    [ -z "${FM_SWEEP_PROC_SCOPE:-}" ] || printf '%s %s' "$args" "$cwd" | grep -Eq "$FM_SWEEP_PROC_SCOPE" || continue
    # nothing protected (an agent, a browser, a repo tool) may hang below it
    if ps -eo ppid=,args= 2>/dev/null | awk -v p="$pid" '$1 == p' | grep -Eq "$PROTECT_CORE_RE|(^| )(pi|claude|herdr|no-mistakes)( |$)|/chrome( |$)|/chromium|google-chrome"; then continue; fi
    reason=''; kids=''
    case "$rule" in
      tests)
        under "$cwd" "$SCRATCH/live_task_paths" && continue
        reason="orphan test run (ppid $ppid), up $((age / 60)) min, cwd $cwd" ;;
      lavish)
        reason="orphan lavish poller (ppid $ppid, no supervising runner), up $((age / 60)) min" ;;
      bridges)
        sess=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CHROME_DEVTOOLS_AXI_SESSION=//p' | head -1)
        ok=''
        if [ -n "$sess" ]; then
          grep -qxF "$sess" "$SCRATCH/live_ids" && continue
          while IFS= read -r t; do [ -n "$t" ] || continue
            case "$sess" in "$t"|"$t"-*) ok="its session $sess belongs to ended task $t"; break ;; esac
          done < "$SCRATCH/ended_ids"
        fi
        if [ -z "$ok" ]; then
          [ "${SS_OK:-0}" = 1 ] && [ "$age" -ge $((preview_hours * 3600)) ] && [ "$(pid_conns "$pid")" = 0 ] || continue
          ok="up $((age / 3600)) h with no connection"
        fi
        kids=$(tree_pids "$pid" | tr '\n' ' ')
        reason="chrome-devtools-axi bridge: $ok" ;;
      previews)
        cls=$(task_class "$cwd")
        for t in $args; do   # the directory it serves counts as much as where it was started
          case "$t" in /*) [ "$cls" = live ] || [ "$(task_class "$t")" = none ] || cls=$(task_class "$t") ;; esac
          [ "$cls" = live ] && break
        done
        [ "$cls" = live ] && continue
        if [ "$cls" = ended ]; then reason="preview server of an ended task, cwd $cwd, up $((age / 3600)) h"
        else
          [ "${SS_OK:-0}" = 1 ] && [ "$age" -ge $((preview_hours * 3600)) ] && [ "$(pid_conns "$pid")" = 0 ] || continue
          reason="preview server up $((age / 3600)) h with no connection, no live task around cwd $cwd"
        fi ;;
    esac
    now_args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    [ "$now_args" = "$args" ] || continue
    if [ -n "$kids" ]; then
      # shellcheck disable=SC2086
      actn "$rule" "pid $pid ${args:0:100}" $(( ${rss:-0} * 1024 )) "$reason" endprocs $kids "$pid"
    else
      actn "$rule" "pid $pid ${args:0:100}" $(( ${rss:-0} * 1024 )) "$reason" endproc "$pid"
    fi
  done <<< "$rows"
}

# ---- Herdr terminals: the proof and the close belong to fm-herdr-session-cleanup.sh --sweep-idle
sweep_panes() {
  local cleaner="$root/bin/fm-herdr-session-cleanup.sh" h line c st o b r
  local -a args
  [ -x "$cleaner" ] && [ "${#homes[@]}" -gt 0 ] || return 0
  args=(--sweep-idle --idle-hours "$pane_idle_hours")
  [ "$apply" = 1 ] && [ "$armed" = 1 ] && args+=(--apply)
  for h in "${homes[@]}"; do args+=(--meta-dir "$h/state"); done
  while IFS=$'\t' read -r line c st o b r; do
    [ "$line" = ITEM ] || continue
    if [ "$apply" = 1 ] && [ "$armed" = 0 ] && [ "$st" = would ]; then r="$r (rules not armed: simulation)"; fi
    emit "$c" "$st" "$o" "$b" "$r"
  done < <(FM_HOME="${homes[0]}" to 300 "$cleaner" "${args[@]}" 2>/dev/null)
}

# ---- tabs of the shared Chrome (CDP): first seen is kept in the home's state/, the tab ids stay stable while the browser runs
sweep_chrome() {
  local port=${FM_SWEEP_CHROME_PORT:-9222} base list rows id url title mark now first n clients line live=''
  local sdir=${homes[0]:-}/state
  [ -n "${homes[0]:-}" ] && [ -d "$sdir" ] || return 0
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  base="http://127.0.0.1:$port"
  list=$(to 8 curl -fsS --max-time 6 "$base/json/list" 2>/dev/null) || return 0
  rows=$(printf '%s' "$list" | jq -r '.[]? | select(.type == "page") | [.id, .url, .title] | @tsv' 2>/dev/null) || return 0
  [ -n "$rows" ] || return 0
  now=$(date +%s); n=$(printf '%s\n' "$rows" | grep -c .)
  clients=0
  if command -v ss >/dev/null 2>&1; then clients=$(ss -Htn state established "( sport = :$port )" 2>/dev/null | grep -c .); else clients=1; fi
  while IFS=$'\t' read -r id url title; do
    [ -n "$id" ] || continue
    case "$id" in *[!A-Za-z0-9_-]*) continue ;; esac
    live="$live $id"
    mark="$sdir/.sweep-chrome-tab-$port-$id"
    [ -f "$mark" ] || { echo "$now" > "$mark"; emit chrome kept "tab $id" 0 "first seen now: needs $chrome_hours h of observation"; continue; }
    first=$(cat "$mark" 2>/dev/null); first=${first:-$now}
    if [ "$clients" != 0 ]; then emit chrome kept "tab $id" 0 "a CDP client is connected to port $port"; continue; fi
    printf '%s %s' "$url" "$title" | grep -Eq "$PROTECT_CORE_RE" && { emit chrome kept "tab $id" 0 "owner profile or app page"; continue; }
    [ $((now - first)) -ge $((chrome_hours * 3600)) ] || { emit chrome kept "tab $id" 0 "open $(( (now - first) / 3600 )) h of $chrome_hours h"; continue; }
    [ "$n" -gt 1 ] || { emit chrome kept "tab $id" 0 "the last tab"; continue; }
    actn chrome "tab $id ${url:0:80}" 0 "tab open $(( (now - first) / 3600 )) h on shared Chrome port $port with no client connected" \
      curl -fsS --max-time 6 -X PUT "$base/json/close/$id"
    n=$((n - 1))
  done <<< "$rows"
  # markers of tabs that are gone
  for line in "$sdir"/.sweep-chrome-tab-"$port"-*; do
    [ -f "$line" ] || continue
    id=${line##*/.sweep-chrome-tab-"$port"-}
    case " $live " in *" $id "*) ;; *) rm -f -- "$line" ;; esac
  done
}

# ---- leftovers in <home>/state
window_keys_of() {  # home -> the v3 marker suffix of every window a task record names
  local m w d
  for m in "$1"/state/*.meta; do
    [ -f "$m" ] || continue
    for w in "$(meta_val "$m" window)" "$(meta_val "$m" terminal)"; do
      [ -n "$w" ] || continue
      if command -v sha256sum >/dev/null 2>&1; then d=$(printf '%s' "$w" | sha256sum); else d=$(printf '%s' "$w" | shasum -a 256); fi
      printf 'v3.%s\n' "${d%% *}"
    done
  done
}
sweep_statefiles() {
  local h s f name suffix key keys decoded now bytes
  now=$(date +%s)
  for h in "${homes[@]}"; do
    s="$h/state"; [ -d "$s" ] || continue
    keys=$(window_keys_of "$h")
    # the watcher's per-window marker families (bin/fm-watch-key-lib.sh); only the retired key scheme, or a v3 key no record names
    for f in "$s"/.hash-* "$s"/.count-* "$s"/.stale-* "$s"/.stale-since-* "$s"/.churn-since-* "$s"/.dead-reported-* "$s"/.paused-* "$s"/.writing-since-* "$s"/.validating-since-*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      name=${f##*/}
      case "$name" in
        .stale-since-*) suffix=${name#.stale-since-} ;;
        .churn-since-*) suffix=${name#.churn-since-} ;;
        .dead-reported-*) suffix=${name#.dead-reported-} ;;
        .writing-since-*) suffix=${name#.writing-since-} ;;
        .validating-since-*) suffix=${name#.validating-since-} ;;
        .paused-*) suffix=${name#.paused-} ;;
        .hash-*) suffix=${name#.hash-} ;;
        .count-*) suffix=${name#.count-} ;;
        .stale-*) suffix=${name#.stale-} ;;
      esac
      case "$suffix" in
        v3.*)
          printf '%s\n' "$keys" | grep -qxF "$suffix" && continue
          [ -z "$(find "$f" -mtime -3 -print -quit 2>/dev/null)" ] || continue
          actn state "$f" "$(bytes_of "$f")" "watcher marker of a window no task record names, untouched 3+ days" rmtree "$f" ;;
        *)
          [ -z "$(find "$f" -mtime -1 -print -quit 2>/dev/null)" ] || continue
          actn state "$f" "$(bytes_of "$f")" "watcher marker of the retired non-v3 key scheme, untouched 1+ day" rmtree "$f" ;;
      esac
    done
    # dedup records of process events: kept while their key can still be queued
    for f in "$s"/.seen-procevent-*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      [ -z "$(find "$f" -mtime -7 -print -quit 2>/dev/null)" ] || continue
      key=${f##*/.seen-procevent-}
      case "$key" in ''|*[!0-9a-f]*) continue ;; esac
      decoded=$(printf '%b' "$(printf '%s' "$key" | sed 's/../\\x&/g')")
      [ -n "$decoded" ] || continue
      grep -qF -- "$decoded" "$s/.wake-queue" 2>/dev/null && continue
      actn state "$f" "$(bytes_of "$f")" "process-event dedup record untouched 7+ days, its key is not in the wake queue" rmtree "$f"
    done
    # temporaries a crashed writer left behind
    for f in "$s"/*.tmp.* "$s"/.*.tmp.*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      [ -z "$(find "$f" -mtime -1 -print -quit 2>/dev/null)" ] || continue
      bytes=$(bytes_of "$f")
      actn state "$f" "$bytes" "temporary file untouched 1+ day" rmtree "$f"
    done
  done
}

# ---- what only the owner may decide: listed, never touched
sweep_asks() {
  local h d n id st f dir b
  for h in "${homes[@]}"; do
    n=0
    for d in "$h"/data/*/; do
      [ -d "$d" ] && [ ! -L "${d%/}" ] || continue
      id=$(basename "$d")
      grep -qxF "$id" "$SCRATCH/live_ids" && continue
      [ -z "$(find "$d" -mtime -30 -print -quit 2>/dev/null)" ] || continue
      n=$((n + 1))
    done
    [ "$n" = 0 ] || emit ask listed "datadirs:$h/data" 0 "$n data/<id> folder(s) untouched 30+ days"
    for f in "$h"/state/*.status; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .status); st=$(last_word "$f")
      case "$st" in needs-decision|blocked|paused) ;; *) continue ;; esac
      [ -f "$h/state/$id.meta" ] || continue
      [ -z "$(find "$f" -mtime -3 -print -quit 2>/dev/null)" ] || continue
      emit ask listed "parked:$h:$id" 0 "task parked on $st for 3+ days"
    done
  done
  for dir in "$HOME/.claude/projects" "$HOME/.claude-conta2/projects"; do
    [ -d "$dir" ] || continue
    left 30 || break
    n=$(find "$dir" -name '*.jsonl' -mtime +30 2>/dev/null | grep -c .)
    [ "$n" = 0 ] || emit ask listed "transcripts:$dir" 0 "$n transcript(s) older than 30 days"
  done
  for dir in "$HOME/.npm" "$HOME/.cache"; do
    [ -d "$dir" ] || continue
    left 60 || break
    b=$(to 60 du -sk "$dir" 2>/dev/null | awk '{print $1}'); b=$(( ${b:-0} * 1024 ))
    [ "$b" -lt 1073741824 ] || emit ask listed "caches:$dir" "$b" "cache above 1 GB"
  done
}

# ============================== orchestrator: runs on the main machine ==============================
orchestrate_main() {
  local fmroot fmhome hostsf conf name k target hroot hhomes htest
  fmroot="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "$SELF")/.." && pwd)}"
  fmhome="${FM_HOME:-$fmroot}"
  hostsf="${FM_SWEEP_HOSTS:-$fmhome/config/host-sweep.hosts}"
  conf="$fmhome/config/host-sweep.conf"
  [ -n "$removed_log" ] || removed_log="$fmhome/data/sweep/removed.tsv"
  [ ! -f "$fmhome/config/host-sweep.rules-armed" ] || armed=1
  local globs=() l
  if [ -f "$conf" ]; then while read -r k l; do [ "$k" = dead-glob ] && globs+=("$l"); done < "$conf"; fi
  [ "${#globs[@]}" -gt 0 ] || globs=('@HOME@/data/pod-logs-*' '@HOME@/data/pod-suites/*' '@TMP@/podsuite.*')
  local specs
  if [ -f "$hostsf" ]; then specs=$(grep -Ev '^[[:space:]]*(#|$)' "$hostsf")
  else
    local lh="$fmhome" m
    for m in "$fmhome"/state/*.meta; do
      [ -f "$m" ] || continue
      [ "$(meta_val "$m" kind)" = secondmate ] && [ -z "$(meta_val "$m" remote_host)" ] && [ -n "$(meta_val "$m" home)" ] && lh="$lh,$(meta_val "$m" home)"
    done
    specs="main vps local $fmroot $lh
creative vps creative-vps-factory /home/factory/firstmate /home/factory/firstmate-aux-home,/home/factory/firstmate-pm-sm-home,/home/factory/firstmate-mc-sm-home
pc pc pc-aux /home/sadvi/firstmate-aux2 /home/sadvi/firstmate-aux2-home
mac mac ${FM_SWEEP_MAC_SSH:-none} - - ${FM_SWEEP_MAC_TESTDIRS:--}"
  fi
  if [ "$apply" = 1 ]; then
    mkdir -p "$(dirname "$removed_log")"
    [ -s "$removed_log" ] || printf 'time\thost\tcategory\tobject\tbytes\treason\n' >> "$removed_log"
  fi
  printf '== fm-host-sweep %s%s pass=%s %s\n' "$([ $apply = 1 ] && echo apply || echo dry-run)" "$([ $armed = 1 ] || echo ' (new rules not armed)')" "$pass" "$(date -u +%FT%TZ)"
  printf '%-10s %-9s %6s %6s %6s %6s %10s  %s\n' machine status lanes procs branch tmp+ MB "other (pool/clones)"
  # machines run in parallel; each writes its block and its removal rows to files that are joined in order
  local outdir names='' mname
  outdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-host-sweep-out.XXXXXX") || exit 1
  while read -r name k target hroot hhomes htest; do
    [ -n "$name" ] || continue
    if [ "${#only_hosts[@]}" -gt 0 ]; then case " ${only_hosts[*]} " in *" $name "*) ;; *) continue ;; esac; fi
    names="$names $name"
    sweep_host "$name" "$k" "$target" "$hroot" "$hhomes" "${htest:-}" "${globs[@]}" > "$outdir/$name.out" 2> /dev/null < /dev/null &
  done <<< "$specs"
  wait
  for mname in $names; do cat "$outdir/$mname.out"; [ ! -f "$outdir/$mname.removed" ] || cat "$outdir/$mname.removed" >> "$removed_log"; done
  [ "$apply" = 1 ] && [ "$notify" = 1 ] && notify_primary "$outdir" "$fmroot" "$fmhome"
  rm -rf "$outdir"
  printf 'audit log: %s (removals are appended on --apply)\n' "$removed_log"
}

# ONE line for the primary when a round removed something or an item waits for the owner's OK; nothing for an empty round.
# An unchanged waiting list alone is repeated at most once a day (marker in the home's state/).
notify_primary() {  # outdir fmroot fmhome
  local items line cmd mark text clean ask now prev_t prev_e
  items=$(cat "$1"/*.items 2>/dev/null)
  clean=$(printf '%s\n' "$items" | awk -F'\t' '
    $1 == "ITEM" && $3 == "removed" { g = $2
      if (g == "panes") g = "terminais"; else if (g == "lanes") g = "agentes"
      else if (g == "procs" || g == "lavish" || g == "bridges" || g == "previews") g = "processos"
      else if (g == "chrome") g = "abas"; else if (g == "state") g = "arquivos de state"
      else if (g == "branches") g = "branches"; else g = "pastas"
      n[g]++; bytes += $5 }
    END { sep = ""; for (k in n) { printf "%s%d %s", sep, n[k], k; sep = ", " }
          if (bytes >= 1048576) { gb = bytes / 1073741824; if (gb >= 0.1) { s = sprintf("%.1f", gb); sub(/\./, ",", s); printf "%s%s GB", sep, s } else printf "%s%d MB", sep, bytes / 1048576 } }')
  ask=$(printf '%s\n' "$items" | awk -F'\t' '
    $1 == "ITEM" && $3 == "listed" { t = $4; sub(/:.*/, "", t)
      if (t == "branch") t = "branches"; else if (t == "dirty-worktree") t = "worktrees sujos"; else if (t == "datadirs") t = "pastas data/ antigas"
      else if (t == "transcripts") t = "pastas de transcricoes antigas"; else if (t == "caches") t = "caches grandes"; else if (t == "parked") t = "tarefas paradas"
      n[t]++ }
    END { sep = ""; for (k in n) { printf "%s%d %s", sep, n[k], k; sep = ", " } }')
  [ -n "$clean" ] || [ -n "$ask" ] || return 0
  text=''
  [ -z "$clean" ] || text="limpei: $clean"
  if [ -n "$ask" ]; then
    mark="$3/state/.host-sweep-ask-notified"; now=$(date +%s)
    if [ -z "$clean" ] && [ -f "$mark" ]; then
      prev_e=$(head -n1 "$mark" 2>/dev/null); prev_t=$(sed -n 2p "$mark" 2>/dev/null)
      if [ "$prev_t" = "$ask" ] && [ $((now - ${prev_e:-0})) -lt 86400 ]; then return 0; fi
    fi
    mkdir -p "$3/state" 2>/dev/null && printf '%s\n%s\n' "$now" "$ask" > "$mark"
    text="${text:+$text · }esperando seu OK: $ask"
  fi
  cmd=${FM_SWEEP_NOTIFY_CMD:-$2/bin/fm-inbox.sh note}
  # shellcheck disable=SC2086
  FM_HOME="$3" $cmd "fm-host-sweep: $text" >/dev/null 2>&1 || true
}

sweep_host() {  # name kind target root homes testdirs globs...
  local name=$1 k=$2 target=$3 hroot=$4 hhomes=$5 htest=$6; shift 6
  local -a wargs=(--worker --kind "$k" --budget "$budget" --idle-hours "$idle_hours" --tmp-days "$tmp_days" --clone-days "$clone_days"
    --max-lanes "$max_lanes" --pool-keep "$pool_keep" --proc-min-age "$proc_min_age" --pass "$pass" --pane-idle-hours "$pane_idle_hours"
    --chrome-hours "$chrome_hours" --preview-hours "$preview_hours" --test-min-age "$test_min_age")
  local out rc=0 h t g status=ok line
  [ "$apply" = 1 ] && wargs+=(--apply)
  [ "$armed" = 1 ] && wargs+=(--armed)
  [ "$remote_branches" = 1 ] && wargs+=(--remote-branches)
  [ "$clones" = 1 ] || wargs+=(--no-clones)
  [ "$hroot" = - ] || wargs+=(--root "$hroot")
  for h in $(printf '%s' "$hhomes" | tr ',' ' '); do [ "$h" = - ] || wargs+=(--home "$h"); done
  for t in $(printf '%s' "$htest" | tr ',' ' '); do [ "$t" = - ] || wargs+=(--testdir "$t"); done
  for g in "$@"; do wargs+=(--dead-glob "$g"); done
  case "$target" in
    none|'') printf '%-10s %-9s no ssh target configured (set FM_SWEEP_MAC_SSH or config/host-sweep.hosts)\n' "$name" unknown; return 0 ;;
    local) out=$(timeout "$((budget + 180))" bash "$SELF" "${wargs[@]}" 2>/dev/null </dev/null) || rc=$? ;;
    *)
      local q; q=$(printf '%q ' "${wargs[@]}")
      # shellcheck disable=SC2086
      out=$(timeout "$((budget + 180))" ${FM_SWEEP_SSH_CMD:-ssh} -o BatchMode=yes -o ConnectTimeout="${FM_SWEEP_SSH_TIMEOUT:-10}" -o ServerAliveInterval=15 "$target" "bash -s -- $q" < "$SELF" 2>/dev/null) || rc=$? ;;
  esac
  if [ "$rc" != 0 ] && ! printf '%s\n' "$out" | grep -q '^ITEM'; then
    printf '%-10s %-9s did not answer (exit %s)\n' "$name" unreachable "$rc"; return 0
  fi
  [ "$rc" = 0 ] || status=partial
  printf '%s\n' "$out" > "$outdir/$name.items"
  local n_l n_p n_b n_t mb other listed
  n_l=$(printf '%s\n' "$out" | awk -F'\t' '$1=="ITEM"&&$2=="lanes"&&($3=="would"||$3=="removed")' | wc -l | tr -d ' ')
  n_p=$(printf '%s\n' "$out" | awk -F'\t' '$1=="ITEM"&&$2=="procs"&&($3=="would"||$3=="removed")' | wc -l | tr -d ' ')
  n_b=$(printf '%s\n' "$out" | awk -F'\t' '$1=="ITEM"&&$2=="branches"&&($3=="would"||$3=="removed")' | wc -l | tr -d ' ')
  n_t=$(printf '%s\n' "$out" | awk -F'\t' '$1=="ITEM"&&$2=="tmp"&&($3=="would"||$3=="removed")' | wc -l | tr -d ' ')
  other=$(printf '%s\n' "$out" | awk -F'\t' '$1=="ITEM"&&($3=="would"||$3=="removed")&&$2!="lanes"&&$2!="procs"&&$2!="branches"&&$2!="tmp"{c[$2]++} END{printf "pool %d, clones %d", c["pool"], c["clones"]; for (k in c) if (k != "pool" && k != "clones") printf ", %s %d", k, c[k]}')
  listed=$(printf '%s\n' "$out" | awk -F'\t' '$1=="ITEM"&&$3=="listed"' | wc -l | tr -d ' ')
  mb=$(printf '%s\n' "$out" | awk -F'\t' '$1=="ITEM"&&($3=="would"||$3=="removed"){s+=$5} END{printf "%d", s/1048576}')
  printf '%-10s %-9s %6s %6s %6s %6s %10s  %s\n' "$name" "$status" "$n_l" "$n_p" "$n_b" "$n_t" "$mb" "$other"
  local kept failed
  kept=$(printf '%s\n' "$out" | awk -F'\t' '$1=="ITEM"&&$3=="kept"' | wc -l | tr -d ' ')
  failed=$(printf '%s\n' "$out" | awk -F'\t' '$1=="ITEM"&&$3=="failed"' | wc -l | tr -d ' ')
  printf '           kept %s, refused %s, waiting for the owner'"'"'s OK %s%s\n' "$kept" "$failed" "$listed" "$([ $apply = 1 ] && echo '' || echo ' (columns count what WOULD go)')"
  printf '%s\n' "$out" | awk -F'\t' -v v="$verbose" '$1=="ITEM"&&($3=="would"||$3=="failed"||$3=="listed"||(v&&$3=="kept")){printf "           %s %s %s (%d MB): %s\n", $3, $2, $4, $5/1048576, $6}' | head -40
  if [ "$apply" = 1 ]; then
    printf '%s\n' "$out" | awk -F'\t' -v t="$(date -u +%FT%TZ)" -v h="$name" '$1=="ITEM"&&$3=="removed"{printf "%s\t%s\t%s\t%s\t%s\t%s\n", t, h, $2, $4, $5, $6}' > "$outdir/$name.removed"
  fi
}

if [ "$MODE" = worker ]; then
  export GIT_OPTIONAL_LOCKS=0   # read-only git calls must not refresh an index and so look like use
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-host-sweep.XXXXXX") || exit 1
  trap 'rm -rf "$SCRATCH"' EXIT
  collect_task_sets
  worker_main
  exit 0
fi
orchestrate_main
exit 0
