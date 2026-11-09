#!/usr/bin/env bash
# fm-spawn-task.sh - file the task, write its brief from a task+spec pair, resolve the profile, spawn, and prove the
# worker started, as ONE command with ONE result line. It replaces the hand-copied spawn helpers (spawn-rvf, spawn-imp, spawn-pm).
#
# Usage: fm-spawn-task.sh ship  <task-id> <project> --title T --mode <mode> --yolo on|off (--files PREFIX | --task FILE --spec FILE)
#                         [--branch-prefix P] [--base-branch B] [harness options] [--project-dir DIR] [--no-verify] [--dry-run] [-- <fm-spawn args>]
#        fm-spawn-task.sh scout <task-id> <project> --title T (--files PREFIX | --task FILE --spec FILE) [--base-branch B] [harness options] ...
#   --files PREFIX  reads PREFIX.task (the `## Captain's intent` fill) and PREFIX.spec (the `## Firstmate spec` fill)
#   harness options  --harness H [--model M] [--effort E]. Without them bin/fm-dispatch-resolve.sh decides: a `clear` profile is
#                    used, nothing configured (off) leaves the static harness, and any other status REFUSES with the intake needed
#                    (the quota-array choice stays with firstmate; this command never guesses a profile)
#   --mode/--yolo/--branch-prefix are the delivery contract firstmate resolved at intake; they are required for a ship and
#   refused for a scout, exactly as bin/fm-brief.sh and bin/fm-spawn.sh enforce. <project> is the registered name; its clone
#   is projects/<project> (the firstmate repo itself is the home), or --project-dir.
# Steps (the first failure stops the rest and prints one REFUSED line; nothing is bypassed or forced):
#   1 backlog  bin/fm-tasks-axi.sh show || add  (--kind ship|scout --repo <project> --title T)
#   2 brief    bin/fm-brief.sh scaffold, then the task and spec fill the two placeholders (each must appear exactly once)
#   3 profile  explicit options, else bin/fm-dispatch-resolve.sh (see above)
#   4 spawn    bin/fm-spawn.sh with the delivery contract and profile; its own refusals (capacity 75, isolation, brief
#              checks) are the result. A refused spawn keeps the filled brief, so re-running the same command resumes at step 3
#   5 verify   data/tools/fm-verify-launch.sh <id>: the worker really processed the brief (skip only with --no-verify)
# Output: one line.
#   SPAWNED <id> kind=<k> project=<p> profile=<...> verify=<OK ...|skipped>
#   DRY-RUN-OK <id> kind=<k> project=<p> would=<steps>
#   REFUSED <id>: <step>: <reason> [log: <file>]
# Exit: 0 spawned (or dry-run ok), 1 refused, 2 usage, 75 passed through when the spawn was deferred by capacity.
# Env: FM_HOME, FM_SPAWN_TASK_BIN (dir holding fm-tasks-axi.sh fm-brief.sh fm-dispatch-resolve.sh fm-spawn.sh, default bin/),
#      FM_VERIFY_LAUNCH (default $FM_HOME/data/tools/fm-verify-launch.sh).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$HERE/.." && pwd)}; export FM_HOME
BIN=${FM_SPAWN_TASK_BIN:-$HERE}
VERIFY=${FM_VERIFY_LAUNCH:-$FM_HOME/data/tools/fm-verify-launch.sh}
usage() { sed -n 2,13p "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

kind=${1:-}; id=${2:-}; project=${3:-}
case "$kind" in ship|scout) ;; -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; *) usage ;; esac
[ -n "$id" ] && [ -n "$project" ] || usage
shift 3
title=""; mode=""; yolo=""; bprefix=""; bbase=""; taskf=""; specf=""; pdir=""; harness=""; model=""; effort=""
verify=1; dry=0; extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --title|--mode|--yolo|--branch-prefix|--base-branch|--task|--spec|--files|--project-dir|--harness|--model|--effort)
      [ $# -ge 2 ] || usage ;;
  esac
  case "$1" in
    --title) title=$2; shift 2 ;;
    --mode) mode=$2; shift 2 ;;
    --yolo) yolo=$2; shift 2 ;;
    --branch-prefix) bprefix=$2; shift 2 ;;
    --base-branch) bbase=$2; shift 2 ;;
    --task) taskf=$2; shift 2 ;;
    --spec) specf=$2; shift 2 ;;
    --files) taskf=$2.task; specf=$2.spec; shift 2 ;;
    --project-dir) pdir=$2; shift 2 ;;
    --harness) harness=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --effort) effort=$2; shift 2 ;;
    --no-verify) verify=0; shift ;;
    --dry-run) dry=1; shift ;;
    --) shift; extra=("$@"); break ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
[ -n "$title" ] && [ -r "$taskf" ] && [ -r "$specf" ] || { echo "REFUSED $id: usage: --title and readable task and spec files are required"; exit 2; }
if [ "$kind" = ship ]; then
  case "$yolo" in on|off) ;; *) mode="" ;; esac
  [ -n "$mode" ] || { echo "REFUSED $id: a ship needs --mode and --yolo on|off from the intake"; exit 2; }
else
  [ -z "$mode$yolo$bprefix" ] || { echo "REFUSED $id: --mode, --yolo and --branch-prefix are refused for a scout"; exit 2; }
fi
if [ -z "$pdir" ]; then
  if [ "$project" = firstmate ]; then pdir=$FM_HOME; else pdir=$FM_HOME/projects/$project; fi
