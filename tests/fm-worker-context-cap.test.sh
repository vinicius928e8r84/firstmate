#!/usr/bin/env bash
# tests/fm-worker-context-cap.test.sh - the per-project context cap for Pi workers
# (bin/fm-worker-context-cap.sh, installed by bin/fm-spawn.sh, retired through
# fm_control_harness_wiring_paths). The helper is driven directly, and the real
# fm-spawn is driven against a fake tmux pane and an isolated git worktree.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"

CAP="$ROOT/bin/fm-worker-context-cap.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-context-cap)

write_config() {  # <config-dir>
  mkdir -p "$1"
  cat > "$1/worker-context-cap" <<'CFG'
# project cap model window
modo-caverna 250000 claude-opus-5-5 1000000
modo-caverna 250000 claude-sonnet-5-5 1000000   # trailing comment
tiny 250000 small-model 300000
project 250000 claude-opus-5-5 1000000
CFG
}

test_settings_for_a_listed_pair_only() {
  local cfg out
  cfg="$TMP_ROOT/helper-config"
  write_config "$cfg"
  out=$(FM_CONFIG_OVERRIDE="$cfg" "$CAP" settings modo-caverna claude-opus-5-5 task-1) || fail "helper failed"
  [ "$(printf '%s' "$out" | jq -r .compaction.reserveTokens)" = 750000 ] || fail "reserve must be window minus cap: $out"
  [ "$(printf '%s' "$out" | jq -r .compaction.enabled)" = true ] || fail "compaction must be enabled: $out"
  [ "$(printf '%s' "$out" | jq -r .compaction.keepRecentTokens)" = 40000 ] || fail "keepRecentTokens: $out"
  [ "$(printf '%s' "$out" | jq -r .firstmateWorkerContextCap)" = task-1 ] || fail "marker missing: $out"
  out=$(FM_CONFIG_OVERRIDE="$cfg" "$CAP" settings modo-caverna claude-bridge/claude-sonnet-5-5 task-2) || fail "provider-prefixed model"
  [ "$(printf '%s' "$out" | jq -r .compaction.reserveTokens)" = 750000 ] || fail "a provider prefix must not hide the model: $out"
  [ -z "$(FM_CONFIG_OVERRIDE="$cfg" "$CAP" settings modo-caverna some-other-model task-3)" ] || fail "an unlisted model must get no cap"
  [ -z "$(FM_CONFIG_OVERRIDE="$cfg" "$CAP" settings PerpetualMiner claude-opus-5-5 task-4)" ] || fail "an unlisted project must get no cap"
  [ -z "$(FM_CONFIG_OVERRIDE="$cfg" "$CAP" settings modo-caverna '' task-5)" ] || fail "an unset model must get no cap"
  [ -z "$(FM_CONFIG_OVERRIDE="$cfg" "$CAP" settings tiny small-model task-6 2>/dev/null)" ] || fail "a window with under 100000 tokens above the cap must be ignored"
  [ -z "$(FM_CONFIG_OVERRIDE="$TMP_ROOT/none" "$CAP" settings modo-caverna claude-opus-5-5 task-7)" ] || fail "no config file means no cap"
  pass "the cap settings exist only for a listed project and model, and compute reserve = window - cap"
}

test_helper_refuses_bad_arguments() {
  local status
  "$CAP" settings modo-caverna claude-opus-5-5 'bad id' > /dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a task id with a space must be refused"
  "$CAP" settings modo-caverna > /dev/null 2>&1
  status=$?
  expect_code 2 "$status" "missing arguments must be refused"
  pass "the helper refuses malformed arguments"
}

make_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi)
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  write_config "$home/config"
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

spawn() {  # <home> <wt> <fakebin> <id> <proj> [spawn-args...]
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  shift 5
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" --mode no-mistakes --yolo off
}

test_spawn_installs_and_excludes_the_cap_for_a_listed_model() {
  local rec home proj wt fakebin out
  rec=$(make_spawn_case spawn-listed cap-1)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  out=$(spawn "$home" "$wt" "$fakebin" cap-1 "$proj" --model claude-opus-5-5)
  expect_code 0 $? "spawn should succeed: $out"
  assert_present "$wt/.pi/settings.json" "the capped model got no project settings"
  [ "$(jq -r .compaction.reserveTokens "$wt/.pi/settings.json")" = 750000 ] || fail "reserve: $(cat "$wt/.pi/settings.json")"
  [ -z "$(git -C "$wt" status --porcelain -- .pi)" ] || fail "the settings file must be git-excluded: $(git -C "$wt" status --porcelain -- .pi)"
  fm_control_harness_wiring_paths pi "$wt" "$home/state" cap-1 ship | grep -qxF "$wt/.pi/settings.json" \
    || fail "relaunch and cleanup do not know the settings file"
  fm_control_harness_wiring_paths pi "$wt" "$home/state" other-task ship | grep -qxF "$wt/.pi/settings.json" \
    && fail "another task's marker must not retire this file"
  pass "spawn installs a git-excluded cap for a listed model and the wiring list names it"
}

test_spawn_leaves_unlisted_models_and_existing_files_alone() {
  local rec home proj wt fakebin out exclude
  rec=$(make_spawn_case spawn-unlisted cap-2)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  out=$(spawn "$home" "$wt" "$fakebin" cap-2 "$proj" --model some-other-model)
  expect_code 0 $? "spawn should succeed: $out"
  assert_absent "$wt/.pi/settings.json" "an unlisted model was capped"

  rec=$(make_spawn_case spawn-own-settings cap-3)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  # A project's own settings file: ignored here so the pooled worktree still counts as clean.
  exclude=$(git -C "$wt" rev-parse --git-path info/exclude)
  case "$exclude" in /*) ;; *) exclude="$wt/$exclude" ;; esac
  mkdir -p "$(dirname "$exclude")" "$wt/.pi"
  echo '.pi/settings.json' >> "$exclude"
  printf '{"theme":"light"}\n' > "$wt/.pi/settings.json"
  out=$(spawn "$home" "$wt" "$fakebin" cap-3 "$proj" --model claude-opus-5-5)
  expect_code 0 $? "spawn should succeed beside a project settings file: $out"
  [ "$(cat "$wt/.pi/settings.json" 2>/dev/null)" = '{"theme":"light"}' ] || fail "the project's own settings file was overwritten or never reached the worktree: $(cat "$wt/.pi/settings.json" 2>&1)"
  fm_control_harness_wiring_paths pi "$wt" "$home/state" cap-3 ship | grep -qxF "$wt/.pi/settings.json" \
    && fail "a project's own settings file must never be retired"
  pass "spawn leaves unlisted models alone and never overwrites or retires a project's own settings"
}

test_settings_for_a_listed_pair_only
test_helper_refuses_bad_arguments
test_spawn_installs_and_excludes_the_cap_for_a_listed_model
test_spawn_leaves_unlisted_models_and_existing_files_alone
