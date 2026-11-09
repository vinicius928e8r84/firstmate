#!/usr/bin/env bash
# Behavioral coverage for bin/fm-request-log-retention.sh: requests older than the raw window are packed per UTC hour into
# archive/<hour>.tar.zst and removed only after the archive verifies; newer requests, requests still being written or held
# open, and keep/ stay untouched; dry-run changes nothing; old archives are pruned; a failed verification keeps the originals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v zstd >/dev/null 2>&1 || { echo "# skip: zstd not installed"; exit 0; }
RET="$ROOT/bin/fm-request-log-retention.sh"
NOW=$(date -u -d '2026-11-09 15:00:00' +%s)

# mkreq <logs-dir> <UTC stamp YYYY-MM-DDTHH-MM-SS-mmm> [mtime-offset-seconds-before-NOW]
mkreq() {
  local d=$1 st=$2 age=${3:-3600} s
  for s in md request.txt response.txt; do
    printf 'body of %s %s\n' "$st" "$s" > "$d/${st}_claude-code.$s"
    touch -d "@$((NOW - age))" "$d/${st}_claude-code.$s"
  done
}

fixture() {
  local root; root=$(fm_test_tmproot fm-reqlog) || fail "tmproot"
  mkdir -p "$root/logs" "$root/keep"
  mkreq "$root/logs" 2026-11-09T01-10-00-000 50000
  mkreq "$root/logs" 2026-11-09T01-40-00-000 50000
  mkreq "$root/logs" 2026-11-09T02-05-00-000 45000
  mkreq "$root/logs" 2026-11-09T10-00-00-000 18000
  mkreq "$root/logs" 2026-11-09T14-58-30-000 90
  printf 'keep me\n' > "$root/keep/2026-11-09T01-00-00-000_claude-code.md"
  printf '%s\n' "$root"
}

run() { RL_NOW=$NOW RL_ZSTD_LEVEL=3 "$RET" --dir "$1" "${@:2}" 2>&1; }

test_dry_run_changes_nothing() {
  local root out rc before after
  root=$(fixture); before=$(find "$root" -type f | sort | xargs md5sum | md5sum)
  out=$(run "$root" --dry-run); rc=$?
  expect_code 0 "$rc" "dry-run exit"
  after=$(find "$root" -type f ! -name .lock | sort | xargs md5sum | md5sum)
  assert_equals "$before" "$after" "dry-run left every file as it was"
  assert_contains "$out" "pack 2026-11-09T01: 6 files" "hour 01 would be packed"
  assert_contains "$out" "pack 2026-11-09T02: 3 files" "hour 02 would be packed"
  assert_contains "$out" "would be packed" "summary says would"
  pass "dry-run lists the hours and writes nothing"
}

test_apply_packs_old_and_keeps_recent() {
  local root out rc
  root=$(fixture)
  out=$(run "$root" --apply); rc=$?
  expect_code 0 "$rc" "apply exit"
  assert_present "$root/archive/2026-11-09T01.tar.zst" "hour 01 archive"
  assert_present "$root/archive/2026-11-09T02.tar.zst" "hour 02 archive"
  assert_absent "$root/logs/2026-11-09T01-10-00-000_claude-code.request.txt" "packed original removed"
  assert_absent "$root/logs/2026-11-09T02-05-00-000_claude-code.md" "packed md removed"
  assert_present "$root/logs/2026-11-09T10-00-00-000_claude-code.md" "request inside the raw window stays readable"
  assert_present "$root/logs/2026-11-09T10-00-00-000_claude-code.request.txt" "raw request stays"
  assert_present "$root/logs/2026-11-09T14-58-30-000_claude-code.response.txt" "newest request stays"
  assert_equals "keep me" "$(cat "$root/keep/2026-11-09T01-00-00-000_claude-code.md")" "keep/ untouched"
  assert_equals "body of 2026-11-09T01-40-00-000 request.txt" \
    "$(zstd -dc --long=27 "$root/archive/2026-11-09T01.tar.zst" | tar -xOf - 2026-11-09T01-40-00-000_claude-code.request.txt)" \
    "archive returns the original bytes"
  assert_contains "$out" "ok:" "verification reported"
  pass "apply packs requests older than 6 h per hour and leaves the rest"
}

