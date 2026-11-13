#!/usr/bin/env bash
# tests/fm-fleet-card.test.sh - bin/fm-fleet-card.sh: the card a context re-emit
# prints first. It must carry every section from plain files, never write or
# lock anything, hold its byte ceiling without dropping the open decisions, and
# stay quiet-but-valid on an empty home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CARD="$ROOT/bin/fm-fleet-card.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-card-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

card() { FM_HOME="$1" FM_CARD_TZ=UTC "$CARD" "${@:2}"; }

# A home that carries every source the card reads.
make_home() {  # <name>
  local h="$TMP_ROOT/$1" now
  now=$(date +%s)
  mkdir -p "$h/state/procevent-inbox" "$h/data"
  # Notices: 3 rows, 2 distinct keys.
  printf '%s\t1\tcheck\tprocevent:a:1\tcheck: one\n%s\t2\tcheck\tprocevent:a:1\tcheck: one\n%s\t3\tsignal\tt-1\tdone: x\n' \
    "$((now - 600))" "$((now - 500))" "$((now - 400))" > "$h/state/.wake-queue"
  printf '2026-11-13T10:00:00.000Z inline-ack through=41 attempt=0 status=0\n2026-11-13T10:05:00.000Z inline-drain unavailable status=timeout\n' \
    > "$h/state/.watch-extension.log"
  # A ship with a PR waiting for the captain, a yolo ship with a ready branch, a working scout.
  printf 'window=w:1\nkind=ship\nmode=no-mistakes\nyolo=off\n' > "$h/state/ship-pr.meta"
  printf 'done [at=%s]: PR ready https://github.com/o/r/pull/77\n' "$((now - 90))" > "$h/state/ship-pr.status"
  printf 'window=w:2\nkind=ship\nmode=local-only\nyolo=on\n' > "$h/state/ship-br.meta"
  printf 'done [at=%s]: ready in branch fm/ship-br\n' "$((now - 90))" > "$h/state/ship-br.status"
  printf 'window=w:3\nkind=scout\n' > "$h/state/scout-w.meta"
  printf 'working [at=%s]: reading the report\n' "$((now - 30))" > "$h/state/scout-w.status"
  # One open decision persisted by the drain's fold.
  printf 'working [at=%s]: begin\nneeds-decision [at=%s] [dec-key]: which option?\n' "$((now - 60))" "$((now - 50))" > "$h/state/scout-d.status"
  printf 'window=w:4\nkind=scout\n' > "$h/state/scout-d.meta"
  printf 'version=9:scout\noffset=10\nident=strong:1:2:x\ndec-key\tneeds-decision\twhich option?\n' > "$h/state/.scout-d.open-decisions-cursor"
  # Backlog with a held item and queued items.
  cat > "$h/data/backlog.md" <<BL
# Backlog

## In flight

## Queued
- [ ] held-1 - Held thing (repo: r) (kind: ship) (hold: captain call)
- [ ] q-1 - First queued (repo: r) (kind: ship)
- [ ] q-2 - Second queued (repo: r) (kind: ship)

## Done
- [x] old-1 - done long ago (hold: gone)
BL
  printf 'k1\t%s\t%s\t2\topen\tShould I merge 77?\nk2\t%s\t%s\t1\tdone\tAlready answered\n' \
    "$now" "$now" "$now" "$now" > "$h/data/captain-asks.tsv"
  printf 'session:\n  status: feedback\n' > "$h/state/procevent-inbox/lavish-aa.1.result"
  printf 'session:\n  status: feedback\n' > "$h/state/procevent-inbox/lavish-bb.1.result"
  : > "$h/state/procevent-inbox/lavish-bb.1.handled"
  printf '%s\n' "$h"
}

