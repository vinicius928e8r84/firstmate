#!/usr/bin/env bash
# Behavioral coverage for bin/fm-improvement-feed.sh: the Melhorias table of the newest audit becomes queue rows with an
# owner, a state and a due time (once only), backlog tasks the captain already approved are seeded without a worker and
# without breaking the cap of five in flight, and an approved improvement still without a worker after 24 h reaches
# firstmate as one inbox note per day (a launch reminder first, a give-back-to-the-captain from 48 h on).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-improvement-feed)
FEED="$ROOT/bin/fm-improvement-feed.sh"
QUEUE="$ROOT/bin/fm-improvement-queue.sh"
export FM_HOME="$TMP_ROOT/home"
export FM_AUDIT_QUEUE="$FM_HOME/data/audit-queue.tsv"
export FM_NOTIFY_INBOX="$TMP_ROOT/inbox.sh"
mkdir -p "$FM_HOME/data/audit-daily" "$FM_HOME/state"
cat > "$FM_NOTIFY_INBOX" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/inbox.notes"
SH
chmod +x "$FM_NOTIFY_INBOX"

write_audit() { # <file name>
  cat > "$FM_HOME/data/audit-daily/$1" <<'MD'
# Auditoria

## Gargalos

| # | x | y |
|---|---|---|
| 1 | not an improvement | row |

## Melhorias, por ganho sobre esforço

| # | O quê | Quem / como | Esforço | Ganho |
|---|---|---|---|---|
| 1 | Disparar a trava hoje | **Firstmate (ramo):** o fim da trava passa a ser a renovação | 30 min | evita parada |
| 2 | Página da manhã | **MAIN**, até 08:00: uma página com os textos | 15 min | PRs entram |
| 3 | Apagar os restos | **Capitão**: sim para apagar | 1 sim | 5 h |
| 4 | Usar fm-claude-budget.sh de novo | **MAIN** liga | 5 min | nada |

## O que veio das auditorias anteriores

- **Feitas:** a 2
MD
}

test_ingest_records_owner_state_and_due_once() {
  local out first
  write_audit 2026-11-09.md
  printf '# older\n\n## Melhorias\n\n| # | O quê | Quem | E | G |\n|---|---|---|---|---|\n| 1 | Old one | **MAIN** x | 1 | 1 |\n' > "$FM_HOME/data/audit-daily/2026-11-08.md"
  printf '# appendix\n\n## Melhorias\n\n| # | O quê | Quem | E | G |\n|---|---|---|---|---|\n| 1 | From appendix | **MAIN** x | 1 | 1 |\n' > "$FM_HOME/data/audit-daily/2026-11-09-apendice.md"
  out=$(FM_IMPROVEMENT_NOW=1800000000 "$FEED" ingest)
  assert_contains "$out" "added 20261109-1 [Firstmate]: Disparar a trava hoje" "the owner is the first bold name without its parenthesis"
  assert_contains "$out" "added 20261109-2 [MAIN]: Página da manhã" "a MAIN row"
  assert_contains "$out" "added 20261109-3 [Capitão]: Apagar os restos" "a captain row"
  assert_contains "$out" "skip exists in repo: Usar fm-claude-budget.sh de novo" "a title naming an existing script is not proposed again"
  assert_not_contains "$out" "From appendix" "the appendix is never read"
  assert_not_contains "$out" "Old one" "only the newest audit is read"
  assert_not_contains "$out" "not an improvement" "only the Melhorias table is read"
  first=$("$QUEUE" list | head -1)
  assert_contains "$first" "20261109-1"$'\t'"proposed"$'\t'"Firstmate"$'\t'"Disparar a trava hoje"$'\t'"Firstmate (ramo): o fim da trava" "state, owner and how-note"
  assert_equals "$((1800000000 + 48 * 3600))" "$(awk -F'\t' '$2 == "20261109-1" { print $7 }' "$FM_AUDIT_QUEUE")" "the due time is 48 h out"
  out=$(FM_IMPROVEMENT_NOW=1800003600 "$FEED" ingest)
  assert_contains "$out" "skip known: Página da manhã" "a second run does not record a title twice"
  assert_contains "$out" "0 recorded" "a second run records nothing new"
  assert_equals 3 "$("$QUEUE" list | wc -l | tr -d ' ')" "three ids, no duplicates"
  pass "ingest records each Melhorias row once with owner, state and due time"
}

test_ingest_dry_run_and_missing_audit() {
  local before out rc
  before=$(wc -l < "$FM_AUDIT_QUEUE")
  write_audit 2026-11-10.md
  sed -i 's/Página da manhã/Página da tarde/' "$FM_HOME/data/audit-daily/2026-11-10.md"
  out=$("$FEED" ingest --dry-run)
  assert_contains "$out" "would add [MAIN]: Página da tarde" "dry run reports"
  assert_equals "$before" "$(wc -l < "$FM_AUDIT_QUEUE")" "dry run writes nothing"
  rm -f "$FM_HOME/data/audit-daily/2026-11-10.md"
  out=$(FM_AUDIT_DIR="$TMP_ROOT/none" "$FEED" ingest 2>&1); rc=$?
  expect_code 1 "$rc" "no audit report is an error"
  pass "ingest --dry-run writes nothing and a missing audit is reported"
}

make_backlog() {
  cat > "$FM_HOME/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] busy-one - something running (repo: firstmate) (kind: ship) (since 2026-11-09)
## Queued
- [ ] t-new - newest task (repo: firstmate) (kind: ship) (since 2026-11-03)
- [ ] t-a - oldest task (repo: firstmate) (kind: ship) (since 2026-10-26)
- [ ] t-b - second task (repo: firstmate) (kind: ship) (since 2026-10-29)
- [ ] t-c - third (repo: firstmate) (kind: ship) (since 2026-10-31)
- [ ] t-d - fourth (repo: firstmate) (kind: ship) (since 2026-10-31)
- [ ] t-e - fifth (repo: firstmate) (kind: ship) (since 2026-10-31)
- [ ] t-f - sixth (repo: firstmate) (kind: ship) (since 2026-10-31)
MD
}

