#!/usr/bin/env bash
# Behavior tests for bin/fm-place.sh (the machine chooser) and its opt-in hook in
# bin/fm-spawn.sh (config/placement spawn on|dry-run|off).
#
# The chooser cases replace fm-on.sh and fm-capacity.sh with fakes that serve
# canned fm-lane-capacity.v1 documents. The spawn cases drive the real
# bin/fm-spawn.sh against a real clone with fake tmux and treehouse binaries that
# log every call, and judge a deferral by what it left behind.
# shellcheck disable=SC2016 # fake commands are written as single-quoted scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

PLACE="$ROOT/bin/fm-place.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-place)
DEFER_EXIT=75

# --- chooser fixtures ---------------------------------------------------------

# make_case <name>: a home with remote secondmate records for pc-aux2 and
# creative-aux, a fake fm-on (serves $dir/facts/<home>.json), a fake
# fm-capacity (serves $dir/facts/self-live.json for --json) and the case's
# config/placement written by the test.
make_case() {
  local dir="$TMP_ROOT/$1" id
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/facts"
  for id in pc-aux2 creative-aux; do
    fm_write_meta "$dir/home/state/$id.meta" "kind=secondmate" "mode=secondmate" "remote_host=$id-host"
  done
  cat > "$dir/on" <<'SH'
#!/usr/bin/env bash
[ "$2 $3 $4" = "fm-remote-file.sh get state/lane-capacity.json" ] || exit 64
cat "$FAKE_FACTS/$1.json" 2>/dev/null || exit 1
SH
  cat > "$dir/capacity" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 64
cat "$FAKE_FACTS/self-live.json" 2>/dev/null || exit 1
SH
  chmod +x "$dir/on" "$dir/capacity"
  printf '%s\n' "$dir"
}

# placement <dir> <line>...: the case's config/placement.
placement() {
  local dir=$1
  shift
  printf '%s\n' "$@" > "$dir/home/config/placement"
}

# The fleet of the report: principal (self), the owner's pc, the creative VPS.
fleet() {
  placement "$1" \
    "machine principal self" \
    "machine pc pc-aux2 owner-pc" \
    "machine criativa creative-aux hold" \
    "type edit light principal pc" \
    "type scout light principal pc" \
    "type review light principal pc criativa" \
    "type suite heavy pc principal criativa" \
    "type anki-proof heavy pc principal"
}

# facts <path> <free-lanes> <runq-per-core> [age-s] [captain] [admit]
facts() {
  local age=${4:-5} admit=${6:-true}
  jq -n --argjson gen "$(($(date +%s) - age))" --argjson free "$2" --argjson rpc "$3" \
    --arg captain "${5:-not-configured}" --argjson admit "$admit" '
    {schema: "fm-lane-capacity.v1", generated_epoch: $gen,
     lanes: {count: 1}, cap: {target: 9, status: "ok"},
     pressure: {level: "ok", runq_per_core: $rpc}, captain: $captain,
     verdict: {admit: $admit, free_lanes: $free, reasons: (if $admit then [] else ["cpu: load 9 on 4 cores"] end)}}' > "$1"
}

run() {  # <dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_PLACE_ON="$dir/on" FM_PLACE_CAPACITY="$dir/capacity" \
    FAKE_FACTS="$dir/facts" "$PLACE" "$@" 2>&1
}

# --- chooser cases ------------------------------------------------------------

test_picks_the_machine_with_most_free_lanes_among_the_allowed() {
  local dir out rc=0
  dir=$(make_case most-free)
  fleet "$dir"
  facts "$dir/home/state/lane-capacity.json" 2 0.5
  facts "$dir/facts/pc-aux2.json" 6 0.1
  facts "$dir/facts/creative-aux.json" 9 0.1
  out=$(run "$dir" --type edit) || rc=$?
  expect_code 0 "$rc" "no pick with two free machines: $out"
  assert_contains "$out" "picked machine=pc home=pc-aux2 host=pc-aux2-host free=6 type=edit weight=light" "the machine with more free lanes was not picked"
  assert_contains "$out" "skipped: principal (free but ranked below pc)" "the other free machine was not reported"
  assert_not_contains "$out" "criativa" "a machine the type does not list was considered"
  pass "the machine with the most free lanes wins and only the type's machines are considered"
}

