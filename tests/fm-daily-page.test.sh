#!/usr/bin/env bash
# Behavior tests for bin/fm-daily-page.sh (the day's captain decision page).
#
# Drives the public environment interface with a stub reader that prints the
# bearings decisions_open JSON and a stub lavish-axi on PATH that keeps its
# session listing in a file, so no case touches a real Lavish server. Pins:
#   1. one card per open captain decision, pt-BR, in the board's markup (a
#      data-lavish-question form and a window.lavish.queuePrompt call), with
#      worker blockers and duplicate keys left out and text escaped;
#   2. the recommended option is preselected when recorded, and only then;
#   3. the same date gives the same file and URL, opens one session only, and
#      does not rewrite an unchanged page;
#   4. an ended session is reported and never reopened;
#   5. ghost holds (a main-home hold that asks to merge a PR that is already
#      merged or closed) are released through the hold script and listed in
#      the footer; doubtful ones stay and say "talvez já resolvida";
#   6. resilience cards from state/resil/cards/ become cards of their own;
#   7. the page is rebuilt at most twice a day unless forced;
#   8. the URL carries the tailnet host, never localhost; an empty list still
#      builds a page; a failing reader leaves the page alone and exits 1.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-daily-page.sh"
TMP_ROOT=$(fm_test_tmproot fm-daily-page)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SESSIONS="$TMP_ROOT/sessions"
LAVISH_LOG="$TMP_ROOT/lavish.log"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"
: > "$SESSIONS"; : > "$LAVISH_LOG"

cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ $# -eq 0 ]; then
  printf 'sessions[1]{file,status,url,pending_prompts,listener}:\n'
  sed 's/^/  /' "${SESSIONS:?}"
  exit 0
fi
file=$1
printf 'open %s\n' "$*" >> "${LAVISH_LOG:?}"
if grep -q "^$file," "$SESSIONS"; then
  printf 'status: existing\n'
else
  id=$(printf '%s' "$file" | cksum | cut -d' ' -f1)
  printf '%s,open,"http://127.0.0.1:4387/session/s%s",0,none\n' "$file" "$id" >> "$SESSIONS"
  printf 'status: created\n'
fi
SH
chmod +x "$FAKEBIN/lavish-axi"

READER_JSON="$TMP_ROOT/reader.json"
cat > "$TMP_ROOT/reader.sh" <<SH
#!/usr/bin/env bash
cat '$READER_JSON'
SH
chmod +x "$TMP_ROOT/reader.sh"
write_decisions() { printf '%s\n' "$1" > "$READER_JSON"; }

run_page() {  # <home-name> [env...]
  local name=$1; shift
  env HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" SESSIONS="$SESSIONS" LAVISH_LOG="$LAVISH_LOG" \
    FM_HOME="$TMP_ROOT/$name" FM_DAILY_PAGE_DATE=2026-10-29 FM_SW_NO_NOTIFY=1 \
    FM_DAILY_PAGE_READER="$TMP_ROOT/reader.sh" FM_DAILY_PAGE_MAX_RUNS=1000 "$@" bash "$TOOL" 2>"$TMP_ROOT/err"
}

write_decisions '{"decisions_open":[
 {"id":"alpha","key":"alpha","verb":"captain-hold","summary":"Publicar o relatório <semanal>? [rec=defer]","owner":"(main)"},
 {"id":"beta","key":"beta","verb":"needs-decision","summary":"Qual runtime usar","owner":"(main)",
  "options":[{"value":"pi","label":"Pi","hint":"padrão"},{"value":"claude","label":"Claude"}],"recommend":"claude"},
 {"id":"gamma","key":"gamma","verb":"blocked","summary":"obstáculo de um worker","owner":"(main)"},
 {"id":"alpha","key":"alpha","verb":"needs-decision","summary":"duplicada","owner":"(main)"},
 {"id":"delta","key":"delta","verb":"captain-hold","summary":"Sem recomendação","owner":"m1","recommend":"inexistente"}
]}'

OUT=$(run_page w1); CODE=$?
expect_code 0 "$CODE" "a run with decisions succeeds"
PAGE="$TMP_ROOT/w1/.lavish/diaria-2026-10-29.html"
assert_present "$PAGE" "the dated page is written under .lavish"
assert_contains "$OUT" "page: $(cd "$TMP_ROOT/w1/.lavish" && pwd -P)/diaria-2026-10-29.html" "the page path is printed"
URL=$(printf '%s\n' "$OUT" | sed -n 's/^url: //p')
case "$URL" in
  http://100.96.168.50:4387/session/s*) pass "daily-page: the URL uses the tailnet host" ;;
  *) fail "unexpected URL '$URL'" ;;
