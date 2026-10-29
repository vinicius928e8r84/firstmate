#!/usr/bin/env bash
# fm-daily-page.sh - build or refresh the day's decision page for the captain.
#
# Usage:
#   fm-daily-page.sh        run on demand (no cron line, no timer)
#
# Writes <home>/.lavish/diaria-YYYY-MM-DD.html from the open captain decisions
# and prints two lines:
#   page: <absolute path of the html file>
#   url:  http://100.96.168.50:4387/session/<id>
# The same date always gives the same file and the same URL: a rerun rewrites
# the file only when its content changed, and opens a lavish-axi session only
# when the server lists none for that file. A session the captain ended is
# listed and is never reopened here; the url line then names it and a note on
# stderr says it ended.
#
# Reader (no new store): bin/fm-bearings-snapshot.sh --json, the structured
# read of the captain-hold backlog and the status decision fold. Its
# decisions_open[] rows ({id,key,verb,summary,owner}) with verb captain-hold or
# needs-decision become one card each, in reader order, one per key. A row may
# also carry `options` ([{value,label,hint}]) and `recommend` (an option
# value); a `[rec=<value>]` token in the summary is read the same way and
# stripped from the shown text. Without options the card offers Aprovar,
# Adiar and Recusar. The recommended option, when it names a real option, is
# preselected and marked "rec".
#
# Each card is the bearings board's decision markup in pt-BR: a form carrying
# data-lavish-question=<key> with a radio group named `answer`, an optional
# free-text `note`, and a submit that calls window.lavish.queuePrompt with the
# selection and note under schema fm-daily-answer.v1.
#
# Environment:
#   FM_HOME                 firstmate home (default: the code root)
#   FM_DAILY_PAGE_DIR       directory for the page (default: $FM_HOME/.lavish)
#   FM_DAILY_PAGE_DATE      YYYY-MM-DD to build (default: today)
#   FM_DAILY_PAGE_READER    shell command printing the reader's JSON (an object
#                           with decisions_open[], or a bare array); default is
#                           the bearings snapshot with FM_BEARINGS_DECISIONS=500
#   FM_DAILY_PAGE_HOST      host:port written into the url (default
#                           100.96.168.50:4387; never localhost)
#
# Exit status: 0 on success; 1 when the reader, the page write, or the lavish
# session fails, leaving any existing page untouched.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DIR="${FM_DAILY_PAGE_DIR:-$FM_HOME/.lavish}"
DAY="${FM_DAILY_PAGE_DATE:-$(date +%F)}"
HOST="${FM_DAILY_PAGE_HOST:-100.96.168.50:4387}"
DEFAULT_READER="FM_BEARINGS_DECISIONS=500 '$SCRIPT_DIR/fm-bearings-snapshot.sh' --json"
READER="${FM_DAILY_PAGE_READER:-$DEFAULT_READER}"

fail() { printf 'fm-daily-page: %s\n' "$*" >&2; exit 1; }

case "$DAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) fail "FM_DAILY_PAGE_DATE must be YYYY-MM-DD, got '$DAY'" ;;
esac
command -v jq >/dev/null 2>&1 || fail "jq is not installed"

PAGE="$DIR/diaria-$DAY.html"