test_busy_and_fresh_requests_are_skipped() {
  local root pid
  root=$(fixture)
  mkreq "$root/logs" 2026-11-09T03-00-00-000 50000
  mkreq "$root/logs" 2026-11-09T03-30-00-000 60       # old stamp but modified a minute ago: still being written
  exec 7< "$root/logs/2026-11-09T03-00-00-000_claude-code.request.txt"
  sleep 30 <&7 & pid=$!
  exec 7<&-
  run "$root" --apply >/dev/null
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_present "$root/logs/2026-11-09T03-00-00-000_claude-code.request.txt" "file held open by a live process stays"
  assert_present "$root/logs/2026-11-09T03-30-00-000_claude-code.md" "request modified in the last 5 minutes stays"
  assert_absent "$root/logs/2026-11-09T02-05-00-000_claude-code.md" "other old requests still packed"
  pass "requests being written or held open are never packed"
}

test_second_run_never_overwrites_an_archive() {
  local root
  root=$(fixture)
  run "$root" --apply >/dev/null
  mkreq "$root/logs" 2026-11-09T01-50-00-000 50000
  run "$root" --apply >/dev/null
  assert_present "$root/archive/2026-11-09T01.tar.zst" "first archive kept"
  assert_present "$root/archive/2026-11-09T01.2.tar.zst" "straggler goes to a second archive"
  pass "a later run for an archived hour writes a new archive"
}

test_old_archives_are_pruned() {
  local root
  root=$(fixture); mkdir -p "$root/archive"
  printf x > "$root/archive/2026-09-01T00.tar.zst"; touch -d "@$((NOW - 40*86400))" "$root/archive/2026-09-01T00.tar.zst"
  printf x > "$root/archive/2026-11-01T00.tar.zst"; touch -d "@$((NOW - 8*86400))" "$root/archive/2026-11-01T00.tar.zst"
  run "$root" --apply >/dev/null
  assert_absent "$root/archive/2026-09-01T00.tar.zst" "archive older than 30 days pruned"
  assert_present "$root/archive/2026-11-01T00.tar.zst" "younger archive kept"
  pass "archives past --archive-days are deleted"
}

test_failed_verification_keeps_originals() {
  local root fake out rc
  root=$(fixture); fake=$(fm_test_tmproot fm-reqlog-fake)
  # shellcheck disable=SC2016 # the fake's script text must keep $1 and "$@" literal
  printf '#!/usr/bin/env bash\ncase "$1" in -tq) exit 1;; esac\nexec %s "$@"\n' "$(command -v zstd)" > "$fake/zstd"
  chmod +x "$fake/zstd"
  out=$(PATH="$fake:$PATH" run "$root" --apply); rc=$?
  expect_code 1 "$rc" "verification failure exits 1"
  assert_contains "$out" "FAILED verification" "failure reported"
  assert_present "$root/logs/2026-11-09T01-10-00-000_claude-code.request.txt" "original kept when the archive does not verify"
  assert_absent "$root/archive/2026-11-09T01.tar.zst" "no archive published"
  assert_equals "" "$(find "$root/archive" -name '*.part' | head -1)" "no partial file left"
  pass "a failed verification keeps the originals and publishes nothing"
}

test_bad_usage() {
  local rc
  "$RET" --raw-hours x >/dev/null 2>&1; rc=$?; expect_code 64 "$rc" "non-numeric window refused"
  "$RET" --bogus >/dev/null 2>&1; rc=$?; expect_code 64 "$rc" "unknown flag refused"
  pass "bad arguments exit 64"
}

test_dry_run_changes_nothing
test_apply_packs_old_and_keeps_recent
test_busy_and_fresh_requests_are_skipped
test_second_run_never_overwrites_an_archive
test_old_archives_are_pruned
test_failed_verification_keeps_originals
test_bad_usage

echo '# all fm-request-log-retention tests passed'