test_every_section_is_carried_from_plain_files() {
  local h out
  h=$(make_home full)
  out=$(card "$h")
  assert_contains "$out" "FLEET CARD" "no header"
  assert_contains "$out" "queue: 3 row(s), 2 distinct key(s)" "the notice queue size and distinct keys were not reported"
  assert_contains "$out" "through 41" "the last acknowledgement was not reported"
  assert_contains "$out" "timed out after it: 1" "the timed out drain was not counted after the last acknowledgement"
  assert_contains "$out" "OPEN DECISIONS (1" "the open decision count is missing"
  assert_contains "$out" "scout-d [dec-key] needs-decision: which option?" "the open decision row is missing"
  assert_contains "$out" "https://github.com/o/r/pull/77 ship-pr (needs the captain's word)" "a PR ready for the captain was not queued with its full URL"
  assert_contains "$out" "branch fm/ship-br ship-br (yolo: firstmate merges when green)" "a ready local branch was not queued with its merge authority"
  assert_contains "$out" "HELD FOR CAPTAIN (1 " "the held count is wrong or missing"
  assert_contains "$out" "held-1: Held thing" "the held item is missing"
  assert_not_contains "$out" "old-1" "a Done item with a hold marker leaked onto the card"
  assert_contains "$out" "CAPTAIN ASKS (1 open" "only open asks count"
  assert_contains "$out" "Should I merge 77?" "the open ask text is missing"
  assert_not_contains "$out" "Already answered" "an answered ask was listed"
  assert_contains "$out" "PAGE ANSWERS (1 result(s) with no handled marker)" "the unhandled page answer count is wrong"
  assert_contains "$out" "lavish-aa.1 feedback UNHANDLED" "the unhandled round is not flagged"
  assert_contains "$out" "QUEUED (2 ready to dispatch" "queued count excludes held items"
  assert_contains "$out" "q-1: First queued" "the first queued row is missing"
  assert_contains "$out" "scout-w [scout] working" "the task in flight is missing"
  assert_not_contains "$out" "ship-pr [ship" "a ship already in the merge queue was repeated under in flight"
  case "$out" in *"NOTICES"*"OPEN DECISIONS"*"MERGE QUEUE"*"HELD FOR CAPTAIN"*"CAPTAIN ASKS"*"PAGE ANSWERS"*"QUEUED"*"IN FLIGHT"*) ;; *) fail "sections are not in priority order" ;; esac
  pass "the card carries every section from plain files, in priority order"
}

test_card_reads_only_and_writes_nothing() {
  local h before after
  h=$(make_home readonly)
  before=$(find "$h" -printf '%p %T@ %s\n' | sort)
  card "$h" >/dev/null
  after=$(find "$h" -printf '%p %T@ %s\n' | sort)
  assert_equals "$before" "$after" "the card changed files in the home it only reads"
  pass "the card writes nothing and takes no lock in the home it reads"
}

test_ceiling_cuts_low_priority_sections_but_never_decisions() {
  local h out i
  h=$(make_home ceiling)
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    printf 'window=w:%s\nkind=scout\n' "$i" > "$h/state/many-$i.meta"
    printf 'working [at=%s]: a long running note number %s that keeps going and going\n' "$(date +%s)" "$i" > "$h/state/many-$i.status"
  done
  out=$(card "$h" --max-bytes 1200)
  [ "${#out}" -le 1200 ] || fail "the card is ${#out} bytes, over its 1200 byte ceiling"
  assert_contains "$out" "OPEN DECISIONS (1" "the ceiling dropped the open decisions"
  assert_contains "$out" "scout-d [dec-key]" "the ceiling dropped an open decision row"
  assert_contains "$out" "shortened away to fit 1200 B" "a shortened section did not say so"
  out=$(FM_CARD_MAX_BYTES=1200 card "$h")
  [ "${#out}" -le 1200 ] || fail "FM_CARD_MAX_BYTES did not set the ceiling"
  pass "the ceiling shortens low-priority sections first and never the open decisions"
}

test_many_decisions_shorten_to_task_and_key() {
  local h out i
  h=$(make_home decisions)
  for i in 1 2 3 4 5 6 7; do
    printf 'version=9:scout\noffset=1\nident=x\nkey-%s\tblocked\tnote number %s\n' "$i" "$i" > "$h/state/.dec-$i.open-decisions-cursor"
  done
  out=$(card "$h")
  assert_contains "$out" "- dec-7 [key-7]" "a decision beyond the sixth must still be listed by task and key"
  assert_not_contains "$out" "note number 7" "past six decisions rows are expected to shorten"
  pass "past six open decisions each row shortens to task and key instead of leaving"
}

test_empty_home_prints_a_valid_card() {
  local h="$TMP_ROOT/empty" out status=0
  mkdir -p "$h"
  out=$(card "$h") || status=$?
  expect_code 0 "$status" "an empty home must still exit 0"
  assert_contains "$out" "FLEET CARD" "the empty home printed nothing"
  assert_contains "$out" "OPEN DECISIONS (0" "the empty home did not say it holds no decisions"
  assert_contains "$out" "no data/backlog.md" "the missing backlog is not disclosed"
  pass "an empty home still prints a valid card and exits 0"
}

test_every_section_is_carried_from_plain_files
test_card_reads_only_and_writes_nothing
test_ceiling_cuts_low_priority_sections_but_never_decisions
test_many_decisions_shorten_to_task_and_key
test_empty_home_prints_a_valid_card

echo "# fm-fleet-card.test.sh: all assertions passed"