# --- read the open decisions -------------------------------------------------
raw=$(bash -c "$READER") || fail "the decision reader failed"
decisions=$(printf '%s' "$raw" | jq -c '
  (if type == "array" then . else (.decisions_open // []) end)
  | [ .[] | select((.verb // "") == "captain-hold" or (.verb // "") == "needs-decision")
          | select((.key // .id // "") != "") ]
  | reduce .[] as $d ([]; if any(.[]; (.key // .id) == ($d.key // $d.id)) then . else . + [$d] end)
') || fail "the decision reader did not print the expected JSON"

# --- render the cards ----------------------------------------------------------
cards=$(printf '%s' "$decisions" | jq -r '
  def default_options: [
    {value:"approve", label:"Aprovar", hint:"Seguir com o que foi proposto"},
    {value:"defer",   label:"Adiar",   hint:"Voltar a esta decisão mais tarde"},
    {value:"decline", label:"Recusar", hint:"Não seguir com isto"}];
  def summary_text: (.summary // .key // .id) | gsub("\\s*\\[rec=[A-Za-z0-9_.-]+\\]"; "");
  def rec_value:
    (.recommend // ((.summary // "") | capture("\\[rec=(?<v>[A-Za-z0-9_.-]+)\\]").v) // "");
  .[] | (.key // .id) as $key
      | (if ((.options // []) | length) > 0 then .options else default_options end) as $opts
      | (rec_value) as $rec
      | (if any($opts[]; .value == $rec) then $rec else "" end) as $pick
      | (summary_text) as $title
      | "<article class=\"card\">\n"
      + "  <div class=\"card-top\"><span class=\"badge\">decisão</span><span class=\"owner\">" + ((.owner // "(main)") | @html) + "</span></div>\n"
      + "  <h2>" + ($title | @html) + "</h2>\n"
      + "  <p class=\"key\">" + ($key | @html) + "</p>\n"
      + "  <form data-lavish-question=\"" + ($key | @html) + "\" data-title=\"" + ($title | @html) + "\">\n"
      + "    <div class=\"opts\">\n"
      + ([ $opts[] | "      <label class=\"opt\"><input type=\"radio\" name=\"answer\" value=\"" + (.value | tostring | @html) + "\""
            + (if .value == $pick then " checked" else "" end) + ">"
            + "<span class=\"opt-body\"><span class=\"opt-label\">" + ((.label // .value) | tostring | @html) + "</span>"
            + (if (.hint // "") != "" then "<span class=\"opt-hint\">" + (.hint | @html) + "</span>" else "" end)
            + "</span>"
            + (if .value == $pick then "<span class=\"rec\">rec</span>" else "" end)
            + "</label>" ] | join("\n")) + "\n"
      + "    </div>\n"
      + "    <input type=\"text\" name=\"note\" class=\"freeform\" placeholder=\"ou responda com suas palavras…\">\n"
      + "    <div class=\"foot\"><button type=\"submit\">Enfileirar resposta</button><span class=\"queued\">✓ enfileirada</span><span class=\"limit\" role=\"alert\"></span></div>\n"
      + "  </form>\n"
      + "</article>"
') || fail "could not render the decision cards"
count=$(printf '%s' "$decisions" | jq 'length')

if [ "$count" -eq 0 ]; then
  cards='<article class="card empty"><p>Nenhuma decisão aberta no momento.</p></article>'
  sub="nada aguardando resposta"
elif [ "$count" -eq 1 ]; then
  sub="1 decisão aguarda resposta"
else
  sub="$count decisões aguardam resposta"
fi

day_br="${DAY:8:2}/${DAY:5:2}/${DAY:0:4}"

html=$(cat <<EOF
<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Decisões do dia - $DAY</title>
<style>
  :root { color-scheme: light dark; --bg:#f6f5f1; --fg:#1d1d1b; --muted:#6b6a64; --card:#fff; --line:#dcdad2; --accent:#2f5d50; --gold:#b8860b; }
  @media (prefers-color-scheme: dark) { :root { --bg:#16171a; --fg:#ececea; --muted:#9a9a94; --card:#1f2024; --line:#34353b; --accent:#6fb59f; --gold:#d9a93a; } }
  * { box-sizing: border-box; }
  body { margin:0; padding:2rem 1rem; background:var(--bg); color:var(--fg); font:16px/1.5 system-ui, sans-serif; }
  main { max-width:44rem; margin:0 auto; }
  header h1 { margin:0; font-size:1.6rem; }
  header p { margin:.25rem 0 1.5rem; color:var(--muted); }
  .card { background:var(--card); border:1px solid var(--line); border-radius:.75rem; padding:1.25rem; margin-bottom:1rem; min-width:0; }
  .card.empty { text-align:center; color:var(--muted); }
  .card-top { display:flex; gap:.6rem; align-items:center; flex-wrap:wrap; }
  .badge { background:var(--accent); color:#fff; border-radius:999px; padding:.1rem .6rem; font-size:.75rem; text-transform:uppercase; letter-spacing:.04em; }
  .owner { color:var(--muted); font-size:.85rem; overflow-wrap:anywhere; }
  .card h2 { margin:.6rem 0 .2rem; font-size:1.15rem; overflow-wrap:anywhere; }
  .key { margin:0 0 1rem; color:var(--muted); font:.8rem ui-monospace, monospace; overflow-wrap:anywhere; }
  .opts { display:grid; gap:.5rem; }
  .opt { display:flex; gap:.6rem; align-items:flex-start; border:1px solid var(--line); border-radius:.5rem; padding:.6rem .75rem; cursor:pointer; min-width:0; }
  .opt:has(input:checked) { border-color:var(--accent); }
  .opt-body { display:flex; flex-direction:column; flex:1; min-width:0; }
  .opt-label { font-weight:600; overflow-wrap:anywhere; }
  .opt-hint { color:var(--muted); font-size:.85rem; overflow-wrap:anywhere; }
  .rec { color:var(--gold); border:1px solid var(--gold); border-radius:.3rem; padding:0 .35rem; font-size:.7rem; text-transform:uppercase; }
  .freeform { width:100%; margin-top:.75rem; padding:.55rem .7rem; border:1px solid var(--line); border-radius:.5rem; background:transparent; color:inherit; font:inherit; }
  .foot { display:flex; gap:.75rem; align-items:center; margin-top:.9rem; flex-wrap:wrap; }
  button { background:var(--accent); color:#fff; border:0; border-radius:.5rem; padding:.5rem 1rem; font:inherit; cursor:pointer; }
  .queued, .limit { display:none; font-size:.85rem; }
  .queued { color:var(--accent); }
  .limit { color:#b3261e; }
  .card.is-queued .queued, .limit.is-visible { display:inline; }
</style>
</head>
<body>
<main>
  <header>
    <h1>Decisões do dia</h1>
    <p>$day_br · $sub</p>
  </header>
$cards
</main>
<script>
(function () {
  function byteLength(s) { return new TextEncoder().encode(s).length; }
  Array.prototype.forEach.call(document.querySelectorAll("form[data-lavish-question]"), function (form) {
    var card = form.closest(".card");
    var limit = form.querySelector(".limit");
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      limit.classList.remove("is-visible");
      var fd = new FormData(form);
      var value = fd.get("answer");
      var note = (fd.get("note") || "").trim();
      var shown = value ? (note ? value + " - " + note : value) : note;
      if (!shown) return;
      if (byteLength(shown) > 512) {
        limit.textContent = "Resposta longa demais para enfileirar (máximo de 512 bytes).";
        limit.classList.add("is-visible");
        return;
      }
      var title = form.getAttribute("data-title");
      if (window.lavish && window.lavish.queuePrompt) {
        window.lavish.queuePrompt(
          "Resposta à decisão - " + title + ": " + shown,
          { tag: "choice", text: title + " -> " + shown, element: form,
            data: { schema: "fm-daily-answer.v1", question: form.getAttribute("data-lavish-question"),
                    selection: value || "", note: note } }
        );
      }
      card.classList.add("is-queued");
    });
  });
})();
</script>
</body>
</html>
EOF
)

# --- write the page (only when it changed) ---------------------------------------
mkdir -p "$DIR" || fail "cannot create $DIR"
PAGE_REAL="$(cd "$DIR" && pwd -P)/diaria-$DAY.html"
if [ ! -f "$PAGE" ] || [ "$(cat "$PAGE")" != "$html" ]; then
  tmp=$(mktemp "$DIR/.diaria-$DAY.XXXXXX") || fail "cannot write in $DIR"
  if ! printf '%s\n' "$html" > "$tmp" || ! mv -f "$tmp" "$PAGE"; then
    rm -f "$tmp"
    fail "cannot write $PAGE"
  fi
fi

# --- the lavish session: reuse the listed one, open only when none exists ---------
command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"

# Rows of the bare `lavish-axi` listing are `<file>,<status>,"<url>",<pending>,...`.
session_row() {  # prints "<status> <url>" for the page, or nothing
  lavish-axi 2>/dev/null | awk -v path="$PAGE_REAL" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      n = split(rest, f, ",")
      url = ""
      for (i = 2; i <= n; i++) if (f[i] ~ /session\//) { url = f[i]; gsub(/"/, "", url); break }
      print f[1], url; exit
    }'
}

row=$(session_row)
if [ -z "$row" ]; then
  out=$(lavish-axi "$PAGE_REAL" 2>&1) || fail "lavish-axi could not open the page: $out"
  row=$(session_row)
  if [ -z "$row" ]; then
    url_out=$(printf '%s\n' "$out" | grep -o 'session/[A-Za-z0-9]*' | head -1)
    [ -n "$url_out" ] && row="open $url_out"
  fi
fi
[ -n "$row" ] || fail "no lavish session found for $PAGE_REAL"
status=${row%% *}
sid=$(printf '%s\n' "${row#* }" | sed -n 's|.*session/\([A-Za-z0-9]*\).*|\1|p')
[ -n "$sid" ] || fail "no session id for $PAGE_REAL"
[ "$status" = open ] || printf 'fm-daily-page: the session for this page is %s; not reopening it\n' "$status" >&2

printf 'page: %s\n' "$PAGE_REAL"
printf 'url: http://%s/session/%s\n' "$HOST" "$sid"
