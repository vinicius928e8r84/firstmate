#!/usr/bin/env bash
# fm-place.sh - choose the machine (home) that should run a new worker, from the
# lane facts every home publishes and the captain's affinity table. No model.
#
# Usage:
#   fm-place.sh --type <task-type> [--needs <a,b,...>] [--json] [--dry-run]
#   fm-place.sh --spawn-mode          print off, dry-run or on (bin/fm-spawn.sh's check)
#
# It reads config/placement (docs/configuration.md "Task placement" owns the
# format), then each candidate home's published fm-lane-capacity.v1 document.
# It never spawns, locks or writes anything, so every call is already a dry run;
# --dry-run is accepted so the intent reads plainly in a command line.
#
# A machine is dropped, with its reason printed, when any of these holds:
#   - the task type does not list it (the affinity table), or it is marked hold;
#   - its facts are unreadable, not fm-lane-capacity.v1, or older than max-age;
#   - its own verdict does not admit, or it has no free lane (verdict.free_lanes,
#     else cap target minus lanes);
#   - it is an owner-pc and the task is heavy while the published captain state is
#     not idle or away (an unknown state counts as present);
#   - it is an owner-pc and --needs names anki, opera, adspower, dolphin or port
#     8766. That last rule is built in and no config line lifts it.
# Among the rest the most free lanes wins, then the lowest load per core, then the
# machine named first on the type's line.
#
# Facts come from the machine's home: `self` is this home (state/lane-capacity.json
# when fresh, else bin/fm-capacity.sh --json), any other home id is a remote
# secondmate read through fm-on.sh and fm-remote-file.sh exactly as bin/fm-overflow.sh
# does, so this adds no transport.
#
# Output (stdout): `picked machine=<label> home=<id> host=<alias|local> free=<n>
# type=<t> weight=<light|heavy>` or `none type=<t>`, then one `skipped: <label> (<why>)`
# line per dropped machine. --json prints the same as one object.
# Exit: 0 picked, 1 none placeable, 2 usage or config error (a reason on stderr).
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE as in the other bin/
# scripts; FM_PLACE_ON (the fm-on.sh command), FM_PLACE_CAPACITY (the fm-capacity.sh
# command) and FM_PLACE_READ_TIMEOUT (seconds per remote read, default 30).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONF="$CONFIG/placement"
ON="${FM_PLACE_ON:-$SCRIPT_DIR/fm-on.sh}"
CAPACITY="${FM_PLACE_CAPACITY:-$SCRIPT_DIR/fm-capacity.sh}"
READ_TIMEOUT="${FM_PLACE_READ_TIMEOUT:-30}"
TAB=$(printf '\t')

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
die() { echo "fm-place: $1" >&2; exit 2; }
case "$READ_TIMEOUT" in ''|*[!0-9]*) READ_TIMEOUT=30 ;; esac

type_arg='' needs='' json=0 spawn_mode=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --type) [ $# -ge 2 ] || usage; type_arg=$2; shift 2 ;;
    --needs) [ $# -ge 2 ] || usage; needs=$2; shift 2 ;;
    --json) json=1; shift ;;
    --dry-run) shift ;;
    --spawn-mode) spawn_mode=1; shift ;;
    *) usage ;;
  esac
done

# --- config/placement ---------------------------------------------------------

SPAWN=off MAX_AGE=600
MACHINES=   # one "label home flags" per line, flags comma-separated or -
TYPES=      # one "name weight label label..." per line
seen_spawn=0 seen_age=0

machine_line() { printf '%s\n' "$MACHINES" | awk -v l="$1" '$1 == l { print; exit }'; }

