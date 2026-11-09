#!/usr/bin/env bash
# Behavioral coverage for bin/fm-spawn-task.sh with stand-in backlog, brief, dispatch, spawn and launch-check
# tools: the task+spec fill, the delivery contract passed through, the profile rules (explicit, clear, off,
# non-clear), the refusals that must not spawn, the resume after a refused spawn, and the one result line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-task)
SPAWN_TASK="$ROOT/bin/fm-spawn-task.sh"

# new_home <name>: a home with stand-in tools; `show` fails until `add` ran, the brief scaffold carries both placeholders.
new_home() {
  H="$TMP_ROOT/$1"; B="$H/bin"; mkdir -p "$H/state" "$H/data" "$B" "$H/projects/widget"
  export FM_HOME="$H" FM_SPAWN_TASK_BIN="$B" FM_VERIFY_LAUNCH="$H/verify"
  cat > "$B/fm-tasks-axi.sh" <<S
#!/usr/bin/env bash
echo "\$*" >> '$H/tasks.calls'
[ "\$1" = show ] && { [ -e '$H/added' ]; exit; }
touch '$H/added'; [ -z "\${TASKS_FAIL:-}" ]
S
  cat > "$B/fm-brief.sh" <<S
#!/usr/bin/env bash
echo "\$*" >> '$H/brief.calls'
mkdir -p '$H/data/'"\$1"; printf '# Task\n## Captain intent\n{TASK}\n## Firstmate spec\n{FIRSTMATE_SPEC}\n' > '$H/data/'"\$1"/brief.md
S
  cat > "$B/fm-dispatch-resolve.sh" <<S
#!/usr/bin/env bash
echo run >> '$H/resolve.calls'
case "\${RESOLVE:-clear}" in
  clear) printf 'dispatch-resolve:\n  status: clear\n  profile: --harness pi --model m1 --effort high\n' ;;
  off) ;;
  *) printf 'dispatch-resolve:\n  status: %s\n' "\$RESOLVE" ;;
esac
S
  cat > "$B/fm-spawn.sh" <<S
