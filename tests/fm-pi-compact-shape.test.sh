#!/usr/bin/env bash
# tests/fm-pi-compact-shape.test.sh - the Pi primary's compaction shape
# (.pi/extensions/fm-compact-shape.ts). Each case drives the real extension's
# session_before_compact handler in node with a mock Pi context. The stubbed Pi
# package records what compact() received and answers with a scripted summary;
# the last case, when a real Pi package is installed, runs Pi's own compact() and
# records the summarizer request instead.
# The JavaScript case bodies below are single-quoted on purpose, template literals included.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-compact-shape)
EXT="$ROOT/.pi/extensions/fm-compact-shape.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
export NODE_NO_WARNINGS=1

# Keep JavaScript heredocs outside command substitutions (stock macOS Bash 3.2
# reparses quotes and template literals inside that combination).
install_stub_fixture() {
  local repo=$1
  mkdir -p "$repo/.pi/extensions" "$repo/node_modules/@earendil-works/pi-coding-agent"
  cp "$EXT" "$repo/.pi/extensions/fm-compact-shape.ts"
  printf '%s\n' '{"type":"module"}' >"$repo/package.json"
  printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}' \
    >"$repo/node_modules/@earendil-works/pi-coding-agent/package.json"
  cat >"$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
// compact(): records its arguments, calls the stream function once the way Pi's
// summarizer does, then answers globalThis.stubSummary or throws globalThis.stubError.
export async function compact(preparation, model, apiKey, headers, customInstructions, signal, thinkingLevel, streamFn) {
  globalThis.compactCalls.push({ preparation, model, customInstructions, signal, streamFn });
  if (streamFn) await streamFn(model, { messages: [] }, { cacheRetention: "none" });
  if (globalThis.stubError) throw new Error(globalThis.stubError);
  return { summary: globalThis.stubSummary, firstKeptEntryId: preparation.firstKeptEntryId, tokensBefore: preparation.tokensBefore };
}
JS
}

install_real_pi_fixture() {
  local repo=$1
  mkdir -p "$repo/.pi/extensions" "$repo/node_modules/@earendil-works"
  cp "$EXT" "$repo/.pi/extensions/fm-compact-shape.ts"
  printf '%s\n' '{"type":"module"}' >"$repo/package.json"
  ln -s "$PI_PACKAGE_DIR" "$repo/node_modules/@earendil-works/pi-coding-agent"
}

# <case> <repo> <script-body> [env...]: the body sees `run(event-overrides, ctx-overrides)`
# (fires session_before_compact and resolves to the handler's result), `calls` (the stub
# compact() calls), `streams` (calls that reached ctx.modelRegistry.streamSimple),
# `notes` (ctx.ui.notify messages), `prep()` (a fresh preparation built from the fixture
# messages below), `sample` (those messages), `setSummary(text)` and `setError(text)`.
# OWN=no drops the fleet lock; MODEL_BASE_URL picks the model's baseUrl (default a native API).
run_case() {
  local name=$1 repo=$2 body=$3 home
  shift 3
  home="$TMP_ROOT/$name-home"
  mkdir -p "$home/state"
  env PLUGIN="$repo/.pi/extensions/fm-compact-shape.ts" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$@" BODY="$body" \
    node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

globalThis.compactCalls = [];
globalThis.stubSummary = "## Goal\nKeep the fleet moving.";
globalThis.stubError = "";
if (process.env.OWN !== "no") writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);

const MARK = "\u2063";
const wake = (reason, rows, extra) =>
  `${MARK}FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: ${reason}\n\n` +
  "WAKE DRAIN (bin/fm-wake-drain.sh already ran for this wake; do not run it again.):\n" +
  rows.join("\n") + "\n" +
  extra +
  "OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):\n" +
  "pc-aux2 [key=pending-reply-1] blocked: pending-reply-missed: old request\n" +
  "OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'\n" +
  "MERGE-READY WAITING (reported ready, no later status says it was merged - confirm each PR's live state before asking the captain):\n" +
  "mmc-sm PR 605 MERGE-READY waiting 153h: stale ready line\n" +
  "MERGE-READY WAITING: 3 more omitted (byte cap)\n" +
  "STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):\n" +
  "fmx-1 done [at=1]: backstop line\n" +
  "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.\n\n" +
  "Handle the wake. Watcher continuity is extension-owned.";