esac
assert_not_contains "$OUT" "127.0.0.1" "the stub's local host never leaks"
assert_not_contains "$OUT" "localhost" "localhost never leaks"

HTML=$(cat "$PAGE")
assert_equals 3 "$(grep -c 'data-lavish-question=' "$PAGE")" "one form per captain decision (blocker and duplicate left out)"
assert_contains "$HTML" 'data-lavish-question="alpha"' "alpha card"
assert_contains "$HTML" 'data-lavish-question="beta"' "beta card"
assert_contains "$HTML" 'data-lavish-question="delta"' "delta card"
assert_not_contains "$HTML" 'data-lavish-question="gamma"' "a worker blocker is not a captain card"
assert_not_contains "$HTML" "duplicada" "the second row for a key is dropped"
assert_contains "$HTML" 'window.lavish.queuePrompt' "answers go through queuePrompt"
assert_contains "$HTML" 'lang="pt-BR"' "the page is pt-BR"
assert_contains "$HTML" "3 decisões aguardam resposta" "the count line is pt-BR"
assert_contains "$HTML" "Publicar o relatório &lt;semanal&gt;?" "the title is HTML-escaped"
assert_not_contains "$HTML" "[rec=" "the rec token is stripped from the shown text"
pass "daily-page: one pt-BR card per open captain decision, escaped, in the board markup"

# The preselected option is the recorded recommendation, and only then.
alpha=$(sed -n '/data-lavish-question="alpha"/,/<\/form>/p' "$PAGE")
beta=$(sed -n '/data-lavish-question="beta"/,/<\/form>/p' "$PAGE")
delta=$(sed -n '/data-lavish-question="delta"/,/<\/form>/p' "$PAGE")
assert_contains "$alpha" 'value="defer" checked' "alpha preselects the token's recommendation"
assert_not_contains "$alpha" 'value="approve" checked' "alpha does not preselect another option"
assert_contains "$beta" 'value="claude" checked' "beta preselects the recorded recommend value"
assert_contains "$beta" 'value="pi"' "beta offers its own options"
assert_not_contains "$beta" 'value="approve"' "beta does not offer the default options"
assert_not_contains "$delta" ' checked' "a recommendation naming no option preselects nothing"
assert_contains "$delta" 'value="approve"' "delta falls back to the default options"
pass "daily-page: the recommended option is preselected only when recorded"

# Same date: same file, same URL, one session, no rewrite of an unchanged page.
touch -d '2020-01-01' "$PAGE"
OUT2=$(run_page w1); CODE=$?
expect_code 0 "$CODE" "a rerun succeeds"
assert_equals "$OUT" "$OUT2" "the rerun prints the same page and URL"
assert_equals 1 "$(grep -c '^open ' "$LAVISH_LOG")" "lavish-axi opened the file only once"
assert_equals "2020-01-01" "$(date -r "$PAGE" +%F)" "an unchanged page is not rewritten"
write_decisions '{"decisions_open":[{"id":"alpha","key":"alpha","verb":"captain-hold","summary":"Outro texto","owner":"(main)"}]}'
OUT3=$(run_page w1); CODE=$?
expect_code 0 "$CODE" "a refresh succeeds"
assert_equals "$URL" "$(printf '%s\n' "$OUT3" | sed -n 's/^url: //p')" "the refresh keeps the URL"
assert_contains "$(cat "$PAGE")" "Outro texto" "the refresh rewrites the same file with the new decisions"
assert_contains "$(cat "$PAGE")" "1 decisão aguarda resposta" "the singular count line"
assert_equals 1 "$(grep -c '^open ' "$LAVISH_LOG")" "the refresh opened no second session"
pass "daily-page: the same date gives the same file and URL and reuses its session"

# Another date is another file and another session.
OUT4=$(run_page w1 FM_DAILY_PAGE_DATE=2026-10-30); CODE=$?
expect_code 0 "$CODE" "the next day builds"
assert_present "$TMP_ROOT/w1/.lavish/diaria-2026-10-30.html" "the next day has its own file"
assert_not_equals "$URL" "$(printf '%s\n' "$OUT4" | sed -n 's/^url: //p')" "the next day has its own URL"
pass "daily-page: a new date gets a new file and session"

# An ended session is reported and never reopened.
sed -i 's/,open,/,user-ended,/' "$SESSIONS"
before=$(grep -c '^open ' "$LAVISH_LOG")
run_page w1 >/dev/null; CODE=$?
expect_code 0 "$CODE" "an ended session still prints the URL"
assert_equals "$before" "$(grep -c '^open ' "$LAVISH_LOG")" "an ended session is not reopened"
assert_contains "$(cat "$TMP_ROOT/err")" "user-ended" "the ended session is named on stderr"
pass "daily-page: an ended session is never reopened"