fi
[ -d "$pdir" ] || { echo "REFUSED $id: project directory not found: $pdir"; exit 1; }
for t in fm-tasks-axi fm-brief fm-dispatch-resolve fm-spawn; do [ -x "$BIN/$t.sh" ] || { echo "REFUSED $id: $BIN/$t.sh is missing"; exit 1; }; done
[ $verify = 0 ] || [ -x "$VERIFY" ] || { echo "REFUSED $id: the launch check $VERIFY is missing (use --no-verify only on purpose)"; exit 1; }

DATA=$FM_HOME/data/$id; BRIEF=$DATA/brief.md; META=$FM_HOME/state/$id.meta
LOG=$(mktemp "${TMPDIR:-/tmp}/fm-spawn-task.XXXXXX"); created=0; launched=0
trap '[ $created = 1 ] && [ $launched = 0 ] && [ "${keep_brief:-0}" = 0 ] && rm -rf "$DATA"' EXIT
refused() { echo "REFUSED $id: $1: $2 [log: $LOG]"; exit "${3:-1}"; }
last() { grep -v '^WARNING' "$1" | grep . | tail -1 | cut -c1-220; }
unfilled() { grep -c '{TASK}\|{FIRSTMATE_SPEC}' "$BRIEF"; }

if [ -e "$META" ]; then refused precheck "the task is already live (state/$id.meta)"; fi
reuse=0
if [ -e "$DATA" ]; then
  if [ -s "$BRIEF" ] && [ "$(unfilled)" = 0 ]; then reuse=1
  else refused precheck "data/$id exists without a complete brief; move it aside or pick another id"; fi
fi
if [ $dry = 1 ]; then
  echo "DRY-RUN-OK $id kind=$kind project=$project would=backlog,$([ $reuse = 1 ] && echo reuse-brief || echo brief+fill),profile,spawn$([ $verify = 1 ] && echo ,verify)"
  rm -f "$LOG"; exit 0
fi

# 1 backlog
if ! "$BIN/fm-tasks-axi.sh" show "$id" >/dev/null 2>&1; then
  "$BIN/fm-tasks-axi.sh" add "$id" --kind "$kind" --repo "$project" --title "$title" >"$LOG" 2>&1 || refused backlog "$(last "$LOG")"
fi
# 2 brief
if [ $reuse = 0 ]; then
  created=1
  if [ "$kind" = ship ]; then
    bargs=(--mode "$mode"); [ -z "$bprefix" ] || bargs+=(--branch-prefix "$bprefix")
  else bargs=(--scout); fi
  [ -z "$bbase" ] || bargs+=(--base-branch "$bbase")
  "$BIN/fm-brief.sh" "$id" "$project" "${bargs[@]}" >"$LOG" 2>&1 || refused brief "$(last "$LOG")"
  python3 -I - "$BRIEF" "$taskf" "$specf" >>"$LOG" 2>&1 <<'PY' || refused fill "$(last "$LOG")"
import sys
p, tf, sf = sys.argv[1:4]
t = open(p).read()
task, spec = open(tf).read().strip(), open(sf).read().strip()
if not task or not spec:
    sys.exit("the task and the spec must both be non-empty")
if t.count("{TASK}") != 1 or t.count("{FIRSTMATE_SPEC}") != 1:
    sys.exit("the scaffold does not carry exactly one {TASK} and one {FIRSTMATE_SPEC}")
open(p, "w").write(t.replace("{TASK}", task).replace("{FIRSTMATE_SPEC}", spec))
PY
  [ "$(unfilled)" = 0 ] || refused fill "placeholders left in the brief (the task or spec text contains one)"
fi
keep_brief=1   # from here a refusal keeps the filled brief, so the same command resumes

# 3 profile
prof=()
if [ -n "$harness" ]; then
  prof=(--harness "$harness"); [ -z "$model" ] || prof+=(--model "$model"); [ -z "$effort" ] || prof+=(--effort "$effort")
else
  res=$("$BIN/fm-dispatch-resolve.sh" "$BRIEF" 2>>"$LOG"); rrc=$?; echo "$res" >> "$LOG"
  [ $rrc = 0 ] || refused profile "fm-dispatch-resolve exited $rrc: $(last "$LOG")"
  if [ -n "$res" ]; then
    status=$(sed -n 's/^ *status: *//p' <<<"$res" | head -1)
    [ "$status" = clear ] || refused profile "dispatch status '${status:-unknown}': firstmate must choose the profile at intake, then pass --harness/--model/--effort"
    read -r -a prof < <(sed -n 's/^ *profile: *//p' <<<"$res" | head -1)
  fi
fi

# 4 spawn
if [ "$kind" = ship ]; then sargs=("$id" "$pdir" --mode "$mode" --yolo "$yolo"); [ -z "$bprefix" ] || sargs+=(--branch-prefix "$bprefix")
else sargs=("$id" "$pdir" --scout); fi
[ -z "$bbase" ] || sargs+=(--base-branch "$bbase")
"$BIN/fm-spawn.sh" "${sargs[@]}" "${prof[@]}" "${extra[@]}" >>"$LOG" 2>&1; src=$?
[ $src = 0 ] || { launched=1; refused spawn "fm-spawn exited $src: $(last "$LOG")" "$([ $src = 75 ] && echo 75 || echo 1)"; }
launched=1

# 5 verify
vres=skipped
if [ $verify = 1 ]; then
  vres=$("$VERIFY" "$id" 2>&1 | tail -1 | cut -c1-120)
  case "$vres" in OK*) ;; *) refused verify "the worker did not start: ${vres:-no output} (spawned; check with bin/fm-peek.sh $id)" ;; esac
fi
echo "SPAWNED $id kind=$kind project=$project profile=${prof[*]:-static} verify=$vres"
rm -f "$LOG"; exit 0
