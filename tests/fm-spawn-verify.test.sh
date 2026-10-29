#!/usr/bin/env bash
# Behavior tests for the post-launch proof in bin/fm-spawn.sh (bin/fm-spawn-verify-lib.sh):
# a spawn only reports success when the worker is processing its brief and shows the requested model.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-verify)

# Spawn world whose tmux shows $FM_FAKE_CAPTURE (a file) as the worker's pane.
make_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gh-axi gh)
  mv "$fakebin/tmux" "$fakebin/tmux.fixture"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = capture-pane ]; then
  cat "\${FM_FAKE_CAPTURE:-/dev/null}" 2>/dev/null
  exit 0
fi
exec "$fakebin/tmux.fixture" "\$@"
SH
  chmod +x "$fakebin/tmux"
  id="ver-$name-x1"
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" "$id" brief
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

# run_case <pane-text> <model> -> sets OUT, RC, and the case variables
run_case() {
  local name=$1 pane=$2 model=$3 rec
  rec=$(make_case "$name")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN ID <<EOF
$rec
EOF
  printf '%s\n' "$pane" > "$CASE_DIR/pane.txt"
  OUT=$(FM_SPAWN_VERIFY=1 FM_SPAWN_VERIFY_SECS=2 FM_SPAWN_VERIFY_INTERVAL=0.2 \
    FM_FAKE_CAPTURE="$CASE_DIR/pane.txt" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" \
    "$ID" "$PROJ_DIR" grok --model "$model" --mode no-mistakes --yolo off)
  RC=$?
}

test_verified_launch_passes() {
  run_case ok 'grok  claude-opus-4-8   ↑1.2k ↓300' claude-opus-4-8
  expect_code 0 "$RC" "a worker processing its brief with the requested model should spawn: $OUT"
  assert_contains "$OUT" "spawned $ID harness=grok" "verified spawn did not report success"
  pass "fm-spawn: verified launch (processing + requested model) succeeds"
}

test_provider_prefix_and_friendly_name_match() {
  run_case friendly 'Opus 4.8 · Working' anthropic/claude-opus-4-8-20260101
  expect_code 0 "$RC" "a provider prefix, date stamp, and friendly header name should still match: $OUT"
  pass "fm-spawn: model match ignores provider prefix, date stamp, and friendly casing"
}

test_model_not_found_fails_and_keeps_worktree() {
  run_case notfound 'Model "claude-opus-9" not found. Use --list-models to see choices.' claude-opus-9
  assert_equals 1 "$RC" "a model-not-found worker must fail the spawn"
  assert_contains "$OUT" "was not verified" "diagnostic did not say the spawn was not verified"
  assert_contains "$OUT" "claude-opus-9" "diagnostic did not name the missing model"
  assert_contains "$OUT" "worktree and window" "diagnostic did not say the worktree and window are left untouched"
  assert_present "$WT_DIR/.git" "the worktree must stay intact after a failed proof"
  assert_present "$WT_DIR" "the worktree directory must remain"
  [ -s "$FAKEBIN/.spawn-window" ] || fail "the worker window must not be closed by a failed proof"
  assert_grep 'launch not verified'  "$HOME_DIR/state/$ID.status" "the failure was not recorded in the status log"
  assert_not_contains "$OUT" "spawned $ID" "a failed proof must not report the spawn"
  pass "fm-spawn: model-not-found fails with a plain diagnostic and leaves the worktree"
}

test_wrong_model_fails() {
  run_case wrong 'pi  claude-sonnet-5-5   ↑5k ↓1k' claude-opus-4-8
  assert_equals 1 "$RC" "a worker running a different model must fail the spawn"
  assert_contains "$OUT" "never showed the requested model 'claude-opus-4-8'" "diagnostic did not name the mismatch"
  assert_present "$WT_DIR/.git" "the worktree must stay intact after a model mismatch"
  pass "fm-spawn: a different model than requested fails the spawn"
}

test_no_start_fails() {
  run_case idle '$ ' claude-opus-4-8
  assert_equals 1 "$RC" "a worker that never processes its brief must fail the spawn"
  assert_contains "$OUT" "no sign of processing the brief" "diagnostic did not say the worker never started"
  assert_present "$WT_DIR/.git" "the worktree must stay intact when the worker never started"
  pass "fm-spawn: a worker that never starts fails the spawn"
}

test_gate_can_be_turned_off() {
  local rec
  rec=$(make_case off)
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN ID <<EOF
$rec
EOF
  OUT=$(FM_SPAWN_VERIFY=0 fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" \
    "$ID" "$PROJ_DIR" grok --model claude-opus-4-8 --mode no-mistakes --yolo off)
  expect_code 0 $? "FM_SPAWN_VERIFY=0 must skip the proof: $OUT"
  pass "fm-spawn: FM_SPAWN_VERIFY=0 skips the proof"
}

test_verified_launch_passes
test_provider_prefix_and_friendly_name_match
test_model_not_found_fails_and_keeps_worktree
test_wrong_model_fails
test_no_start_fails
test_gate_can_be_turned_off