parse_config() {
  local lineno=0 line key rest label home flags f name weight
  [ -f "$CONF" ] || return 0
  [ -r "$CONF" ] || die "$CONF cannot be read"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%#*}
    # shellcheck disable=SC2086 # word splitting is the tokenizer
    set -- $line
    [ $# -gt 0 ] || continue
    key=$1; shift
    case "$key" in
      spawn)
        [ $# -eq 1 ] && [ "$seen_spawn" -eq 0 ] || die "$CONF line $lineno: spawn takes one value, once"
        case "$1" in off|dry-run|on) SPAWN=$1 ;; *) die "$CONF line $lineno: spawn must be off, dry-run or on" ;; esac
        seen_spawn=1 ;;
      max-age)
        [ $# -eq 1 ] && [ "$seen_age" -eq 0 ] || die "$CONF line $lineno: max-age takes one value, once"
        case "$1" in ''|*[!0-9]*) die "$CONF line $lineno: max-age needs a number of seconds" ;; esac
        MAX_AGE=$1; seen_age=1 ;;
      machine)
        [ $# -ge 2 ] || die "$CONF line $lineno: machine needs <label> <home|self> [owner-pc] [hold]"
        label=$1 home=$2; shift 2
        [[ $label =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "$CONF line $lineno: bad machine label '$label'"
        [[ $home =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "$CONF line $lineno: bad home '$home'"
        [ -z "$(machine_line "$label")" ] || die "$CONF line $lineno: machine $label is declared twice"
        flags=-
        for f in "$@"; do
          case "$f" in owner-pc|hold) flags=$([ "$flags" = - ] && echo "$f" || echo "$flags,$f") ;; *) die "$CONF line $lineno: unknown machine flag '$f'" ;; esac
        done
        MACHINES="$MACHINES$label $home $flags
" ;;
      type)
        [ $# -ge 3 ] || die "$CONF line $lineno: type needs <name> light|heavy <label>..."
        name=$1 weight=$2; shift 2
        [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "$CONF line $lineno: bad task type '$name'"
        case "$weight" in light|heavy) ;; *) die "$CONF line $lineno: weight must be light or heavy" ;; esac
        printf '%s\n' "$TYPES" | awk -v n="$name" '$1 == n { f = 1 } END { exit !f }' && die "$CONF line $lineno: type $name is declared twice"
        for f in "$@"; do [ -n "$(machine_line "$f")" ] || die "$CONF line $lineno: type $name names undeclared machine '$f' (declare machine lines first)"; done
        TYPES="$TYPES$name $weight $*
" ;;
      *) die "$CONF line $lineno: unknown key '$key'" ;;
    esac
  done < "$CONF"
}

parse_config

if [ "$spawn_mode" -eq 1 ]; then echo "$SPAWN"; exit 0; fi

[ -n "$type_arg" ] || usage
command -v jq >/dev/null 2>&1 || die "needs jq"
[ -f "$CONF" ] || die "no $CONF: nothing says which machine takes which work (docs/configuration.md \"Task placement\")"
type_line=$(printf '%s\n' "$TYPES" | awk -v n="$type_arg" '$1 == n { print; exit }')
[ -n "$type_line" ] || die "task type '$type_arg' is not declared in $CONF"
# shellcheck disable=SC2086 # word splitting is the tokenizer
set -- $type_line
shift; weight=$1; shift
allowed="$*"

# The owner's apps and the port a worker must never touch on his own PC.
owner_blocked_need=
IFS=, read -r -a need_list <<EOF
$(printf '%s' "$needs" | tr '[:upper:]' '[:lower:]')
EOF
for n in "${need_list[@]+"${need_list[@]}"}"; do
  n=${n#port:}; n=${n#port}
  case "$n" in anki|opera|adspower|dolphin|8766) owner_blocked_need=$n; break ;; esac
done

now=$(date +%s)
skipped=
cands=
idx=0