test_seed_respects_the_cap_and_creates_no_worker() {
  local out rc
  export FM_AUDIT_QUEUE="$FM_HOME/data/audit-queue-seed.tsv"
  rm -f "$FM_AUDIT_QUEUE"
  make_backlog
  out=$(FM_IMPROVEMENT_NOW=1800000000 "$FEED" seed t-new t-a t-b t-c t-d t-e t-f 2>&1); rc=$?
  expect_code 0 "$rc" "seed succeeded: $out"
  assert_equals 5 "$("$QUEUE" wip)" "exactly the cap is approved"
  assert_contains "$("$QUEUE" list | grep 't-a:')" "approved" "the oldest task is approved first"
  assert_contains "$("$QUEUE" list | grep 't-b:')" "approved" "then the next oldest"
  assert_contains "$("$QUEUE" list | grep 't-new:')" "proposed" "the newest waits for a slot"
  assert_contains "$("$QUEUE" list | grep 't-new:')" "aprovada pelo dono; espera vaga" "a waiting task says why"
  assert_equals "t-a" "$("$QUEUE" list | head -1 | awk -F'\t' '{print $4}' | cut -d: -f1)" "the ledger order is the oldest-first order"
  assert_equals 7 "$("$QUEUE" list | wc -l | tr -d ' ')" "seven ids recorded"
  assert_not_contains "$(cat "$FM_HOME/data/backlog.md")" "approved" "the backlog is untouched"
  assert_absent "$FM_HOME/state/t-a.meta" "no worker state was created"
  out=$("$FEED" seed t-a t-b 2>&1)
  assert_contains "$out" "skip known: t-a" "seeding again records nothing"
  assert_equals 7 "$("$QUEUE" list | wc -l | tr -d ' ')" "still seven ids"
  out=$("$FEED" seed no-such-task 2>&1); rc=$?
  expect_code 1 "$rc" "an unknown task id is an error"
  assert_contains "$out" "no-such-task is not a Queued task" "the error names the id"
  pass "seed approves the oldest five, queues the rest, and creates neither a worker nor a backlog change"
}

test_watch_promotes_and_alerts_once_a_day() {
  local base=1800000000 notes id
  rm -f "$FM_HOME/inbox.notes"; rm -rf "$FM_HOME/state/.improvement-feed"
  # seeded at $base: approved, due $base+24h
  FM_IMPROVEMENT_NOW=$((base + 3600 * 23)) "$FEED" watch >/dev/null
  assert_absent "$FM_HOME/inbox.notes" "no alert inside 24 h"
  FM_IMPROVEMENT_NOW=$((base + 3600 * 25)) "$FEED" watch >/dev/null
  notes=$(cat "$FM_HOME/inbox.notes")
  assert_equals 1 "$(wc -l < "$FM_HOME/inbox.notes" | tr -d ' ')" "one note for all stale ids"
  assert_contains "$notes" "(t-a: oldest task)" "the note names a stale task"
  assert_contains "$notes" "Lancar o worker agora" "the first day asks firstmate to launch"
  assert_not_contains "$notes" "devolver ao dono" "not yet a give-back"
  FM_IMPROVEMENT_NOW=$((base + 3600 * 26)) "$FEED" watch >/dev/null
  assert_equals 1 "$(wc -l < "$FM_HOME/inbox.notes" | tr -d ' ')" "the same day does not repeat"
  FM_IMPROVEMENT_NOW=$((base + 3600 * 52)) "$FEED" watch >/dev/null
  assert_equals 2 "$(wc -l < "$FM_HOME/inbox.notes" | tr -d ' ')" "the next day repeats once"
  assert_contains "$(tail -1 "$FM_HOME/inbox.notes")" "devolver ao dono para descartar" "past 48 h the item goes back to the captain"
  # a worker for t-a, and t-b dropped: t-b frees a slot, the waiting task takes it
  id=$("$QUEUE" list | awk -F'\t' '$4 ~ /^t-a:/ {print $1}')
  "$QUEUE" set "$id" building "worker started" >/dev/null
  id=$("$QUEUE" list | awk -F'\t' '$4 ~ /^t-b:/ {print $1}')
  "$QUEUE" set "$id" dropped "captain dropped it" >/dev/null
  assert_equals 4 "$("$QUEUE" wip)" "a dropped task frees a slot"
  assert_contains "$(FM_IMPROVEMENT_NOW=$((base + 3600 * 53)) "$FEED" watch)" "promoted" "watch fills the free slot"
  assert_equals 5 "$("$QUEUE" wip)" "the cap is full again"
  assert_contains "$("$QUEUE" list | grep 't-f:')" "approved" "the oldest waiting task was promoted"
  assert_contains "$("$QUEUE" list | grep 't-new:')" "proposed" "the newer waiting task keeps waiting"
  assert_not_contains "$("$QUEUE" stale | cut -f1)" "$("$QUEUE" list | awk -F'\t' '$4 ~ /^t-a:/ {print $1}')" "a started worker is no longer stale"
  pass "watch promotes into free slots and reminds once a day, then gives the item back to the captain"
}

test_ingest_records_owner_state_and_due_once
test_ingest_dry_run_and_missing_audit
test_seed_respects_the_cap_and_creates_no_worker
test_watch_promotes_and_alerts_once_a_day

echo '# all fm-improvement-feed tests passed'
