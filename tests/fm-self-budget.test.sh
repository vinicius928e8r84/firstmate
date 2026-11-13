#!/usr/bin/env bash
# Behavior tests for bin/fm-self-budget.sh (the fleet's share of the week spent
# on its own repository) and its opt-in hook in bin/fm-spawn.sh
# (config/self-work-budget mode report|defer).
#
# The measurement runs on transcript fixtures written here; the spawn runs the
# real bin/fm-spawn.sh against a fake terminal and worktree pool that log every
# call, and a deferral is judged by what it left behind.
# shellcheck disable=SC2016 # fake commands are written as single-quoted scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

BUDGET="$ROOT/bin/fm-self-budget.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-self-budget)
DEFER_EXIT=75
NOW=1794500000   # 2026-11-12T15:33:20Z

# --- measurement fixtures -----------------------------------------------------

# make_home <name>: a home and an empty transcript root.
make_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/sessions"
  printf '%s\n' "$dir"
}

# response <file> <id> <iso-time> <cwd> <input> <output> <cache-read> <cache-write>
response() {
  mkdir -p "$(dirname "$1")"
  jq -cn --arg id "$2" --arg ts "$3" --arg cwd "$4" --argjson i "$5" --argjson o "$6" --argjson r "$7" --argjson w "$8" \
    '{type: "assistant", cwd: $cwd, timestamp: $ts,
      message: {id: $id, usage: {input_tokens: $i, output_tokens: $o, cache_read_input_tokens: $r, cache_creation_input_tokens: $w}}}' >> "$1"
}

budget() {  # <case-dir> <args...>
  local dir=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$dir/home" FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SELF_BUDGET_SESSIONS="$dir/sessions" FM_SELF_BUDGET_NOW="$NOW" FM_SELF_BUDGET_NO_BACKGROUND=1 \
    "$BUDGET" "$@" 2>&1
}

REPO_NAME=$(basename "$ROOT")

# week <case-dir> <self-weight-in-input-tokens> <product-weight-in-input-tokens>
week() {
  local dir=$1
  response "$dir/sessions/a/s1.jsonl" m1 2026-11-12T10:00:00.000Z "/pool/1/$REPO_NAME" "$2" 0 0 0
  response "$dir/sessions/b/s2.jsonl" m2 2026-11-12T11:00:00.000Z "/pool/7/product" "$3" 0 0 0
}

doc_field() { jq -r "$2" "$1/home/state/self-work-budget.json"; }

# --- measurement cases --------------------------------------------------------

test_nothing_happens_without_the_config() {
  local c out rc=0
  c=$(make_home absent)
  week "$c" 100 100
  out=$(budget "$c" measure) || rc=$?
  expect_code 0 "$rc" "measure without a config failed: $out"
  assert_absent "$c/home/state/self-work-budget.json" "measure wrote a document although no config exists"
  rc=0; out=$(budget "$c" admit --project "$ROOT") || rc=$?
  expect_code 0 "$rc" "admit without a config must admit: $out"
  [ -z "$out" ] || fail "admit without a config spoke: $out"
  pass "with no config/self-work-budget nothing is measured, written or said"
}