const sample = [
  { role: "custom", customType: "firstmate-sessionstart-nudge", content: `${MARK}FIRSTMATE_OP: v1 session-start: SESSION START (CONTEXT RE-EMIT) digest body`, display: false },
  { role: "user", content: [{ type: "text", text: `${MARK}FIRSTMATE_OP: v1 session-start: a pasted digest` }] },
  { role: "user", content: [{ type: "text", text: "merge PR 12 when green" }] },
  { role: "assistant", content: [
    { type: "thinking", thinking: "private reasoning" },
    { type: "text", text: "On it." },
    { type: "toolCall", id: "t1", name: "bash", arguments: { command: "bin/fm-merge-pr.sh --by captain https://example.test/pr/12" } },
  ] },
  { role: "toolResult", toolCallId: "t1", toolName: "bash", content: [{ type: "text", text: "MERGED repo#12" }] },
  { role: "user", content: [{ type: "text", text: wake("signal: a.status", ["1794219310\t74194\tsignal\ta.status\tsignal: a.status", "1794219311\t74195\tcheck\tk\tcheck: merge landed"], "UNREAD STATUS (new since last drain, not re-printed after this presentation):\nfmx-2 done [at=2]: ready in branch fm/fmx-2\n") }] },
  { role: "user", content: [{ type: "text", text: wake("check: rearm-resurface", ["1794219311\t74195\tcheck\tk\tcheck: merge landed", "1794219399\t74196\tcheck\tk2\tcheck: procevent"], "") }] },
];
const snapshot = JSON.stringify(sample);
const prep = () => ({
  firstKeptEntryId: "keep-1",
  messagesToSummarize: sample.slice(0, 6),
  turnPrefixMessages: sample.slice(6),
  isSplitTurn: true,
  tokensBefore: 400000,
  previousSummary: "## Goal\nOld goal.\n- no <read-files> in prose\n\n<read-files>\n/tmp/a\n</read-files>\n\n<modified-files>\n/tmp/b\n</modified-files>",
  fileOps: { read: new Set(["/tmp/a"]), written: new Set(["/tmp/c"]), edited: new Set(["/tmp/b"]) },
  settings: { enabled: true, reserveTokens: 600000, keepRecentTokens: 40000 },
});

const handlers = new Map();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default({ on(name, fn) { handlers.set(name, fn); } });
const streams = [];
const notes = [];
const run = (eventOverrides = {}, ctxOverrides = {}) => {
  const event = { type: "session_before_compact", preparation: prep(), branchEntries: [], customInstructions: undefined, reason: "threshold", willRetry: false, signal: new AbortController().signal, ...eventOverrides };
  const ctx = {
    model: { id: "m", provider: "p", api: "a", baseUrl: process.env.MODEL_BASE_URL || "https://api.example.test", maxTokens: 64000 },
    modelRegistry: { streamSimple(model, context, options) { streams.push({ model, context, options }); return { result: async () => ({}) }; } },
    ui: { notify(message, type) { notes.push({ message, type }); } },
    ...ctxOverrides,
  };
  return handlers.get("session_before_compact")(event, ctx);
};
const setSummary = (text) => { globalThis.stubSummary = text; };
const setError = (text) => { globalThis.stubError = text; };
const body = new Function("run", "calls", "streams", "notes", "prep", "sample", "setSummary", "setError", "snapshot", `return (async () => { ${process.env.BODY} })();`);
try {
  await body(run, globalThis.compactCalls, streams, notes, prep, sample, setSummary, setError, snapshot);
  console.log("ok");
} catch (error) {
  console.log(`FAILED: ${error.message}`);
}
process.exit(0);
EOF
}

