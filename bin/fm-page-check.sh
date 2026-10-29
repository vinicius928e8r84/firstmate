#!/usr/bin/env bash
# fm-page-check.sh - check a Lavish HTML decision page before it is shown to the captain.
# Usage: bin/fm-page-check.sh <page.html>
# Prints one PASS/FAIL line per check, then a one-line verdict.
# Exit 0 = every check passed, 1 = at least one FAIL, 2 = usage error or unreadable file.
# Works offline: reads the file only (python3 standard library), never fetches a URL.
#
# Checks:
#   parses      tags balance (html, body, form, div, label, a, button, ...) and the body has visible text
#   lang        <html lang="pt-BR">
#   forms       every data-lavish-question form has a markable input, a submit control, and a
#               queuePrompt call (in its onsubmit or in an inline script); a page with no such form passes as an info page
#   recommended in each form, an option marked recommended (class rec/recommended, data-recommended, or a
#               "Recomendado"/"Recommended" label) is preselected with `checked`
#   links       every local href/src (relative or file:) points at an existing file, and every #fragment at an id on the page;
#               http(s), mailto, tel, data, javascript and root-absolute URLs are not checked (no network)
set -uo pipefail

if [ "$#" -ne 1 ] || [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  sed -n '2,5p' "$0" >&2
  exit 2
fi
if [ ! -f "$1" ] || [ ! -r "$1" ]; then
  echo "error: cannot read page: $1" >&2
  exit 2
fi

exec python3 -I - "$1" <<'PY'
import os, re, sys
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit

path = sys.argv[1]
raw = open(path, "rb").read().decode("utf-8", errors="replace")

TRACKED = {"html", "head", "body", "form", "div", "label", "a", "button", "span", "table",
           "ul", "ol", "section", "select", "textarea", "script", "style", "p"}
OPTIONAL_END = {"p"}  # may legally be closed implicitly


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []          # tracked open tags
        self.problems = []
        self.lang = None
        self.have_html = False
        self.text = []
        self.in_script = None
        self.in_body = False
        self.ids = set()
        self.links = []          # (attr, value)
        self.scripts = []        # inline script bodies
        self.forms = []          # dicts
        self.form = None
        self.labels = []         # open label records
        self.skip_text = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "html":
            self.have_html = True
            self.lang = a.get("lang")
        if tag == "body":
            self.in_body = True
        if "id" in a and a["id"]:
            self.ids.add(a["id"])
        for k in ("href", "src"):
            if a.get(k):
                self.links.append((k, a[k], tag))
        if tag in ("script", "style"):
            self.skip_text += 1
        if tag == "script":
            self.in_script = []
        if tag in TRACKED:
            self.stack.append(tag)
        if tag == "form" and "data-lavish-question" in a:
            self.form = {"name": a["data-lavish-question"], "onsubmit": a.get("onsubmit", ""),
                         "inputs": 0, "submit": 0, "rec": {}, "groups": set()}
            self.forms.append(self.form)
        f = self.form
        if f is not None:
            if tag == "label":
                self.labels.append({"classes": (a.get("class") or "").lower().split(),
                                    "text": [], "radios": []})
            if tag in ("input", "select", "textarea"):
                typ = (a.get("type") or "text").lower()
                if tag == "input" and typ in ("submit", "image"):
                    f["submit"] += 1
                elif tag == "input" and typ in ("hidden", "button", "reset"):
                    pass
                else:
                    f["inputs"] += 1
                if tag == "input" and typ in ("radio", "checkbox") and a.get("name"):
                    f["groups"].add(a["name"])
                    rec = {"name": a["name"], "value": a.get("value", ""), "checked": "checked" in a}
                    marked = "data-recommended" in a or bool(
                        {"rec", "recommended", "recomendado"} & set((a.get("class") or "").lower().split()))
                    if marked:
                        f["rec"].setdefault(a["name"], []).append(rec)
                    for lb in self.labels:
                        lb["radios"].append((rec, marked))
            if tag == "button" and (a.get("type") or "submit").lower() == "submit":
                f["submit"] += 1

    def handle_startendtag(self, tag, attrs):
        # self-closing form of a void/any tag: process attributes, keep stack untouched
        n = len(self.stack)
        self.handle_starttag(tag, attrs)
        if tag in ("script", "style"):
            self.skip_text -= 1
            self.in_script = None
        del self.stack[n:]

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip_text = max(0, self.skip_text - 1)
        if tag == "script" and self.in_script is not None:
            self.scripts.append("".join(self.in_script))
            self.in_script = None
        if tag == "label" and self.labels:
            lb = self.labels.pop()
            text = "".join(lb["text"]).lower()
            by_class = bool({"rec", "recommended", "recomendado"} & set(lb["classes"]))
            by_text = "recomendad" in text or "recommended" in text
            if (by_class or by_text) and self.form is not None:
                for rec, marked in lb["radios"]:
                    if not marked:
                        self.form["rec"].setdefault(rec["name"], []).append(rec)
        if tag == "form":
            self.form = None
            self.labels = []
        if tag in TRACKED:
            if tag in self.stack:
                while self.stack and self.stack[-1] != tag:
                    top = self.stack.pop()
                    if top not in OPTIONAL_END:
                        self.problems.append("<%s> not closed before </%s>" % (top, tag))
                self.stack.pop()
            elif tag not in OPTIONAL_END:
                self.problems.append("stray </%s>" % tag)

    def handle_data(self, data):
        if self.in_script is not None:
            self.in_script.append(data)
        if not self.skip_text:
            if self.in_body:
                self.text.append(data)
            for lb in self.labels:
                lb["text"].append(data)


p = Page()
try:
    p.feed(raw)
    p.close()
except Exception as e:  # noqa: BLE001 - any parser failure is the finding
    p.problems.append("parser error: %s" % e)
for tag in p.stack:
    if tag not in OPTIONAL_END:
        p.problems.append("<%s> never closed" % tag)

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))