skip() { skipped="$skipped$1	$2
"; }

read_facts() {  # <home> -> the machine's lane document on stdout, empty when unreadable
  local home=$1 meta fresh
  if [ "$home" = self ]; then
    if [ -f "$STATE/lane-capacity.json" ]; then
      fresh=$(jq -r --argjson now "$now" --argjson maxage "$MAX_AGE" \
        'if (.generated_epoch | type) == "number" and ($now - .generated_epoch) <= $maxage then "y" else "n" end' \
        "$STATE/lane-capacity.json" 2>/dev/null) || fresh=n
      if [ "$fresh" = y ]; then cat "$STATE/lane-capacity.json"; return 0; fi
    fi
    FM_HOME="$FM_HOME" "$CAPACITY" --json 2>/dev/null
    return 0
  fi
  meta="$STATE/$home.meta"
  if [ ! -f "$meta" ] || ! grep -qx 'kind=secondmate' "$meta" 2>/dev/null || ! grep -q '^remote_host=..*' "$meta" 2>/dev/null; then
    return 0
  fi
  fm_run_timed "$READ_TIMEOUT" "$ON" "$home" fm-remote-file.sh get state/lane-capacity.json 2>/dev/null
}

host_of() {  # <home>
  if [ "$1" = self ]; then echo local; else sed -n 's/^remote_host=//p' "$STATE/$1.meta" 2>/dev/null | head -1; fi
}

for label in $allowed; do
  idx=$((idx + 1))
  mline=$(machine_line "$label")
  # shellcheck disable=SC2086 # word splitting is the tokenizer
  set -- $mline
  home=$2 flags=$3
  case ",$flags," in *,hold,*) skip "$label" "held: takes no new work by the captain's decision"; continue ;; esac
  ownerpc=false
  case ",$flags," in *,owner-pc,*) ownerpc=true ;; esac
  if [ "$ownerpc" = true ] && [ -n "$owner_blocked_need" ]; then
    skip "$label" "the owner's PC never takes work needing $owner_blocked_need"
    continue
  fi
  heavy=false
  [ "$weight" = heavy ] && heavy=true
  facts=$(read_facts "$home")
  verdict=$(printf '%s' "$facts" | jq -r --argjson now "$now" --argjson maxage "$MAX_AGE" \
    --argjson heavy "$heavy" --argjson ownerpc "$ownerpc" '
    (.captain // "unknown") as $cap
    | (if (.verdict.free_lanes | type) == "number" then .verdict.free_lanes
       elif (.cap.target | type) == "number" and (.lanes.count | type) == "number" then .cap.target - .lanes.count
       else null end) as $free
    | if type != "object" or .schema != "fm-lane-capacity.v1" then "skip\tlane facts unreadable"
      elif ((.generated_epoch | type) != "number") or ($now - .generated_epoch) > $maxage then "skip\tlane facts are stale"
      elif .verdict.admit != true then "skip\tnot admitting (\((.verdict.reasons // []) | join("; ")))"
      elif $free == null or $free <= 0 then "skip\tno free lane"
      elif $heavy and $ownerpc and ($cap != "idle" and $cap != "away") then "skip\theavy work waits until the owner is away (captain: \($cap))"
      else "ok\t\($free)\t\(.pressure.runq_per_core // 0)" end' 2>/dev/null) || verdict=
  [ -n "$verdict" ] || verdict="skip${TAB}lane facts unreadable"
  IFS=$TAB read -r kind a b <<EOF
$verdict
EOF
  if [ "$kind" != ok ]; then skip "$label" "$a"; continue; fi
  cands="$cands$a$TAB$b$TAB$idx$TAB$label$TAB$home
"
done

best=
if [ -n "$cands" ]; then
  best=$(printf '%s' "$cands" | sort -t "$TAB" -k1,1nr -k2,2g -k3,3n | head -1)
  IFS=$TAB read -r b_free _ _ b_label b_home <<EOF
$best
EOF
  b_host=$(host_of "$b_home")
  while IFS=$TAB read -r _ _ _ l _; do
    [ -z "$l" ] || [ "$l" = "$b_label" ] || skip "$l" "free but ranked below $b_label"
  done <<EOF
$cands
EOF
fi

if [ "$json" -eq 1 ]; then
  jq -cn --arg picked "${b_label:-}" --arg home "${b_home:-}" --arg host "${b_host:-}" --arg free "${b_free:-}" \
    --arg type "$type_arg" --arg weight "$weight" --arg skipped "$skipped" '
    {type: $type, weight: $weight,
     picked: (if $picked == "" then null else {machine: $picked, home: $home, host: $host, free: ($free | tonumber)} end),
     skipped: [$skipped | split("\n")[] | select(. != "") | split("\t") | {machine: .[0], why: .[1]}]}'
else
  if [ -n "${b_label:-}" ]; then
    echo "picked machine=$b_label home=$b_home host=$b_host free=$b_free type=$type_arg weight=$weight"
  else
    echo "none type=$type_arg"
  fi
  printf '%s' "$skipped" | while IFS=$TAB read -r sl sw; do
    [ -z "$sl" ] || echo "skipped: $sl ($sw)"
  done
fi
[ -n "${b_label:-}" ] || exit 1
exit 0
