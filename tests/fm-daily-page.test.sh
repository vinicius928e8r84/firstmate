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
#   5. the URL carries the tailnet host, never localhost; an empty list still
#      builds a page; a failing reader leaves the page alone and exits 1;
#   6. a live session is bound to the keyed-answer intake and armed through the
#      lavish adapter (stubbed), an ended one is not, and the answer schema is
#      the one that intake reads; FM_DAILY_PAGE_NAME/TITLE make a second page
#      and a decision `context` shows under its title.
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

ARM_LOG="$TMP_ROOT/arm.log"; : > "$ARM_LOG"
cat > "$TMP_ROOT/adapter.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  source-id) printf 'lavish-%s\n' "$(basename "$2" .html)" ;;
  arm) printf 'arm %s\n' "$2" >> "${ARM_LOG:?}"; [ -z "${ARM_FAIL:-}" ] || exit 1; printf 'armed: x\n' ;;
esac
SH
cat > "$TMP_ROOT/hold.sh" <<'SH'
#!/usr/bin/env bash
printf 'hold %s\n' "$*" >> "${ARM_LOG:?}"
SH
chmod +x "$TMP_ROOT/adapter.sh" "$TMP_ROOT/hold.sh"

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
    FM_DAILY_PAGE_READER="$TMP_ROOT/reader.sh" ARM_LOG="$ARM_LOG" \
    FM_DAILY_PAGE_ADAPTER="$TMP_ROOT/adapter.sh" FM_DAILY_PAGE_HOLD_CMD="$TMP_ROOT/hold.sh" "$@" bash "$TOOL" 2>"$TMP_ROOT/err"
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

# Bind and arm: a live session is bound then armed once per run; the answer schema is the intake's.
: > "$SESSIONS"; : > "$ARM_LOG"
write_decisions '{"decisions_open":[{"key":"solo","verb":"captain-hold","summary":"Um","context":"Contexto <b>longo</b>"}]}'
OUT5=$(run_page w4); CODE=$?
expect_code 0 "$CODE" "a run that binds and arms succeeds"
P4="$(cd "$TMP_ROOT/w4/.lavish" && pwd -P)/diaria-2026-10-29.html"
assert_contains "$OUT5" "armed: lavish-diaria-2026-10-29" "the armed source id is printed"
assert_equals "hold bind lavish-diaria-2026-10-29
arm $P4" "$(cat "$ARM_LOG")" "the source is bound before it is armed"
assert_contains "$(cat "$P4")" 'schema: "fm-bearings-answer.v1"' "the answer schema is the keyed intake's"
assert_not_contains "$(cat "$P4")" 'fm-daily-answer' "the old schema is gone"
assert_contains "$(cat "$P4")" '<p class="context">Contexto &lt;b&gt;longo&lt;/b&gt;</p>' "a decision context shows, escaped"
pass "daily-page: a live page is bound to the keyed-answer intake and armed, with a readable schema"

# A named page is a second page with its own title and session.
OUT6=$(run_page w4 FM_DAILY_PAGE_NAME=decisoes-teste FM_DAILY_PAGE_TITLE='Decisões <teste>'); CODE=$?
expect_code 0 "$CODE" "a named page builds"
assert_present "$TMP_ROOT/w4/.lavish/decisoes-teste.html" "the named page has its own file"
assert_contains "$(cat "$TMP_ROOT/w4/.lavish/decisoes-teste.html")" '<h1>Decisões &lt;teste&gt;</h1>' "the title is the given one, escaped"
assert_not_equals "$(printf '%s\n' "$OUT5" | sed -n 's/^url: //p')" "$(printf '%s\n' "$OUT6" | sed -n 's/^url: //p')" "the named page has its own URL"
run_page w4 FM_DAILY_PAGE_NAME='../x' >/dev/null; CODE=$?
expect_code 1 "$CODE" "a path in the page name is refused"
pass "daily-page: a named page is separate, and its name cannot leave the directory"

# An ended session is not armed; an arm failure exits 1 but leaves the page written.
: > "$ARM_LOG"
sed -i 's/,open,/,user-ended,/' "$SESSIONS"
run_page w4 >/dev/null; CODE=$?
expect_code 0 "$CODE" "an ended page still prints"
assert_equals "" "$(cat "$ARM_LOG")" "an ended session is neither bound nor armed"
: > "$SESSIONS"
run_page w5 ARM_FAIL=1 >/dev/null; CODE=$?
expect_code 1 "$CODE" "an arm failure exits 1"
assert_contains "$(cat "$TMP_ROOT/err")" "cannot arm" "the arm failure is named"
pass "daily-page: only a live session is armed, and an arm failure is reported"

printf '# all fm-daily-page tests passed\n'
