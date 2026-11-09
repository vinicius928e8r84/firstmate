#!/usr/bin/env bash
# Behavior tests for bin/fm-decision-page.sh (decision page from model-written text, and applying captured answers).
#
# Runs the real fm-daily-page.sh and fm-page-check.sh with a stub lavish-axi and stub adapter, hold and
# process-event scripts. Pins:
#   1. build turns a TSV into one card per decision with the recommended option preselected, the model's own
#      options and context, the page check passing, and the source bound then armed;
#   2. bad input (non-slug key, unknown recommendation, duplicate key, empty file) is refused before any page exists;
#   3. a key that is not an open hold only warns;
#   4. apply feeds each unhandled captured result to the intake in order, marks it handled, skips handled ones,
#      and leaves a result the intake refuses unhandled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-decision-page.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-page)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SESSIONS="$TMP_ROOT/sessions"; : > "$SESSIONS"
CALLS="$TMP_ROOT/calls.log"; : > "$CALLS"
HOME_DIR="$TMP_ROOT/home"; mkdir -p "$HOME_DIR"

cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ $# -eq 0 ]; then printf 'sessions[1]{file,status,url,pending_prompts,listener}:\n'; sed 's/^/  /' "${SESSIONS:?}"; exit 0; fi
grep -q "^$1," "$SESSIONS" || printf '%s,open,"http://127.0.0.1:4387/session/s%s",0,none\n' "$1" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)" >> "$SESSIONS"
SH
cat > "$TMP_ROOT/adapter.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  source-id) printf 'lavish-%s\n' "$(basename "$2" .html)" ;;
  arm) printf 'arm %s\n' "$(basename "$2")" >> "${CALLS:?}" ;;
  answers) cat "$2" ;;
esac
SH
cat > "$TMP_ROOT/hold.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  open) [ "$2" != ghost ] ;;
  bind) printf 'bind %s\n' "$2" >> "${CALLS:?}" ;;
  binding) echo '(any)' ;;
  answers)
    shift; printf 'answers %s\n' "$*" >> "${CALLS:?}"
    in=$(cat); printf 'fed %s\n' "$in" >> "${CALLS:?}"
    case "$in" in *refused*) exit 1 ;; esac ;;