expect_ok() {  # <message> <output>
  [ "$2" = ok ] || fail "$1: $2"
}

STUB_REPO="$TMP_ROOT/stub-repo"
install_stub_fixture "$STUB_REPO"

test_the_summarizer_gets_a_shaped_copy_and_the_checkpoint_rules() {
  local out
  out=$(run_case shaped "$STUB_REPO" '
    const result = await run();
    if (calls.length !== 1) throw new Error(`compact ran ${calls.length} time(s)`);
    const { preparation, customInstructions } = calls[0];
    const all = [...preparation.messagesToSummarize, ...preparation.turnPrefixMessages];
    const text = JSON.stringify(all);
    if (/SESSION START|a pasted digest/.test(text)) throw new Error("a session-start digest reached the summarizer");
    if (/private reasoning/.test(text)) throw new Error("assistant thinking reached the summarizer");
    if (!/On it\./.test(text) || !/fm-merge-pr\.sh --by captain/.test(text) || !/MERGED repo#12/.test(text)) throw new Error("assistant text, tool call or result was lost");
    if (!/merge PR 12 when green/.test(text)) throw new Error("the captain message was lost");
    for (const gone of ["OPEN DECISIONS", "MERGE-READY", "STATUS OUTCOME BACKSTOP", "backstop line", "WARNING", "WAKE DRAIN", "Watcher continuity"]) {
      if (text.includes(gone)) throw new Error(`repeated wake material reached the summarizer: ${gone}`);
    }
    if (all.length !== 5) throw new Error(`expected captain, assistant, tool result and two wakes, got ${all.length} messages`);
    const [first, second] = [all[3], all[4]].map((m) => m.content[0].text);
    if (!first.startsWith("\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: a.status")) throw new Error("the wake reason line was lost");
    if (!first.includes("1794219310\t74194\tsignal\ta.status\n") || first.includes("a.status\tsignal: a.status")) throw new Error("a row repeating the wake reason kept its reason column");
    if (!first.includes("74195\tcheck\tk\tcheck: merge landed") || !first.includes("fmx-2 done [at=2]: ready in branch fm/fmx-2")) throw new Error("a new row or unread status line was lost");
    if (second.includes("74195") || !second.includes("74196\tcheck\tk2\tcheck: procevent")) throw new Error("queue rows were not kept exactly once across the span");
    if (/<read-files>\n|<modified-files>/.test(preparation.previousSummary) || !preparation.previousSummary.includes("no <read-files> in prose")) throw new Error(`previous summary file lists not stripped cleanly: ${preparation.previousSummary}`);
    if (preparation.fileOps.read.size + preparation.fileOps.written.size + preparation.fileOps.edited.size !== 0) throw new Error("file operations still reach compact()");
    if (preparation.firstKeptEntryId !== "keep-1" || preparation.tokensBefore !== 400000) throw new Error("the cut point changed");
    for (const name of ["FIRSTMATE CHECKPOINT RULES", "bin/fm-merge-pr.sh", "bin/fm-spawn-task.sh", "bin/fm-steer.sh", "bin/fm-review-sweep.sh", "bin/fm-host-sweep.sh", "data/tools/fm-report-head.sh"]) {
      if (!customInstructions.includes(name)) throw new Error(`the checkpoint rules do not name ${name}`);
    }
    if (JSON.stringify(sample) !== snapshot) throw new Error("the session messages were modified");
    if (!result?.compaction || result.compaction.summary !== "## Goal\nKeep the fleet moving.") throw new Error("the summary was not returned");
    if (result.compaction.details.readFiles.length + result.compaction.details.modifiedFiles.length !== 0) throw new Error("file lists were carried into the compaction details");
    if (result.compaction.firstKeptEntryId !== "keep-1") throw new Error("the compaction lost its cut point");
  ')
  expect_ok "shaped copy" "$out"
  pass "the summarizer gets a shaped copy (no digest, thinking, repeated wake lists or file lists) and the checkpoint rules"
}

test_the_summary_request_goes_through_the_model_registry() {
  local out
  out=$(run_case route "$STUB_REPO" '
    await run();
    if (streams.length !== 1) throw new Error(`the registry stream was called ${streams.length} time(s)`);
    if (streams[0].options?.cacheRetention !== "none") throw new Error("the one-off summary marker did not reach the provider");
  ')
  expect_ok "route" "$out"
  pass "the summary request goes through the model registry's provider stream"
}

test_the_summary_is_capped_least_needed_sections_first() {
  local out
  out=$(run_case cap "$STUB_REPO" '
    const bullets = (label, n) => Array.from({ length: n }, (_, i) => `- ${label} ${i} ação concluída com êxito, revisão e mesclagem registradas`).join("\n");
    setSummary([
      "## Goal", "- answer the captain about PR 12", "",
      "## Constraints & Preferences", "- the captain wants plain Portuguese", "",
      "## Progress", "### Done", bullets("done", 200), "",
      "### In Progress", "- pmx-1 - waits for CI", "",
      "## Key Decisions", "- **merge order**: 12 before 13", "",
      "## Next Steps", "1. merge PR 12", "",
      "## Critical Context", bullets("context", 40),
      "", "<read-files>", "/tmp/x", "</read-files>",
    ].join("\n"));
    const result = await run();
    const summary = result.compaction.summary;
    const size = Buffer.byteLength(summary, "utf8");
    if (size > 8000) throw new Error(`summary is ${size} bytes`);
    if (summary.includes("\uFFFD")) throw new Error("the cut split a multibyte character");
    for (const kept of ["answer the captain about PR 12", "plain Portuguese", "pmx-1 - waits for CI", "12 before 13", "1. merge PR 12", "[summary cut to 8000 bytes"]) {
      if (!summary.includes(kept)) throw new Error(`lost: ${kept}`);
    }
    if (summary.includes("done 199")) throw new Error("the oldest Done bullets were kept while over the cap");
    if (summary.includes("<read-files>")) throw new Error("file lists survived");
    setSummary("## Goal\n- short\n\n<read-files>\n/tmp/y\n</read-files>");
    const small = await run();
    if (small.compaction.summary !== "## Goal\n- short") throw new Error(`a summary under the cap was changed: ${JSON.stringify(small.compaction.summary)}`);
  ')
  expect_ok "cap" "$out"
  pass "the summary is capped at 8000 bytes, history first, and file lists are stripped"
}

test_a_failure_leaves_pi_default_compaction() {
  local out
  out=$(run_case fallback "$STUB_REPO" '
    setError("Summarization failed: overloaded");
    const failed = await run();
    if (failed !== undefined) throw new Error("a failed summary still returned a compaction");
    if (notes.length !== 1 || notes[0].type !== "warning" || !/default compaction/.test(notes[0].message)) throw new Error("the fallback was not announced");
    setError("");
    setSummary("   ");
    if ((await run()) !== undefined) throw new Error("an empty summary still returned a compaction");
    const controller = new AbortController();
    controller.abort();
    setSummary("## Goal\n- x");
    if ((await run({ signal: controller.signal })) !== undefined) throw new Error("an aborted compaction still returned a result");
  ')
  expect_ok "fallback" "$out"
  pass "a failed, empty or aborted summary returns nothing, so Pi runs its default compaction"
}

test_only_the_lock_owner_shapes_and_the_bridge_needs_the_switch() {
  local out
  out=$(run_case nolock "$STUB_REPO" '
    if ((await run()) !== undefined || calls.length !== 0) throw new Error("a session without the fleet lock shaped its compaction");
  ' OWN=no)
  expect_ok "no lock" "$out"
  out=$(run_case bridge "$STUB_REPO" '
    if ((await run()) !== undefined || calls.length !== 0) throw new Error("a claude-bridge model shaped without FM_COMPACT_SHAPE=1");
  ' MODEL_BASE_URL=claude-bridge)
  expect_ok "bridge default" "$out"
  out=$(run_case bridge-on "$STUB_REPO" '
    if (!(await run())?.compaction || calls.length !== 1) throw new Error("FM_COMPACT_SHAPE=1 did not shape a claude-bridge compaction");
  ' MODEL_BASE_URL=claude-bridge FM_COMPACT_SHAPE=1)
  expect_ok "bridge switched on" "$out"
  out=$(run_case off "$STUB_REPO" '
    if ((await run()) !== undefined || calls.length !== 0) throw new Error("FM_COMPACT_SHAPE=0 still shaped");
  ' FM_COMPACT_SHAPE=0)
  expect_ok "off switch" "$out"
  pass "only the lock owner shapes; a claude-bridge model needs FM_COMPACT_SHAPE=1 and 0 turns it off"
}

test_manual_compact_focus_is_kept() {
  local out
  out=$(run_case focus "$STUB_REPO" '
    await run({ reason: "manual", customInstructions: "focus on PR 12" });
    const text = calls[0].customInstructions;
    if (!text.includes("FIRSTMATE CHECKPOINT RULES") || !text.includes("focus on PR 12")) throw new Error(`instructions: ${text}`);
  ')
  expect_ok "focus" "$out"
  pass "a manual /compact focus is kept after the checkpoint rules"
}

test_pi_compact_builds_the_shaped_request() {
  local repo out
  if ! command -v npm >/dev/null 2>&1 || [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return 0
  fi
  repo="$TMP_ROOT/real-repo"
  install_real_pi_fixture "$repo"
  out=$(run_case real "$repo" '
    // Pi calls the stream function for the history and for the split turn prefix.
    const prompts = [];
    const ctx = {
      modelRegistry: { streamSimple(model, context, options) {
        const user = context.messages.filter((m) => m.role === "user").pop();
        prompts.push({ text: user.content.map((b) => b.text).join(""), options });
        const reply = { role: "assistant", content: [{ type: "text", text: "## Goal\n- summarized" }], stopReason: "stop", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
        return { result: async () => reply };
      } },
    };
    const result = await run({}, ctx);
    if (prompts.length !== 2) throw new Error(`Pi made ${prompts.length} summarizer request(s), expected history and turn prefix`);
    const [history, turn] = prompts.map((p) => p.text);
    if (!history.includes("FIRSTMATE CHECKPOINT RULES") || !history.includes("bin/fm-spawn-task.sh")) throw new Error("the checkpoint rules are not in the summarizer request");
    // The rules name the tags themselves; the listed paths are what must not arrive.
    for (const gone of ["SESSION START", "private reasoning", "OPEN DECISIONS", "MERGE-READY", "/tmp/a", "/tmp/b", "/tmp/c"]) {
      if (history.includes(gone) || turn.includes(gone)) throw new Error(`the summarizer request still carries ${gone}`);
    }
    if (!history.includes("merge PR 12 when green") || !turn.includes("74196")) throw new Error("conversation content is missing from the request");
    if (prompts.some((p) => p.options?.cacheRetention !== "none")) throw new Error("a summarizer request lost the one-off marker");
    if (/<read-files>|<modified-files>/.test(result.compaction.summary)) throw new Error("Pi file lists survived in the summary");
  ')
  expect_ok "real Pi compact" "$out"
  pass "Pi's own compact() sends the shaped conversation and the rules, with no file lists"
}

test_the_summarizer_gets_a_shaped_copy_and_the_checkpoint_rules
test_the_summary_request_goes_through_the_model_registry
test_the_summary_is_capped_least_needed_sections_first
test_a_failure_leaves_pi_default_compaction
test_only_the_lock_owner_shapes_and_the_bridge_needs_the_switch
test_manual_compact_focus_is_kept
test_pi_compact_builds_the_shaped_request
