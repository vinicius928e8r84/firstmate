#!/usr/bin/env bash
# Behavioral coverage for bin/fm-review-sweep.sh with stand-in fm-pr-ready, fm-spawn-task, review-record, review-pin and rules tools:
# a new head opens one scout and is never requested twice, drafts and PRs behind main are skipped, a spawn refused for capacity is
# retried without a duplicate, several PRs open several scouts at once, the profile rule, --dry-run, the lock, and the harvest of
# finished reports into review records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-review-sweep)
SWEEP="$ROOT/bin/fm-review-sweep.sh"
OWNER=vinicius928e8r84
HA=aaaaaaaa11111111111111111111111111111111
HB=bbbbbbbb22222222222222222222222222222222
HC=cccccccc33333333333333333333333333333333

# new_home <name>: a home with the three projects and stand-in tools; the PR rows come from $H/ready.json.
new_home() {
  H="$TMP_ROOT/$1"; B="$H/bin"; mkdir -p "$H/state" "$H/data" "$B" "$H/projects/multimodel-core" "$H/projects/PerpetualMiner" "$H/projects/modo-caverna"
  export FM_HOME="$H" FM_READY_BIN="$B/ready" FM_RECORD_BIN="$B/record" FM_PIN_BIN="$B/pin" FM_SPAWN_TASK_BIN="$B/spawn-task" FM_REVIEW_RULES_BIN="$B/rules"
  export FM_REVIEW_SWEEP_NOW=1000000
  printf '{"rows":[]}\n' > "$H/ready.json"
  printf '#!/usr/bin/env bash\ncat %q\n' "$H/ready.json" > "$B/ready"
  # the stand-in spawn: SPAWN_RC non-zero refuses; NO_PROFILE_RC refuses a spawn that carries no --harness (resolver cannot decide)
  cat > "$B/spawn-task" <<S
#!/usr/bin/env bash
echo "\$*" >> '$H/spawn.calls'
id=\$2
case " \$* " in *" --harness "*) has=1 ;; *) has=0 ;; esac
if [ "\$has" = 0 ] && [ -n "\${NO_PROFILE_RC:-}" ]; then echo "REFUSED \$id: profile: dispatch status 'ambiguous'"; exit 1; fi
if [ -n "\${SPAWN_RC:-}" ]; then echo "REFUSED \$id: spawn: fm-spawn exited \$SPAWN_RC"; exit "\$SPAWN_RC"; fi
touch '$H/state/'"\$id".meta
echo "SPAWNED \$id kind=scout project=\$3 verify=OK"
S
  # shellcheck disable=SC2016 # the stand-in expands its arguments when it runs
  printf '#!/usr/bin/env bash\necho "$*" >> %q\n[ "${1:-}" = read ] && exit 1\nexit 0\n' "$H/record.calls" > "$B/record"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\nexit 0\n' "$H/pin.calls" > "$B/pin"
  printf '#!/usr/bin/env bash\necho "Reviewer standing rules:"\necho "- stand-in rule"\n' > "$B/rules"
  chmod +x "$B"/*
}
# row <repo> <pr> <head> <verdict> <review> [draft] [risk]
row() {
  printf '{"repo":"%s/%s","pr":%s,"head":"%s","url":"https://github.com/%s/%s/pull/%s","verdict":"%s","review":"%s","draft":%s,"risk":"%s"}' \
    "$OWNER" "$1" "$2" "$3" "$OWNER" "$1" "$2" "$4" "$5" "${6:-false}" "${7:-MEDIUM}"
}
ready() { { echo '{"rows":['; local first=1 r; for r in "$@"; do [ $first = 1 ] || echo ,; first=0; echo "$r"; done; echo ']}'; } > "$H/ready.json"; }
sweep() { out=$("$SWEEP" "$@" 2>&1); rc=$?; }
calls() { if [ -f "$H/spawn.calls" ]; then wc -l < "$H/spawn.calls" | tr -d ' '; else echo 0; fi; }
id_a() { echo "rv-$1$2-${3:0:8}"; }

test_new_head_once() {
  new_home once; ready "$(row PerpetualMiner 355 $HA NEEDS-REVIEW none)"
  sweep
  expect_code 0 "$rc" "sweep exit"
  assert_contains "$out" "OPEN PerpetualMiner#355 head aaaaaaaa" "a new head opens a review"
  assert_equals 1 "$(calls)" "one scout spawned"
  assert_contains "$(cat "$H/spawn.calls")" "scout rv-pm355-aaaaaaaa PerpetualMiner --title Independent review PerpetualMiner#355" "scout spawn through fm-spawn-task"
  assert_present "$H/state/rv-pm355-aaaaaaaa.meta" "the scout is live"
  spec=$(cat "$H/data/review-sweep/specs/rv-pm355-aaaaaaaa.spec")
  assert_contains "$spec" "Review exactly head $HA of $OWNER/PerpetualMiner#355 (https://github.com/$OWNER/PerpetualMiner/pull/355)" "spec names URL and exact head"
  assert_contains "$spec" "INTEGRATED with the current base branch" "integrated-code rule"
  assert_contains "$spec" "Only P0 and P1 block" "blocking rule"
  assert_contains "$spec" "data/rv-pm355-aaaaaaaa/report.md" "report path"
  assert_contains "$spec" "stand-in rule" "the standing reviewer rules are appended"
  assert_contains "$(cat "$H/data/review-sweep/specs/rv-pm355-aaaaaaaa.task")" "risk level MEDIA" "task carries the risk level"
  sweep
  assert_contains "$out" "SKIP PerpetualMiner#355: review of head aaaaaaaa already requested" "same head is not requested again"
  assert_equals 1 "$(calls)" "still one scout"
  ready "$(row PerpetualMiner 355 $HB NEEDS-REVIEW stale)"
  sweep
  assert_equals 2 "$(calls)" "a new head of the same PR opens a new review"
  pass "a new head opens one scout, the same head is never requested again, a moved head is"
}

test_skips() {
  new_home skips
  ready "$(row modo-caverna 1 $HA NEEDS-DECISION none true)" "$(row modo-caverna 2 $HB NEEDS-UPDATE none)" \
    "$(row modo-caverna 3 $HC READY ok)" "$(row modo-caverna 4 $HA NEEDS-REVIEW findings)" "$(row modo-caverna 5 $HB NEEDS-CI none)"
  sweep
  assert_contains "$out" "SKIP modo-caverna#1: draft" "draft skipped"
  assert_contains "$out" "SKIP modo-caverna#2: verdict NEEDS-UPDATE" "behind main skipped"
  assert_contains "$out" "SKIP modo-caverna#3: head cccccccc already has a review record (ok)" "reviewed head skipped"
  assert_contains "$out" "SKIP modo-caverna#4:" "head with findings skipped"
  assert_contains "$out" "OPEN modo-caverna#5" "red CI does not hold back the first review"
  assert_equals 1 "$(calls)" "only the red-CI PR opened"
  pass "drafts, PRs behind main and heads with a record are skipped; red CI still gets the first review"
}

test_capacity_retry() {
  new_home cap; ready "$(row multimodel-core 9 $HA NEEDS-REVIEW none)"
  SPAWN_RC=75 sweep
  assert_contains "$out" "DEFER multimodel-core#9" "capacity refusal is a deferral"
  assert_contains "$out" "deferred=1" "summary counts it"
  assert_absent "$H/state/rv-mmc9-aaaaaaaa.meta" "nothing live"
  sweep
  assert_contains "$out" "OPEN multimodel-core#9" "retried next sweep"
  sweep
  assert_contains "$out" "already requested" "and never a third time"
  assert_equals 2 "$(calls)" "two spawn attempts, one scout"
  assert_equals 2 "$(grep -c 'rv-mmc9-aaaaaaaa' "$H/spawn.calls")" "both attempts use the same id, so the brief resumes"
  new_home fail; ready "$(row multimodel-core 9 $HA NEEDS-REVIEW none)"
  SPAWN_RC=1 sweep
  assert_contains "$out" "FAIL multimodel-core#9" "a refused spawn is reported"
  sweep
  assert_contains "$out" "OPEN multimodel-core#9" "a failure does not count as requested"
  pass "a spawn refused for capacity or failing is retried next sweep without a duplicate"
}

test_parallel_and_profile() {
  new_home par
  ready "$(row multimodel-core 11 $HA NEEDS-REVIEW none false HIGH)" "$(row PerpetualMiner 12 $HB NEEDS-REVIEW none false LOW)" "$(row modo-caverna 13 $HC NEEDS-REVIEW none false MEDIUM)"
  sweep
  assert_contains "$out" "opened=3" "three PRs open three scouts at once"
  assert_equals 3 "$(calls)" "three spawns"
  assert_contains "$(grep 'rv-mmc11' "$H/spawn.calls")" "--harness pi --model claude-bridge/claude-opus-5-5 --effort high" "HIGH runs on Opus"
  assert_not_contains "$(grep 'rv-pm12' "$H/spawn.calls")" "--harness" "LOW follows the dispatch rule"
  assert_contains "$(cat "$H/data/review-sweep/specs/rv-mmc11-aaaaaaaa.spec")" "Be exact" "HIGH asks for exact proof"
  new_home fb; ready "$(row PerpetualMiner 12 $HB NEEDS-REVIEW none false LOW)"
  NO_PROFILE_RC=1 sweep
  assert_contains "$out" "OPEN PerpetualMiner#12" "an undecided resolver falls back to the Opus review profile"
  assert_contains "$(tail -1 "$H/spawn.calls")" "claude-opus-5-5" "fallback profile passed"
  pass "several PRs open several scouts, HIGH runs on Opus, an undecided rule falls back to Opus"
}

test_dry_run() {
  new_home dry; ready "$(row PerpetualMiner 355 $HA NEEDS-REVIEW none false HIGH)"
  sweep --dry-run
  expect_code 0 "$rc" "dry run exit"
  assert_contains "$out" "WOULD OPEN PerpetualMiner#355 head aaaaaaaa risk=HIGH" "dry run lists the review"
  assert_contains "$out" "dry-run: nothing changed" "summary says so"
  assert_absent "$H/spawn.calls" "no spawn"
  assert_absent "$H/data/review-sweep" "no registry, no lock directory"
  pass "--dry-run lists WOULD OPEN and changes nothing"
}

test_lock() {
  new_home lock; ready "$(row PerpetualMiner 355 $HA NEEDS-REVIEW none)"
  mkdir -p "$H/data/review-sweep"
  (
    exec 9>"$H/data/review-sweep/.lock"; flock 9
    sweep
    echo "$rc|$out" > "$H/lock.result"
  )
  assert_contains "$(cat "$H/lock.result")" "SWEEP-BUSY" "a second sweep exits at once"
  assert_absent "$H/spawn.calls" "and spawns nothing"
  pass "a held sweep lock stops a second sweep"
}

test_harvest() {
  new_home harv
  ready "$(row PerpetualMiner 20 $HA NEEDS-REVIEW none false HIGH)" "$(row PerpetualMiner 21 $HB NEEDS-REVIEW none)" "$(row PerpetualMiner 22 $HC NEEDS-REVIEW none)"
  sweep
  assert_equals 3 "$(calls)" "three scouts"
  mkdir -p "$H/data/rv-pm20-aaaaaaaa" "$H/data/rv-pm21-bbbbbbbb" "$H/data/rv-pm22-cccccccc"
  printf 'CLEAN %s\n\nBlocking findings (P0/P1): 0\n' "$HA" > "$H/data/rv-pm20-aaaaaaaa/report.md"
  printf '**NOT CLEAN** %s\nBlocking findings (P0/P1): 2\n' "${HB:0:12}" > "$H/data/rv-pm21-bbbbbbbb/report.md"
  printf 'CLEAN deadbeef00 (a different head)\n' > "$H/data/rv-pm22-cccccccc/report.md"
  ready "$(row PerpetualMiner 20 $HA NEEDS-REVIEW none false HIGH)" "$(row PerpetualMiner 21 $HB NEEDS-REVIEW none)" "$(row PerpetualMiner 22 $HC NEEDS-REVIEW none)"
  sweep
  assert_contains "$out" "HARVEST PerpetualMiner#20 head aaaaaaaa clean open=0" "clean report harvested"
  assert_contains "$out" "HARVEST PerpetualMiner#21 head bbbbbbbb findings open=2" "not-clean report harvested with its count"
  assert_contains "$out" "PerpetualMiner#22: rv-pm22-cccccccc report does not start with" "a report for another head is not recorded"
  rec=$(cat "$H/record.calls")
  assert_contains "$rec" "write $OWNER/PerpetualMiner 20 --head $HA --verdict clean --open-findings 0 --reviewer scout:rv-pm20-aaaaaaaa --risk HIGH" "record written for the exact head"
  assert_contains "$rec" "write $OWNER/PerpetualMiner 21 --head $HB --verdict findings --open-findings 2" "findings record"
  assert_not_contains "$rec" "PerpetualMiner 22" "nothing recorded for the mismatched report"
  assert_contains "$(cat "$H/pin.calls")" "record $OWNER/PerpetualMiner 20 $HA" "a clean review is pinned"
  assert_not_contains "$(cat "$H/pin.calls")" "PerpetualMiner 21" "a review with findings is not pinned"
  sweep
  assert_equals 2 "$(wc -l < "$H/record.calls" | tr -d ' ')" "a harvested review is not recorded twice"
  assert_equals 3 "$(calls)" "and no review is repeated"
  new_home dryh; ready "$(row PerpetualMiner 20 $HA NEEDS-REVIEW none)"
  sweep; mkdir -p "$H/data/rv-pm20-aaaaaaaa"; printf 'CLEAN %s\n' "$HA" > "$H/data/rv-pm20-aaaaaaaa/report.md"
  sweep --dry-run
  assert_contains "$out" "WOULD HARVEST PerpetualMiner#20 head aaaaaaaa clean open=0" "dry run lists the harvest"
  assert_absent "$H/record.calls" "and writes no record"
  pass "finished reports become review records for the exact head; mismatched reports are not recorded"
}

test_lost() {
  new_home lost; ready "$(row PerpetualMiner 30 $HA NEEDS-REVIEW none)"
  sweep
  rm -f "$H/state/rv-pm30-aaaaaaaa.meta"
  FM_REVIEW_SWEEP_NOW=$((1000000 + 100)) sweep
  assert_contains "$out" "already requested" "inside the grace period the review is still waited for"
  FM_REVIEW_SWEEP_NOW=$((1000000 + 30000)) sweep
  assert_contains "$out" "LOST PerpetualMiner#30" "a review with no task and no report is lost after the grace period"
  assert_contains "$out" "OPEN PerpetualMiner#30 head aaaaaaaa" "and the head is reviewed again"
  assert_contains "$(tail -1 "$H/spawn.calls")" "scout rv-pm30-aaaaaaaa-r1 PerpetualMiner" "under a new id"
  pass "a lost review is detected after the grace period and reopened under a new id"
}

test_new_head_once
test_skips
test_capacity_retry
test_parallel_and_profile
test_dry_run
test_lock
test_harvest
test_lost

echo '# all fm-review-sweep tests passed'