# No open decisions still builds a page.
: > "$SESSIONS"
write_decisions '{"decisions_open":[]}'
run_page w2 >/dev/null; CODE=$?
expect_code 0 "$CODE" "an empty list builds"
assert_contains "$(cat "$TMP_ROOT/w2/.lavish/diaria-2026-10-29.html")" "Nenhuma decisão aberta" "the empty page says so"
assert_equals 0 "$(grep -c 'data-lavish-question=' "$TMP_ROOT/w2/.lavish/diaria-2026-10-29.html")" "the empty page has no cards"
pass "daily-page: no open decisions still builds a page"

# A bare array from the reader is accepted.
write_decisions '[{"key":"solo","verb":"captain-hold","summary":"Só um"}]'
run_page w3 >/dev/null; CODE=$?
expect_code 0 "$CODE" "a bare array builds"
assert_contains "$(cat "$TMP_ROOT/w3/.lavish/diaria-2026-10-29.html")" 'data-lavish-question="solo"' "the bare array row becomes a card"

# A failing reader or a bad date changes nothing and exits 1.
cp "$TMP_ROOT/w3/.lavish/diaria-2026-10-29.html" "$TMP_ROOT/before.html"
run_page w3 FM_DAILY_PAGE_READER=false >/dev/null; CODE=$?
expect_code 1 "$CODE" "a failing reader exits 1"
assert_equals "$(cat "$TMP_ROOT/before.html")" "$(cat "$TMP_ROOT/w3/.lavish/diaria-2026-10-29.html")" "a failing reader leaves the page alone"
run_page w3 FM_DAILY_PAGE_DATE=hoje >/dev/null; CODE=$?
expect_code 1 "$CODE" "a malformed date exits 1"
pass "daily-page: a failing reader or bad date exits 1 and leaves the page alone"

# --- ghost holds closed by fact, resilience cards, and the daily rebuild limit -----------------------
HOLD_LOG="$TMP_ROOT/hold.log"; : > "$HOLD_LOG"
cat > "$TMP_ROOT/hold-cmd" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$HOLD_LOG'
[ "\$2" = g-fails ] && exit 1
f=
while [ \$# -gt 0 ]; do [ "\$1" = --decision-file ] && f=\$2; shift; done
cat "\$f" >> '$HOLD_LOG'
exit 0
SH
cat > "$TMP_ROOT/pr-cmd" <<'SH'
#!/usr/bin/env bash
case "$1" in
  */pull/1|*/pull/5|*/pull/6|*/pull/7) echo merged; exit 0 ;;
  */pull/3) echo closed; exit 1 ;;
  */pull/2) echo open; exit 1 ;;
  *) echo unknown; exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/hold-cmd" "$TMP_ROOT/pr-cmd"
write_decisions '{"decisions_open":[
 {"id":"g-merged","key":"g-merged","verb":"captain-hold","summary":"Land PR https://github.com/o/r/pull/1 into main?","owner":"(main)"},
 {"id":"g-open","key":"g-open","verb":"captain-hold","summary":"Land PR https://github.com/o/r/pull/2 into main?","owner":"(main)"},
 {"id":"g-review","key":"g-review","verb":"captain-hold","summary":"Revisão da PR https://github.com/o/r/pull/3","owner":"(main)"},
 {"id":"m1/g-other","key":"g-other","verb":"captain-hold","summary":"Merge PR https://github.com/o/r/pull/5?","owner":"m1"},
 {"id":"g-status","key":"g-status","verb":"needs-decision","summary":"Land PR https://github.com/o/r/pull/6?","owner":"(main)"},
 {"id":"g-fails","key":"g-fails","verb":"captain-hold","summary":"Merge PR https://github.com/o/r/pull/7?","owner":"(main)"},
 {"id":"g-nourl","key":"g-nourl","verb":"captain-hold","summary":"Merge the branch?","owner":"(main)"}
]}'
mkdir -p "$TMP_ROOT/g1/state/resil/cards"
printf 'key=spawn-w9\nowner=(main)\nat=1\nsummary=A criação do worker w9 falhou\n' > "$TMP_ROOT/g1/state/resil/cards/spawn-w9.card"
GOUT=$(run_page g1 FM_DAILY_PAGE_PR_CMD="$TMP_ROOT/pr-cmd" FM_DAILY_PAGE_HOLD_CMD="$TMP_ROOT/hold-cmd"); CODE=$?
expect_code 0 "$CODE" "a run with ghost holds succeeds: $(cat "$TMP_ROOT/err")"
GPAGE="$TMP_ROOT/g1/.lavish/diaria-2026-10-29.html"
assert_contains "$(cat "$HOLD_LOG")" "answer g-merged --decision-file" "the merged ghost was released through the hold script"
assert_contains "$(cat "$HOLD_LOG")" "--release" "the ghost is released, not completed"
assert_contains "$(cat "$HOLD_LOG")" "closed by fact: PR https://github.com/o/r/pull/1 is merged" "the decision text names the PR and its state"
assert_not_contains "$(cat "$HOLD_LOG")" "g-open" "an open PR's hold was touched"
assert_not_contains "$(cat "$HOLD_LOG")" "g-review" "a hold that does not ask for a merge was closed"
assert_not_contains "$(cat "$HOLD_LOG")" "g-other" "another home's hold was closed from here"
assert_not_contains "$(cat "$HOLD_LOG")" "g-status" "a status decision was closed as a hold"
assert_not_contains "$(cat "$HOLD_LOG")" "g-nourl" "a hold naming no PR was closed"
assert_not_contains "$(cat "$GPAGE")" 'data-lavish-question="g-merged"' "the closed ghost is still on the page"
for kept in g-open g-review g-other g-status g-fails g-nourl; do
  assert_contains "$(cat "$GPAGE")" "data-lavish-question=\"$kept\"" "$kept must stay on the page"