test_affinity_decides_where_a_heavy_suite_may_go() {
  local dir out
  dir=$(make_case affinity)
  fleet "$dir"
  facts "$dir/home/state/lane-capacity.json" 4 0.5
  facts "$dir/facts/pc-aux2.json" 1 0.1 5 idle
  out=$(run "$dir" --type suite) || true
  assert_contains "$out" "picked machine=principal home=self host=local free=4 type=suite weight=heavy" "the heavy suite did not go to the machine with the most room"
  assert_contains "$out" "skipped: criativa (held: takes no new work by the captain's decision)" "the held creative VPS was not skipped"
  out=$(run "$dir" --type review) || true
  assert_not_contains "$out" "picked machine=criativa" "the held machine received new work through another type"
  pass "affinity lists decide the candidates and a held machine takes nothing new"
}

test_owner_pc_takes_heavy_work_only_while_the_owner_is_away() {
  local dir out rc
  dir=$(make_case owner)
  fleet "$dir"
  facts "$dir/home/state/lane-capacity.json" 0 0.5 5 not-configured false
  for captain in present unknown not-configured; do
    facts "$dir/facts/pc-aux2.json" 6 0.1 5 "$captain"
    rc=0; out=$(run "$dir" --type suite) || rc=$?
    expect_code 1 "$rc" "heavy work was placed on the owner's pc while captain=$captain: $out"
    assert_contains "$out" "skipped: pc (heavy work waits until the owner is away (captain: $captain))" "no reason given for captain=$captain"
  done
  for captain in idle away; do
    facts "$dir/facts/pc-aux2.json" 6 0.1 5 "$captain"
    rc=0; out=$(run "$dir" --type suite) || rc=$?
    expect_code 0 "$rc" "heavy work was refused on the owner's pc while captain=$captain: $out"
    assert_contains "$out" "picked machine=pc" "the idle pc was not picked for a heavy suite (captain=$captain)"
  done
  facts "$dir/facts/pc-aux2.json" 6 0.1 5 present
  rc=0; out=$(run "$dir" --type edit) || rc=$?
  expect_code 0 "$rc" "light work was refused on the owner's pc while the owner is present: $out"
  assert_contains "$out" "picked machine=pc" "light work did not run beside the owner"
  pass "the owner's pc takes light work always and heavy work only when the owner is idle or away"
}

test_owner_apps_and_port_never_reach_the_owner_pc() {
  local dir out need rc
  dir=$(make_case never)
  fleet "$dir"
  facts "$dir/home/state/lane-capacity.json" 0 0.5 5 not-configured false
  facts "$dir/facts/pc-aux2.json" 9 0.1 5 away
  for need in anki Opera 8766 port:8766 adspower dolphin "edit,anki"; do
    rc=0; out=$(run "$dir" --type anki-proof --needs "$need") || rc=$?
    expect_code 1 "$rc" "work needing $need was placed on the owner's pc: $out"
    assert_contains "$out" "skipped: pc (the owner's PC never takes work needing" "no reason given for $need"
  done
  rc=0; out=$(run "$dir" --type anki-proof --needs display) || rc=$?
  expect_code 0 "$rc" "an unrelated need blocked the pc: $out"
  pass "Anki, Opera, AdsPower, Dolphin and port 8766 are never placed on the owner's pc, whatever the type allows"
}

test_unreadable_stale_and_unadmitting_machines_are_skipped() {
  local dir out rc=0
  dir=$(make_case skips)
  fleet "$dir"
  facts "$dir/home/state/lane-capacity.json" 3 0.5 900
  facts "$dir/facts/self-live.json" 5 0.2 1 not-configured false
  rm -f "$dir/facts/pc-aux2.json"
  out=$(run "$dir" --type edit) || rc=$?
  expect_code 1 "$rc" "a pick was made with every machine unusable: $out"
  assert_contains "$out" "none type=edit" "no 'none' line"
  assert_contains "$out" "skipped: principal (not admitting (cpu: load 9 on 4 cores))" "the live fallback verdict was not used for a stale self document"
  assert_contains "$out" "skipped: pc (lane facts unreadable)" "an unreadable remote document was trusted"
  facts "$dir/facts/pc-aux2.json" 6 0.1 900
  out=$(run "$dir" --type edit) || true
  assert_contains "$out" "skipped: pc (lane facts are stale)" "a stale remote document was trusted"
  facts "$dir/facts/pc-aux2.json" 0 0.1
  out=$(run "$dir" --type edit) || true
  assert_contains "$out" "skipped: pc (no free lane)" "a full machine was picked"
  pass "stale, unreadable, full and unadmitting machines are skipped with their reason, and a stale self document falls back to the live one"
}