esac
SH
cat > "$TMP_ROOT/procevent.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = handled ] && { printf 'handled %s %s\n' "$2" "$3" >> "${CALLS:?}"; touch "${INBOX:?}/$2.$3.handled"; }
SH
chmod +x "$FAKEBIN/lavish-axi" "$TMP_ROOT"/*.sh

run() {  # <args...>
  env HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" SESSIONS="$SESSIONS" CALLS="$CALLS" INBOX="$TMP_ROOT/h/state/procevent-inbox" \
    FM_HOME="$TMP_ROOT/h" FM_DAILY_PAGE_DATE=2026-11-09 FM_SW_NO_NOTIFY=1 \
    FM_DECISION_PAGE_ADAPTER="$TMP_ROOT/adapter.sh" FM_DECISION_PAGE_HOLD_CMD="$TMP_ROOT/hold.sh" \
    FM_DECISION_PAGE_PROCEVENT="$TMP_ROOT/procevent.sh" FM_DAILY_PAGE_ADAPTER="$TMP_ROOT/adapter.sh" \
    FM_DAILY_PAGE_HOLD_CMD="$TMP_ROOT/hold.sh" bash "$TOOL" "$@" 2>"$TMP_ROOT/err"
}

TAB=$'\t'
TSV="$TMP_ROOT/dia.tsv"
{
  printf 'key\ttitle\tcontext\trecommend\toptions\n'
  printf '# comment\n\n'
  printf 'ligar-preaway%sLigar a lista antes de sair?%sSó avisa, nunca segura a saída%sligar%sligar=Ligar=Aviso na entrada|manter=Manter desligada\n' "$TAB" "$TAB" "$TAB" "$TAB"
  printf 'limpeza-host%sRodar a limpeza a cada 3 h?%s%sapprove%s\n' "$TAB" "$TAB" "$TAB" "$TAB"
  printf 'ghost%sQuem é <fantasma>?%s%sdefer%s\n' "$TAB" "$TAB" "$TAB" "$TAB"
} > "$TSV"

OUT=$(run build "$TSV"); CODE=$?; [ "$CODE" = 0 ] || cat "$TMP_ROOT/err" >&2
expect_code 0 "$CODE" "build succeeds"
PAGE="$TMP_ROOT/h/.lavish/decisoes-dia-2026-11-09.html"
assert_present "$PAGE" "the page is named after the file and the date"
assert_contains "$OUT" "armed: lavish-decisoes-dia-2026-11-09" "the page source is armed"
assert_equals 3 "$(grep -c 'data-lavish-question=' "$PAGE")" "one card per decision, header and comment skipped"
one=$(sed -n '/data-lavish-question="ligar-preaway"/,/<\/form>/p' "$PAGE")
two=$(sed -n '/data-lavish-question="limpeza-host"/,/<\/form>/p' "$PAGE")
assert_contains "$one" 'value="ligar" checked' "the model's recommendation is preselected"
assert_contains "$one" 'Aviso na entrada' "the option hint shows"
assert_contains "$one" 'value="manter"' "the model's own options are offered"
assert_contains "$(cat "$PAGE")" 'Só avisa, nunca segura a saída' "the context shows"
assert_contains "$two" 'value="approve" checked' "default options accept a recommendation among them"
assert_contains "$(cat "$PAGE")" 'Quem é &lt;fantasma&gt;?' "text is escaped"
assert_contains "$(cat "$CALLS")" "bind lavish-decisoes-dia-2026-11-09" "the source is bound"
assert_contains "$(cat "$TMP_ROOT/err")" "ghost is not an open captain hold" "an unheld key only warns"
assert_not_contains "$(cat "$TMP_ROOT/err")" "limpeza-host is not" "an open hold does not warn"
bash "$ROOT/bin/fm-page-check.sh" "$PAGE" >/dev/null; expect_code 0 "$?" "the built page passes the page check"
pass "decision-page build: a TSV becomes the standard page, checked, bound and armed"

# Refused input never creates a page.
rm -rf "$TMP_ROOT/h/.lavish"
try_bad() {  # <label> <line> <want-text>
  printf '%b\n' "$2" > "$TMP_ROOT/bad.tsv"
  run build "$TMP_ROOT/bad.tsv" >/dev/null; CODE=$?
  expect_code 1 "$CODE" "$1 is refused"
  assert_contains "$(cat "$TMP_ROOT/err")" "$3" "$1 names the problem"
  assert_absent "$TMP_ROOT/h/.lavish" "$1 leaves no page"
}
try_bad "a key that is not a slug" 'Bad Key\tT\t\t\t' "key must be a slug"
try_bad "a recommendation outside the options" 'k1\tT\t\tzzz\ta=A|b=B' "not one of its options"
try_bad "an option value that is not a slug" 'k1\tT\t\ta\ta b=A' "not a slug"
try_bad "a duplicate key" 'k1\tT\t\tapprove\t\nk1\tU\t\tapprove\t' "appears twice"
try_bad "a card without a title" 'k1\t\t\t\t' "has no title"
: > "$TMP_ROOT/bad.tsv"
run build "$TMP_ROOT/bad.tsv" >/dev/null; expect_code 1 "$?" "an empty file is refused"
run build "$TMP_ROOT/missing.tsv" >/dev/null; expect_code 1 "$?" "a missing file is refused"
run >/dev/null; expect_code 2 "$?" "no subcommand is a usage error"
pass "decision-page build: invalid input is refused before any page is written"

# A page that fails the check is not published.
printf '#!/usr/bin/env bash\necho "FAIL forms: broken"; exit 1\n' > "$TMP_ROOT/badcheck.sh"; chmod +x "$TMP_ROOT/badcheck.sh"
run build "$TSV" --name falha >/dev/null 2>&1; : # baseline builds
rm -f "$TMP_ROOT/h/.lavish/novo.html"
FM_DECISION_PAGE_CHECK="$TMP_ROOT/badcheck.sh" run build "$TSV" --name novo >/dev/null; CODE=$?
expect_code 1 "$CODE" "a failing page check exits 1"
assert_absent "$TMP_ROOT/h/.lavish/novo.html" "a page that fails the check is not written"
assert_contains "$(cat "$TMP_ROOT/err")" "page check failed" "the check failure is named"
pass "decision-page build: a page that fails fm-page-check is not published"

# apply
INBOX="$TMP_ROOT/h/state/procevent-inbox"; mkdir -p "$INBOX"
SID=lavish-decisoes-dia-2026-11-09
printf 'ligar-preaway\tligar\tLigar\n' > "$INBOX/$SID.1.result"
printf 'limpeza-host\tapprove\tAprovar\n' > "$INBOX/$SID.2.result"
printf 'ghost\trefused\tx\n' > "$INBOX/$SID.3.result"
printf 'old\tapprove\tx\n' > "$INBOX/$SID.10.result"; touch "$INBOX/$SID.10.handled"
printf 'other\tapprove\tx\n' > "$INBOX/lavish-other.1.result"
: > "$CALLS"
OUT=$(run apply "$PAGE"); CODE=$?
expect_code 1 "$CODE" "apply exits 1 while one result is refused"
assert_contains "$OUT" "applied: $SID 1" "result 1 is applied"
assert_contains "$OUT" "applied: $SID 2" "result 2 is applied"
assert_contains "$OUT" "kept: $SID 3" "the refused result is kept"
assert_contains "$(cat "$CALLS")" "answers --any-origin --source the captured result $SID sequence 1" "the intake gets the unbound scope and provenance"
assert_contains "$(cat "$CALLS")" "fed ligar-preaway${TAB}ligar${TAB}Ligar" "the adapter's keyed line reaches the intake"
assert_not_contains "$(cat "$CALLS")" "handled $SID 10" "an already handled result is skipped"
assert_not_contains "$(cat "$CALLS")" "lavish-other" "another source is untouched"
assert_present "$INBOX/$SID.1.handled" "result 1 is marked handled"
assert_absent "$INBOX/$SID.3.handled" "the refused result stays unhandled"
first=$(grep -n "handled $SID 1" "$CALLS" | cut -d: -f1); second=$(grep -n "handled $SID 2" "$CALLS" | cut -d: -f1)
[ "$first" -lt "$second" ] || fail "results were not applied in order"
: > "$CALLS"
run apply "$SID" >/dev/null; expect_code 1 "$?" "a second apply by source id still reports the refused one"
assert_not_contains "$(cat "$CALLS")" "handled $SID 1" "a handled result is not applied twice"
pass "decision-page apply: captured answers reach the intake once and are marked handled"

printf '# all fm-decision-page tests passed\n'