test_measure_weighs_each_response_once_inside_the_window() {
  local c out
  c=$(make_home weigh)
  printf 'percent 15\n' > "$c/home/config/self-work-budget"
  # One response on this repository: 100 input + 10 output x 5 + 1000 read x 0.1 + 50 write x 2 = 350.
  response "$c/sessions/a/s1.jsonl" m1 2026-11-12T10:00:00.000Z "/pool/1/$REPO_NAME" 1 1 0 0
  response "$c/sessions/a/s1.jsonl" m1 2026-11-12T10:00:01.000Z "/pool/1/$REPO_NAME" 100 10 1000 50
  # A product response of 650, one older than seven days, the primary's own, and a secondmate home's.
  response "$c/sessions/b/s2.jsonl" m2 2026-11-12T11:00:00.000Z "/pool/7/product" 650 0 0 0
  response "$c/sessions/b/s2.jsonl" m3 2026-11-01T11:00:00.000Z "/pool/1/$REPO_NAME" 9000 0 0 0
  response "$c/sessions/c/s3.jsonl" m4 2026-11-12T12:00:00.000Z "$c/home" 500 0 0 0
  mkdir -p "$c/mate/$REPO_NAME" && : > "$c/mate/$REPO_NAME/.fm-secondmate-home"
  response "$c/sessions/d/s4.jsonl" m5 2026-11-12T12:00:00.000Z "$c/mate/$REPO_NAME" 500 0 0 0
  touch -d '2026-11-12T12:00:00Z' "$c/sessions"/*/*.jsonl 2>/dev/null || true

  out=$(budget "$c" measure)
  assert_contains "$out" "measured: self=350 total=2000" "the weights are wrong: $out"
  [ "$(doc_field "$c" .self_weight)" = 350 ] || fail "self weight should count the repeated response once: $(cat "$c/home/state/self-work-budget.json")"
  [ "$(doc_field "$c" '.top[0].cwd')" = "/pool/1/$REPO_NAME" ] || fail "the top spender is not named"
  out=$(budget "$c" report)
  assert_contains "$out" "share=17% ceiling=15% basis=usage" "the report line is wrong: $out"

  # A transcript that did not change is not read again: its cache answers.
  for f in "$c/home/state/.self-work-budget"/s1.*.tsv; do sed -i 's/\t350\t/\t351\t/' "$f"; done
  out=$(budget "$c" measure)
  assert_contains "$out" "self=351" "an unchanged transcript was read again instead of its cache: $out"
  response "$c/sessions/a/s1.jsonl" m9 2026-11-12T13:00:00.000Z "/pool/1/$REPO_NAME" 50 0 0 0
  out=$(budget "$c" measure)
  assert_contains "$out" "self=400" "a transcript that grew was not read again: $out"
  pass "measure counts each response once by weight, keeps to seven days, leaves homes out and reuses its cache"
}

test_quota_basis_and_bad_config() {
  local c out rc=0
  c=$(make_home quota)
  week "$c" 300 100
  printf 'percent 15\nweek-weight 3000\n' > "$c/home/config/self-work-budget"
  budget "$c" measure > /dev/null
  out=$(budget "$c" report)
  assert_contains "$out" "share=10% ceiling=15% basis=quota" "week-weight must be the denominator: $out"

  printf 'percent 150\n' > "$c/home/config/self-work-budget"
  out=$(budget "$c" report) || rc=$?
  expect_code 1 "$rc" "a percent over 100 must be refused: $out"
  assert_contains "$out" "line 1" "the refusal must name the line"
  printf 'percent 15\nceiling 3\n' > "$c/home/config/self-work-budget"
  rc=0; out=$(budget "$c" admit --project "$ROOT") || rc=$?
  expect_code 1 "$rc" "an unknown key must be refused: $out"
  pass "week-weight makes the quota the denominator, and a malformed file is refused naming its line"
}

test_admit_verdicts() {
  local c out rc=0 other
  c=$(make_home admit)
  week "$c" 300 700
  printf 'percent 15\nmode defer\n' > "$c/home/config/self-work-budget"

  out=$(budget "$c" admit --project "$ROOT") || rc=$?
  expect_code 0 "$rc" "an unmeasured budget must admit: $out"
  assert_contains "$out" "no measurement yet" "the note must say why the budget was not applied"

  budget "$c" measure > /dev/null
  rc=0; out=$(budget "$c" admit --project "$ROOT") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "30% against a 15% ceiling must defer: $out"
  assert_contains "$out" "30% of the week's usage" "the deferral must give the share"

  other="$c/other"; fm_git_init_commit "$other"
  rc=0; out=$(budget "$c" admit --project "$other") || rc=$?
  expect_code 0 "$rc" "another repository is never held: $out"
  [ -z "$out" ] || fail "admit spoke about another repository: $out"

  rc=0; out=$(budget "$c" admit --project "$ROOT" --scheduled) || rc=$?
  expect_code 0 "$rc" "a scheduled loop is admitted: $out"
  assert_contains "$out" "scheduled loop is admitted" "the scheduled note is missing"

  printf 'percent 15\nmode report\n' > "$c/home/config/self-work-budget"
  rc=0; out=$(budget "$c" admit --project "$ROOT") || rc=$?
  expect_code 0 "$rc" "mode report never defers: $out"
  assert_contains "$out" "over the 15% ceiling" "mode report must still say the share is over"

  printf 'percent 40\nmode defer\n' > "$c/home/config/self-work-budget"
  rc=0; out=$(budget "$c" admit --project "$ROOT") || rc=$?
  expect_code 0 "$rc" "a share under the ceiling admits: $out"
  [ -z "$out" ] || fail "admit under the ceiling spoke: $out"

  printf 'percent 15\nmode defer\nmax-age 60\n' > "$c/home/config/self-work-budget"
  rc=0; out=$(FM_ROOT_OVERRIDE='' FM_HOME="$c/home" FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SELF_BUDGET_NOW=$((NOW + 600)) FM_SELF_BUDGET_NO_BACKGROUND=1 "$BUDGET" admit --project "$ROOT" 2>&1) || rc=$?
  expect_code 0 "$rc" "a stale measurement must admit: $out"
  assert_contains "$out" "old" "the note must say the measurement is stale"
  pass "admit defers only this repository, only over the ceiling, only in mode defer, and never on a missing or stale measurement"
}

# --- spawn hook fixtures ------------------------------------------------------

make_spawn_case() {  # <name> <task-id>
  local name=$1 id=$2 case_dir fakebin
  case_dir="$TMP_ROOT/$name"; mkdir -p "$case_dir/home/state" "$case_dir/home/config"
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
Exercise the self-work budget.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  printf '%s\n' "$case_dir"
}

spawn_ship() {  # <case-dir> <id> <project> [spawn args...]
  local case_dir=$1 id=$2 project=$3 pane
  shift 3
  git -C "$project" worktree add --quiet -b "wt-$id-$RANDOM" "$case_dir/wt-$id-$$" 2>/dev/null || true
  pane="$case_dir/wt-$id-$$"
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_SELF_BUDGET_SESSIONS="$case_dir/sessions" FM_SELF_BUDGET_NOW="$NOW" FM_SELF_BUDGET_NO_BACKGROUND=1 \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$project" --mode no-mistakes --yolo off "$@" 2>&1
}

# self_clone <case-dir>: a project that shares this repository's history.
self_clone() {
  git clone --quiet --no-hardlinks "$ROOT" "$1/self" 2>/dev/null || fail "could not clone this repository for the fixture"
  git -C "$1/self" checkout --quiet -B main 2>/dev/null
  git -C "$1/self" remote remove origin
  fm_git_add_origin "$1/self" "$1/self.origin.git"
  printf '%s\n' "$1/self"
}

over_budget() {  # <case-dir> <mode>
  week "$1" 300 700
  printf 'percent 15\nmode %s\n' "$2" > "$1/home/config/self-work-budget"
  budget "$1" measure > /dev/null
}

# --- spawn hook cases ---------------------------------------------------------

test_spawn_defers_self_work_over_the_ceiling_and_creates_nothing() {
  local c out rc=0 self
  c=$(make_spawn_case spawn-defer task-a)
  self=$(self_clone "$c")
  over_budget "$c" defer
  out=$(spawn_ship "$c" task-a "$self") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "self-work over the ceiling must defer the spawn: $out"
  assert_contains "$out" "deferred: work on this repository is at 30%" "the deferral line is missing: $out"
  assert_absent "$c/home/state/task-a.meta" "a deferred spawn published a task record"
  assert_absent "$c/home/data/task-a/launch-brief.md" "a deferred spawn rendered a launch brief"
  [ ! -s "$c/calls.log" ] || fail "a deferred spawn touched the terminal or worktree pool: $(cat "$c/calls.log")"
  pass "spawn: self-work over the ceiling in mode defer is deferred with exit 75 and nothing is created"
}

test_spawn_holds_no_product_work_and_report_mode_only_notes() {
  local c out rc=0 self
  c=$(make_spawn_case spawn-product task-a)
  over_budget "$c" defer
  out=$(spawn_ship "$c" task-a "$c/project") || rc=$?
  expect_code 0 "$rc" "a product spawn must not be held by the self-work budget: $out"
  assert_contains "$out" "spawned task-a" "the product spawn did not launch"
  assert_not_contains "$out" "this repository" "the budget spoke about a product spawn"

  c=$(make_spawn_case spawn-report task-b)
  self=$(self_clone "$c")
  over_budget "$c" report
  # The spawn then meets the publication gate, a later and separate check that
  # this fixture home does not pass; what matters here is that the budget let it by.
  rc=0; out=$(spawn_ship "$c" task-b "$self") || rc=$?
  [ "$rc" -ne "$DEFER_EXIT" ] || fail "mode report must never defer: $out"
  assert_contains "$out" "note: work on this repository is at 30%" "mode report must print the share: $out"
  assert_not_contains "$out" "deferred:" "mode report deferred the spawn: $out"

  c=$(make_spawn_case spawn-bad task-c)
  self=$(self_clone "$c")
  printf 'percent many\n' > "$c/home/config/self-work-budget"
  rc=0; out=$(spawn_ship "$c" task-c "$self") || rc=$?
  expect_code 1 "$rc" "an unreadable declaration must refuse the spawn: $out"
  assert_contains "$out" "self-work budget is unreadable" "the refusal must name the file: $out"
  pass "spawn: product work is never held, mode report lets the spawn by with a note, and a malformed file refuses"
}

test_nothing_happens_without_the_config
test_measure_weighs_each_response_once_inside_the_window
test_quota_basis_and_bad_config
test_admit_verdicts
test_spawn_defers_self_work_over_the_ceiling_and_creates_nothing
test_spawn_holds_no_product_work_and_report_mode_only_notes