done
maybe=$(grep -c 'talvez já resolvida' "$GPAGE")
assert_equals 3 "$maybe" "review, another home's hold and a hold that failed to close are marked as perhaps resolved"
assert_not_contains "$(sed -n '/data-lavish-question="g-open"/,/<\/form>/p' "$GPAGE")" "talvez" "an open PR is not marked"
assert_contains "$(cat "$GPAGE")" "Fechadas por fato" "the footer lists what was closed by fact"
assert_contains "$(cat "$GPAGE")" "g-merged - PR https://github.com/o/r/pull/1 (merged)" "the footer names the closed hold"
assert_contains "$(cat "$TMP_ROOT/g1/state/.resil.log")" "task=g-merged cause=ghost-hold action=close-by-fact" "the close was logged"
# the card
card=$(sed -n '/data-lavish-question="spawn-w9"/,/<\/form>/p' "$GPAGE")
assert_contains "$card" 'value="retry" checked' "a card recommends trying again"
assert_contains "$card" 'value="drop"' "a card offers to give up"
assert_contains "$(cat "$GPAGE")" "A criação do worker w9 falhou" "the card text is on the page"
# the footer outlives the run that closed the hold
write_decisions '{"decisions_open":[]}'
run_page g1 FM_DAILY_PAGE_PR_CMD="$TMP_ROOT/pr-cmd" FM_DAILY_PAGE_HOLD_CMD="$TMP_ROOT/hold-cmd" >/dev/null
assert_contains "$(cat "$GPAGE")" "g-merged - PR https://github.com/o/r/pull/1 (merged)" "a later run forgot what was closed today"
pass "daily-page: ghost holds are closed by fact and listed; doubtful ones are marked; cards get their own options"

# Rebuilt at most twice a day unless forced.
write_decisions '{"decisions_open":[{"id":"r1","key":"r1","verb":"captain-hold","summary":"primeira","owner":"(main)"}]}'
run_page lim FM_DAILY_PAGE_MAX_RUNS=2 >/dev/null
write_decisions '{"decisions_open":[{"id":"r1","key":"r1","verb":"captain-hold","summary":"segunda","owner":"(main)"}]}'
run_page lim FM_DAILY_PAGE_MAX_RUNS=2 >/dev/null
assert_contains "$(cat "$TMP_ROOT/lim/.lavish/diaria-2026-10-29.html")" "segunda" "the second run did not rebuild"
write_decisions '{"decisions_open":[{"id":"r1","key":"r1","verb":"captain-hold","summary":"terceira","owner":"(main)"}]}'
LOUT=$(run_page lim FM_DAILY_PAGE_MAX_RUNS=2); CODE=$?
expect_code 0 "$CODE" "a run past the limit still prints the page"
assert_contains "$LOUT" "url: http://100.96.168.50:4387/session/" "a run past the limit still prints the url"
assert_not_contains "$(cat "$TMP_ROOT/lim/.lavish/diaria-2026-10-29.html")" "terceira" "a third run rebuilt the page"
assert_contains "$(cat "$TMP_ROOT/err")" "already rebuilt 2 times today" "the limit is announced on stderr"
run_page lim FM_DAILY_PAGE_MAX_RUNS=2 FM_DAILY_PAGE_FORCE=1 >/dev/null
assert_contains "$(cat "$TMP_ROOT/lim/.lavish/diaria-2026-10-29.html")" "terceira" "FM_DAILY_PAGE_FORCE=1 did not rebuild"
pass "daily-page: the page is rebuilt at most twice a day unless forced"

printf '# all fm-daily-page tests passed\n'