test_json_output_and_exit_codes() {
  local dir out rc=0
  dir=$(make_case json)
  fleet "$dir"
  facts "$dir/home/state/lane-capacity.json" 3 0.5
  facts "$dir/facts/pc-aux2.json" 1 0.1
  out=$(run "$dir" --type scout --json) || rc=$?
  expect_code 0 "$rc" "json pick failed: $out"
  assert_equals "principal self local 3" "$(printf '%s' "$out" | jq -r '.picked | "\(.machine) \(.home) \(.host) \(.free)"')" "the json pick is wrong: $out"
  rc=0; run "$dir" --type nonsense >/dev/null || rc=$?
  expect_code 2 "$rc" "an undeclared task type was accepted"
  rc=0; run "$dir" >/dev/null || rc=$?
  expect_code 2 "$rc" "a missing --type was accepted"
  pass "--json prints the pick, and an unknown type or missing --type is a usage error"
}

test_bad_config_is_refused_and_absent_config_means_off() {
  local dir out rc=0
  dir=$(make_case config)
  out=$(run "$dir" --spawn-mode) || rc=$?
  expect_code 0 "$rc" "the spawn mode failed without a config: $out"
  assert_equals "off" "$out" "placement is not off by default"
  placement "$dir" "spawn on" "machine a self" "type edit light b"
  rc=0; out=$(run "$dir" --spawn-mode) || rc=$?
  expect_code 2 "$rc" "a type naming an undeclared machine was accepted: $out"
  assert_contains "$out" "undeclared machine 'b'" "the bad machine was not named"
  placement "$dir" "spawn maybe"
  rc=0; run "$dir" --spawn-mode >/dev/null || rc=$?
  expect_code 2 "$rc" "an unknown spawn value was accepted"
  placement "$dir" "colour red"
  rc=0; run "$dir" --spawn-mode >/dev/null || rc=$?
  expect_code 2 "$rc" "an unknown key was accepted"
  placement "$dir" "spawn dry-run"
  assert_equals "dry-run" "$(run "$dir" --spawn-mode)" "dry-run is not reported"
  pass "placement is off without a file, the spawn key reads off, dry-run and on, and a malformed file is refused"
}

# --- spawn hook fixtures ------------------------------------------------------

make_spawn_case() {  # <name> <task-id>
  local name=$1 id=$2 case_dir fakebin
  case_dir=$(make_case "$name")
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name= previous=
    for arg in "$@"; do [ "$previous" = -n ] && name=$arg; previous=$arg; done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nprintf "treehouse %%s\\n" "$*" >> "$FM_FAKE_CALL_LOG"\nexit 0\n' > "$fakebin/treehouse"
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  touch "$case_dir/home/state/.last-watcher-beat"
  printf '%s\n' codex > "$case_dir/home/config/crew-harness"
  mkdir -p "$case_dir/home/data/$id" "$case_dir/home/projects"
  cat > "$case_dir/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Run a short task for $id.

## Firstmate spec
Exercise placement.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  printf '%s\n' "$case_dir"
}

spawn_ship() {  # <case-dir> <id> [spawn args...]
  local case_dir=$1 id=$2 pane
  shift 2
  git -C "$case_dir/project" worktree add --quiet -b "wt-$id-$RANDOM" "$case_dir/wt-$id-$$" 2>/dev/null || true
  pane="$case_dir/wt-$id-$$"
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_PLACE_ON="$case_dir/on" FM_PLACE_CAPACITY="$case_dir/capacity" FAKE_FACTS="$case_dir/facts" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off "$@" 2>&1
}

assert_nothing_created() {  # <case-dir> <id> <label>
  assert_absent "$1/home/state/$2.meta" "$3 published a task record"
  assert_absent "$1/home/data/$2/launch-brief.md" "$3 rendered a launch brief"
  [ ! -s "$1/calls.log" ] || fail "$3 touched the terminal or worktree pool: $(cat "$1/calls.log")"
}

# --- spawn hook cases ---------------------------------------------------------

test_spawn_is_unchanged_when_placement_is_absent_or_off() {
  local c out rc=0
  c=$(make_spawn_case off task-a)
  out=$(spawn_ship "$c" task-a) || rc=$?
  expect_code 0 "$rc" "a spawn without config/placement failed: $out"
  assert_contains "$out" "spawned task-a" "a spawn without config/placement did not launch"
  assert_not_contains "$out" "placement" "placement spoke although no file exists"

  c=$(make_spawn_case off-key task-a)
  fleet "$c"
  facts "$c/home/state/lane-capacity.json" 0 0.5 5 not-configured false
  rc=0; out=$(spawn_ship "$c" task-a) || rc=$?
  expect_code 0 "$rc" "a spawn with the spawn key off failed: $out"
  assert_not_contains "$out" "placement" "placement spoke with its spawn key off"
  pass "with no config/placement, or its spawn key off, the spawn is exactly as before"
}