#!/usr/bin/env bash
echo "\$*" >> '$H/spawn.calls'
[ -n "\${SPAWN_RC:-}" ] && { echo "refused by capacity"; exit "\$SPAWN_RC"; }
touch '$H/state/'"\$1".meta
S
  # shellcheck disable=SC2016 # the stand-in expands its arguments and VERIFY_OUT when it runs
  printf '#!/usr/bin/env bash\necho "$*" >> %q\necho "${VERIFY_OUT:-OK id processing (relaunched=0)}"\n' "$H/verify.calls" > "$H/verify"
  chmod +x "$B"/*.sh "$H/verify"
  printf 'the task words\n' > "$H/t.task"; printf -- '- the spec\n' > "$H/t.spec"
}
run() { out=$("$SPAWN_TASK" "$@" 2>&1); rc=$?; }
lines() { printf '%s\n' "$out" | grep -c .; }
ship_args() { echo ship "$1" widget --title Title --mode direct-PR --yolo off --files "$H/t"; }

test_ship_happy_path() {
  new_home ship
  run $(ship_args fix-1) --branch-prefix fm/ --base-branch rel
  expect_code 0 "$rc" "ship spawn exit"
  assert_equals 1 "$(lines)" "one output line"
  assert_contains "$out" "SPAWNED fix-1 kind=ship project=widget profile=--harness pi --model m1 --effort high verify=OK" "result line"
  assert_contains "$(cat "$H/tasks.calls")" "add fix-1 --kind ship --repo widget --title Title" "backlog item filed"
  assert_contains "$(cat "$H/brief.calls")" "fix-1 widget --mode direct-PR --branch-prefix fm/ --base-branch rel" "scaffold gets the contract"
  assert_grep 'the task words' "$H/data/fix-1/brief.md" "task filled"
  assert_grep '- the spec' "$H/data/fix-1/brief.md" "spec filled"
  assert_no_grep '{TASK}' "$H/data/fix-1/brief.md" "no placeholder left"
  assert_equals "fix-1 $H/projects/widget --mode direct-PR --yolo off --branch-prefix fm/ --base-branch rel --harness pi --model m1 --effort high" "$(cat "$H/spawn.calls")" "spawn arguments"
  assert_equals "fix-1" "$(cat "$H/verify.calls")" "launch checked"
  pass "ship: backlog, brief fill, contract, resolved profile, spawn, verify, one line"
}

test_scout_and_explicit_profile() {
  new_home scout
  run scout rv-1 widget --title Review --task "$H/t.task" --spec "$H/t.spec" --harness pi --model x --effort low
  expect_code 0 "$rc" "scout exit"
  assert_equals "rv-1 $H/projects/widget --scout --harness pi --model x --effort low" "$(cat "$H/spawn.calls")" "scout spawn args"
  assert_contains "$(cat "$H/brief.calls")" "rv-1 widget --scout" "scout scaffold"
  assert_absent "$H/resolve.calls" "an explicit profile skips the resolver"
  run scout rv-2 widget --title Review --files "$H/t" --mode direct-PR
  expect_code 2 "$rc" "scout with a ship option"
  assert_contains "$out" "refused for a scout" "scout refuses the delivery contract"
  new_home firstmate
  mkdir -p "$H/data"; run scout rv-3 firstmate --title Review --files "$H/t" --harness pi
  assert_contains "$(cat "$H/spawn.calls")" "rv-3 $H --scout" "the firstmate repo is the home itself"
  pass "scout: no contract options, explicit profile skips the resolver, firstmate project dir"
}

test_profile_rules() {
  new_home off; RESOLVE=off run $(ship_args a-1)
  expect_code 0 "$rc" "no dispatch configured"
  assert_equals "a-1 $H/projects/widget --mode direct-PR --yolo off" "$(cat "$H/spawn.calls")" "static harness: no profile flags"
  assert_contains "$out" "profile=static" "reported as static"
  new_home amb; RESOLVE=ambiguous run $(ship_args a-2)
  expect_code 1 "$rc" "ambiguous exit"
  assert_contains "$out" "REFUSED a-2: profile: dispatch status 'ambiguous'" "firstmate must choose"
  assert_absent "$H/spawn.calls" "no spawn without a profile"
  assert_equals 1 "$(lines)" "one line"
  pass "profile: off keeps the static harness, a non-clear status refuses and never spawns"
}

test_refusals_and_resume() {
  new_home usage; run ship u-1 widget --title T --files "$H/t"
  expect_code 2 "$rc" "ship without mode/yolo"
  assert_contains "$out" "needs --mode and --yolo" "contract is mandatory"
  new_home empty; : > "$H/t.spec"; run $(ship_args e-1)
  expect_code 1 "$rc" "empty spec"
  assert_contains "$out" "REFUSED e-1: fill:" "empty spec refused"
  assert_absent "$H/data/e-1" "a failed fill leaves no half brief behind"
  assert_absent "$H/spawn.calls" "nothing spawned"
  new_home capacity; SPAWN_RC=75 run $(ship_args c-1)
  expect_code 75 "$rc" "capacity deferral is passed through"
  assert_contains "$out" "REFUSED c-1: spawn: fm-spawn exited 75" "deferral named"
  assert_present "$H/data/c-1/brief.md" "the filled brief is kept for the retry"
  run $(ship_args c-1)
  expect_code 0 "$rc" "the same command resumes"
  assert_equals 1 "$(wc -l < "$H/brief.calls" | tr -d ' ')" "the brief is not scaffolded twice"
  run $(ship_args c-1)
  expect_code 1 "$rc" "a live task is refused"
  assert_contains "$out" "already live" "live task named"
  new_home bad; VERIFY_OUT="STILL IDLE bad after 150s" run $(ship_args v-1)
  expect_code 1 "$rc" "idle worker"
  assert_contains "$out" "REFUSED v-1: verify: the worker did not start" "a worker that never started is reported"
  run $(ship_args v-2) --no-verify
  assert_contains "$out" "verify=skipped" "explicit skip is visible"
  new_home dry; run $(ship_args d-1) --dry-run
  expect_code 0 "$rc" "dry run"
  assert_contains "$out" "DRY-RUN-OK d-1 kind=ship project=widget would=backlog,brief+fill,profile,spawn,verify" "dry run line"
  assert_absent "$H/tasks.calls" "dry run changes nothing"
  pass "refusals: usage, empty spec, capacity pass-through with resume, live task, idle worker, dry run"
}

test_ship_happy_path
test_scout_and_explicit_profile
test_profile_rules
test_refusals_and_resume

echo '# all fm-spawn-task tests passed'