# parses
visible = "".join(p.text).strip()
bad = list(p.problems)
if not p.have_html:
    bad.append("no <html> element")
if not visible:
    bad.append("body has no visible text (blank page)")
check("parses", not bad, "; ".join(bad[:3]) if bad else "tags balance, body has text")

# lang
lang = (p.lang or "").strip()
check("lang", lang.lower() == "pt-br", "html lang=%r, want 'pt-BR'" % lang if lang.lower() != "pt-br" else "pt-BR")

# forms
if not p.forms:
    check("forms", True, "no data-lavish-question form (info page)")
else:
    scripts_have_queue = any("queuePrompt" in s for s in p.scripts)
    for f in p.forms:
        miss = []
        if f["inputs"] == 0:
            miss.append("no markable input")
        if f["submit"] == 0:
            miss.append("no submit control")
        if "queuePrompt" not in f["onsubmit"] and not scripts_have_queue:
            miss.append("no queuePrompt call")
        check("form %s" % f["name"], not miss, ", ".join(miss) if miss else "input, submit, queuePrompt")

# recommended preselected
rec_seen = 0
for f in p.forms:
    for name, recs in f["rec"].items():
        rec_seen += 1
        unchecked = [r["value"] or "?" for r in recs if not r["checked"]]
        check("recommended %s/%s" % (f["name"], name), not unchecked,
              "recommended option %s is not preselected (add checked)" % ", ".join(unchecked)
              if unchecked else "preselected")
if p.forms and not rec_seen:
    check("recommended", False, "no option is marked recommended (class rec, data-recommended, or a Recomendado label)")

# links
base = os.path.dirname(os.path.abspath(path))
broken = []
checked_links = 0
for attr, val, tag in p.links:
    val = val.strip()
    if not val or val.startswith("//") or val.startswith("/"):
        continue
    if val.startswith("#"):
        checked_links += 1
        frag = unquote(val[1:])
        if frag and frag not in p.ids and frag != "top":
            broken.append("%s=%s (no such id)" % (attr, val))
        continue
    u = urlsplit(val)
    if u.scheme and u.scheme != "file":
        continue
    target = unquote(u.path)
    if not target:
        continue
    checked_links += 1
    full = target if u.scheme == "file" else os.path.join(base, target)
    if not os.path.exists(full):
        broken.append("%s=%s (missing file)" % (attr, val))
check("links", not broken,
      "; ".join(broken[:5]) + (" ..." if len(broken) > 5 else "") if broken
      else "%d local link(s) ok" % checked_links)

fails = 0
for name, ok, detail in results:
    print("%s %s: %s" % ("PASS" if ok else "FAIL", name, detail))
    fails += 0 if ok else 1
print("%s: %d check(s), %d failed" % ("PAGE OK" if not fails else "PAGE BROKEN", len(results), fails))
sys.exit(1 if fails else 0)
PY
