#!/usr/bin/env bash
# Tests for bin/fm-page-check.sh: a Lavish decision page is validated offline before the captain sees it.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); C=$ROOT/bin/fm-page-check.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2' want '$3')"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok   $1" ;; *) echo "FAIL $1 (missing '$2' in: $3)"; fail=1 ;; esac; }

# page <file> <lang> <form-attrs> <option-b-checked> <extra-body>: a two-option decision page
page() {
  cat > "$1" <<HTML
<!doctype html>
<html lang="$2"><head><meta charset="utf-8"><title>Decisoes</title></head><body>
<h1>Decisoes pendentes</h1>
<form data-lavish-question="d1" $3>
<label class="opt rec"><input type="radio" name="q1" value="A" $4> <span class="tag">Recomendado</span> A - Fechar</label>
<label class="opt"><input type="radio" name="q1" value="B"> B - Manter</label>
${5:-}
</form>
${6:-}
</body></html>
HTML
}
OK_FORM='onsubmit="event.preventDefault(); window.lavish.queuePrompt(\"x\")"'
SUBMIT='<button type="submit">Enviar</button>'

page "$T/good.html" pt-BR "$OK_FORM" checked "$SUBMIT" '<a href="doc.txt">doc</a> <a href="#fim">fim</a> <a href="https://example.com/x">net</a><p id="fim">fim'
echo hello > "$T/doc.txt"
out=$("$C" "$T/good.html"); rc=$?
check good-exit "$rc" 0
has good-verdict "PAGE OK" "$out"
has good-recommended "PASS recommended d1/q1" "$out"

# the three failures of 26/10: blank page, nothing markable, nobody listening (no queuePrompt)
printf '<!doctype html><html lang="pt-BR"><body></body></html>\n' > "$T/black.html"
out=$("$C" "$T/black.html"); rc=$?
check black-exit "$rc" 1
has black-reason "blank page" "$out"

page "$T/nosubmit.html" pt-BR "$OK_FORM" checked ""
out=$("$C" "$T/nosubmit.html"); rc=$?
check nosubmit-exit "$rc" 1
has nosubmit-reason "no submit control" "$out"

printf '<!doctype html><html lang="pt-BR"><body><h1>x</h1><form data-lavish-question="d1">%s</form></body></html>\n' "$SUBMIT" > "$T/noinput.html"
out=$("$C" "$T/noinput.html"); rc=$?
check noinput-exit "$rc" 1
has noinput-reason "no markable input" "$out"

page "$T/noqueue.html" pt-BR "" checked "$SUBMIT"
out=$("$C" "$T/noqueue.html"); rc=$?
check noqueue-exit "$rc" 1
has noqueue-reason "no queuePrompt call" "$out"

# queuePrompt in an inline script is as good as one in onsubmit
page "$T/script.html" pt-BR "" checked "$SUBMIT" '<script>window.lavish.queuePrompt("y")</script>'
check script-queue "$("$C" "$T/script.html" >/dev/null; echo $?)" 0

page "$T/unchecked.html" pt-BR "$OK_FORM" "" "$SUBMIT"
out=$("$C" "$T/unchecked.html"); rc=$?
check unchecked-exit "$rc" 1
has unchecked-reason "not preselected" "$out"

page "$T/lang.html" en "$OK_FORM" checked "$SUBMIT"
out=$("$C" "$T/lang.html"); rc=$?
check lang-exit "$rc" 1
has lang-reason "FAIL lang" "$out"

page "$T/link.html" pt-BR "$OK_FORM" checked "$SUBMIT" '<a href="gone.html">x</a><img src="img/none.png"><a href="#nowhere">y</a>'
out=$("$C" "$T/link.html"); rc=$?
check link-exit "$rc" 1
has link-file "href=gone.html (missing file)" "$out"
has link-img "src=img/none.png (missing file)" "$out"
has link-anchor "href=#nowhere (no such id)" "$out"

page "$T/unbalanced.html" pt-BR "$OK_FORM" checked "$SUBMIT" '<div><span>oops</div>'
out=$("$C" "$T/unbalanced.html"); rc=$?
check unbalanced-exit "$rc" 1
has unbalanced-reason "FAIL parses" "$out"

"$C" "$T/missing.html" >/dev/null 2>&1; check missing-file-exit "$?" 2
"$C" >/dev/null 2>&1; check usage-exit "$?" 2
exit "$fail"