test_spawn_dry_run_reports_the_choice_and_launches() {
  local c out rc=0
  c=$(make_spawn_case dry task-a)
  { fleet "$c"; printf 'spawn dry-run\n' >> "$c/home/config/placement"; }
  facts "$c/home/state/lane-capacity.json" 1 0.5
  facts "$c/facts/pc-aux2.json" 8 0.1
  out=$(spawn_ship "$c" task-a) || rc=$?
  expect_code 0 "$rc" "dry-run placement refused the spawn: $out"
  assert_contains "$out" "placement (dry-run): picked machine=pc" "the choice was not shown"
  assert_contains "$out" "spawned task-a" "dry-run placement did not let the spawn launch"
  pass "spawn key dry-run shows the choice and still launches"
}

test_spawn_on_defers_when_another_machine_is_chosen() {
  local c out rc=0
  c=$(make_spawn_case other task-a)
  { fleet "$c"; printf 'spawn on\n' >> "$c/home/config/placement"; }
  facts "$c/home/state/lane-capacity.json" 1 0.5
  facts "$c/facts/pc-aux2.json" 8 0.1
  out=$(spawn_ship "$c" task-a) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn placed on another machine was not deferred: $out"
  assert_contains "$out" "deferred: placement chose home pc-aux2 for a edit task, not this one; task task-a was not launched" "the deferral does not name the chosen home"
  assert_nothing_created "$c" task-a "a placement deferral"
  pass "spawn key on defers with exit 75 and creates nothing when the choice is another machine"
}

test_spawn_on_launches_here_when_this_home_is_chosen_and_defers_when_none() {
  local c out rc=0
  c=$(make_spawn_case here task-a)
  { fleet "$c"; printf 'spawn on\n' >> "$c/home/config/placement"; }
  facts "$c/home/state/lane-capacity.json" 5 0.5
  facts "$c/facts/pc-aux2.json" 2 0.1
  out=$(spawn_ship "$c" task-a) || rc=$?
  expect_code 0 "$rc" "a spawn placed on this home was refused: $out"
  assert_contains "$out" "spawned task-a" "the spawn placed here did not launch"

  c=$(make_spawn_case none task-a)
  { fleet "$c"; printf 'spawn on\n' >> "$c/home/config/placement"; }
  facts "$c/home/state/lane-capacity.json" 0 0.5 5 not-configured false
  facts "$c/facts/pc-aux2.json" 0 0.1
  rc=0; out=$(spawn_ship "$c" task-a) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn with no placeable machine was not deferred: $out"
  assert_contains "$out" "deferred: no machine can take a edit task now" "the no-machine deferral is missing"
  assert_nothing_created "$c" task-a "a no-machine deferral"

  c=$(make_spawn_case typed task-a)
  { fleet "$c"; printf 'spawn on\n' >> "$c/home/config/placement"; }
  facts "$c/home/state/lane-capacity.json" 5 0.5
  facts "$c/facts/pc-aux2.json" 2 0.1 5 present
  rc=0; out=$(spawn_ship "$c" task-a --task-type suite) || rc=$?
  expect_code 0 "$rc" "a heavy task was not placed on this home while the owner is present: $out"
  assert_contains "$out" "type=suite weight=heavy" "--task-type did not reach the chooser"
  pass "spawn key on launches when this home is chosen, defers when none can take it, and reads --task-type"
}

test_spawn_on_refuses_an_unreadable_declaration() {
  local c out rc=0
  c=$(make_spawn_case broken task-a)
  placement "$c" "spawn on" "bogus line"
  out=$(spawn_ship "$c" task-a) || rc=$?
  expect_code 1 "$rc" "a malformed placement file did not refuse the spawn: $out"
  assert_contains "$out" "the placement declaration is unreadable" "the refusal does not name the declaration"
  assert_nothing_created "$c" task-a "a refused spawn"
  pass "a malformed config/placement refuses the spawn instead of guessing"
}

test_picks_the_machine_with_most_free_lanes_among_the_allowed
test_affinity_decides_where_a_heavy_suite_may_go
test_owner_pc_takes_heavy_work_only_while_the_owner_is_away
test_owner_apps_and_port_never_reach_the_owner_pc
test_unreadable_stale_and_unadmitting_machines_are_skipped
test_json_output_and_exit_codes
test_bad_config_is_refused_and_absent_config_means_off
test_spawn_is_unchanged_when_placement_is_absent_or_off
test_spawn_dry_run_reports_the_choice_and_launches
test_spawn_on_defers_when_another_machine_is_chosen
test_spawn_on_launches_here_when_this_home_is_chosen_and_defers_when_none
test_spawn_on_refuses_an_unreadable_declaration
