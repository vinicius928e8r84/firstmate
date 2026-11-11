#!/usr/bin/env bash
# tests/fm-pi-skill-once.test.sh - the Pi primary's skill loading
# (.pi/extensions/fm-skill-once.ts). Each case drives the real extension's input
# handler in node with a mock Pi context; the last case, when a real Pi package is
# installed, runs a real Pi session on a scripted provider and compares what the
# model would be sent with and without the extension.
# The JavaScript case bodies below are single-quoted on purpose, template literals included.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-skill-once)
EXT="$ROOT/.pi/extensions/fm-skill-once.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
export NODE_NO_WARNINGS=1

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/.pi/extensions"
cp "$EXT" "$REPO/.pi/extensions/fm-skill-once.ts"
printf '%s\n' '{"type":"module"}' >"$REPO/package.json"

# <case> <script-body> [env...]: the body sees `run(text, messages, opts)` (fires the
# input handler and resolves to its result; opts.commands replaces the registered
# slash commands), `skillBlock(name, location, body)` and `config(text)` (writes
# config/skill-shortcuts). OWN=no drops the fleet lock.
run_case() {
  local name=$1 body=$2 home
  shift 2
  home="$TMP_ROOT/$name-home"
  mkdir -p "$home/state" "$home/config"
  env PLUGIN="$REPO/.pi/extensions/fm-skill-once.ts" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$@" BODY="$body" \
    node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

if (process.env.OWN !== "no") writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);

const WAYFINDER = "/skills/wayfinder/SKILL.md";
const defaultCommands = [
  { name: "skill:wayfinder", source: "skill", sourceInfo: { path: WAYFINDER } },
  { name: "skill:afk", source: "skill", sourceInfo: { path: "/skills/afk/SKILL.md" } },
];
const handlers = new Map();
let commands = defaultCommands;
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default({ on(name, fn) { handlers.set(name, fn); }, getCommands() { return commands; } });
const skillBlock = (name, location, body) => `<skill name="${name}" location="${location}">\nReferences are relative to /x.\n\n${body}\n</skill>`;
const run = (text, messages = [], opts = {}) => {
  commands = opts.commands ?? defaultCommands;
  const ctx = { sessionManager: { buildSessionProjection: () => ({ messages }) } };
  return handlers.get("input")({ type: "input", text, source: "interactive" }, ctx);
};
const config = (text) => writeFileSync(`${process.env.FM_CONFIG_OVERRIDE}/skill-shortcuts`, text);
const body = new Function("run", "skillBlock", "config", "WAYFINDER", `return (async () => { ${process.env.BODY} })();`);
try {
  await body(run, skillBlock, config, WAYFINDER);
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

test_a_skill_already_in_the_context_is_not_pasted_again() {
  local out
  out=$(run_case repeat '
    const loaded = [{ role: "user", content: [{ type: "text", text: skillBlock("afk", "/skills/afk/SKILL.md", "LONG BODY") }] }];
    const again = await run("/skill:afk now", loaded);
    if (again?.action !== "transform") throw new Error(`a repeated skill was not rewritten: ${JSON.stringify(again)}`);
    if (!again.text.includes("already loaded above") || !again.text.includes("/skills/afk/SKILL.md")) throw new Error(`no already-loaded line: ${again.text}`);
    if (!again.text.endsWith("\n\nnow")) throw new Error(`the arguments were lost: ${again.text}`);
    if (again.text.length > 200) throw new Error("the replacement is not one short line");
    const bare = await run("/skill:afk", loaded);
    if (bare.text.includes("\n")) throw new Error("a bare repeat is more than one line");
    const stringContent = await run("/skill:afk", [{ role: "user", content: skillBlock("afk", "/skills/afk/SKILL.md", "B") }]);
    if (stringContent?.action !== "transform") throw new Error("a skill block held as a plain string was missed");
  ')
  expect_ok "repeat" "$out"
  pass "a skill whose block is still in the context becomes one already-loaded line that keeps the arguments"
}

test_a_skill_not_in_the_context_loads_normally() {
  local out
  out=$(run_case fresh '
    const other = [{ role: "user", content: [{ type: "text", text: skillBlock("quiet", "/skills/quiet/SKILL.md", "B") }] }];
    for (const [text, messages] of [
      ["/skill:afk", []],
      ["/skill:afk", other],
      ["/skill:afk", [{ role: "assistant", content: [{ type: "text", text: skillBlock("afk", "/x", "quoted by the model") }] }]],
      ["/skill:afk", [{ role: "user", content: [{ type: "text", text: "see <skill name=\"afk\" location=\"/x\"> quoted mid-sentence" }] }]],
      ["/skill:unknown arg", []],
      ["afk", []],
      ["/afk", []],
      ["merge PR 12", []],
    ]) {
      const result = await run(text, messages);
      if (result?.action !== "continue") throw new Error(`${text} was changed: ${JSON.stringify(result)}`);
    }
  ')
  expect_ok "fresh" "$out"
  pass "a skill that is not in the context, and every other input, passes through unchanged"
}

test_a_compacted_away_skill_loads_in_full_again() {
  local out
  out=$(run_case compacted '
    const afterCompaction = [{ role: "compactionSummary", summary: "earlier: afk was loaded" }, { role: "user", content: [{ type: "text", text: "next" }] }];
    const result = await run("/skill:afk", afterCompaction);
    if (result?.action !== "continue") throw new Error(`a skill missing from the projected context was not reloaded: ${JSON.stringify(result)}`);
  ')
  expect_ok "compacted" "$out"
  pass "a skill the compaction removed from the context loads in full again"
}

test_wayfinder_is_a_shortcut_that_opens_a_scout() {
  local out
  out=$(run_case shortcut '
    const bodyInContext = [{ role: "user", content: [{ type: "text", text: skillBlock("wayfinder", WAYFINDER, "THE WHOLE FLOW") }] }];
    for (const messages of [[], bodyInContext]) {
      const result = await run("/skill:wayfinder chart the reorganisation", messages);
      if (result?.action !== "transform") throw new Error(`wayfinder was not rewritten: ${JSON.stringify(result)}`);
      for (const needed of ["bin/fm-spawn-task.sh", "scout", WAYFINDER, "Request: chart the reorganisation"]) {
        if (!result.text.includes(needed)) throw new Error(`the shortcut lacks ${needed}: ${result.text}`);
      }
      if (result.text.includes("THE WHOLE FLOW") || result.text.length > 800) throw new Error("the shortcut is not short");
    }
    const bare = await run("/skill:wayfinder");
    if (!bare.text.includes("ask the captain")) throw new Error(`a bare shortcut has no request fallback: ${bare.text}`);
    const missing = await run("/skill:wayfinder x", [], { commands: [] });
    if (missing?.action !== "continue") throw new Error("a shortcut without an installed skill must leave Pi to answer");
  ')
  expect_ok "shortcut" "$out"
  pass "wayfinder becomes a short instruction that opens a scout on the skill file, not the skill text"
}

test_config_chooses_the_shortcut_skills() {
  local out
  out=$(run_case config '
    config("");
    if ((await run("/skill:wayfinder x"))?.action !== "continue") throw new Error("an empty file must switch the shortcut off");
    config("# only afk\nafk  # trailing\n");
    if ((await run("/skill:afk x"))?.action !== "transform") throw new Error("a listed skill is not a shortcut");
    if ((await run("/skill:wayfinder x"))?.action !== "continue") throw new Error("an unlisted skill became a shortcut");
  ')
  expect_ok "config" "$out"
  pass "config/skill-shortcuts picks the shortcut skills; empty means none"
}

test_only_the_lock_owner_is_rewritten_and_the_switch_turns_it_off() {
  local out
  out=$(run_case notowner '
    const loaded = [{ role: "user", content: [{ type: "text", text: skillBlock("afk", "/x", "B") }] }];
    for (const text of ["/skill:afk", "/skill:wayfinder x"]) {
      if ((await run(text, loaded))?.action !== "continue") throw new Error(`a worker session was rewritten: ${text}`);
    }
  ' OWN=no)
  expect_ok "not the lock owner" "$out"
  out=$(run_case off '
    const loaded = [{ role: "user", content: [{ type: "text", text: skillBlock("afk", "/x", "B") }] }];
    for (const text of ["/skill:afk", "/skill:wayfinder x"]) {
      if ((await run(text, loaded))?.action !== "continue") throw new Error(`FM_SKILL_ONCE=0 still rewrote ${text}`);
    }
  ' FM_SKILL_ONCE=0)
  expect_ok "off switch" "$out"
  pass "only the session that owns the fleet lock is rewritten, and FM_SKILL_ONCE=0 turns it off"
}

# A real Pi session on a scripted provider: what the model is sent for repeated
# /skill: commands, with the extension and without it.
test_real_pi_sends_the_skill_once_and_wayfinder_as_a_shortcut() {
  local pi_ai out
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return 0
  fi
  for pi_ai in "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$(dirname "$PI_PACKAGE_DIR")/pi-ai"; do
    [ -f "$pi_ai/dist/providers/faux.js" ] && break
    pi_ai=""
  done
  if [ -z "$pi_ai" ]; then
    echo "skip: the scripted provider of @earendil-works/pi-ai is not installed"
    return 0
  fi
  out=$(PLUGIN="$REPO/.pi/extensions/fm-skill-once.ts" PI_DIR="$PI_PACKAGE_DIR" PI_AI="$pi_ai" TMP="$TMP_ROOT/real" \
    node --input-type=module 2>&1 <<'EOF'
import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { TMP, PLUGIN, PI_DIR, PI_AI } = process.env;
mkdirSync(`${TMP}/home/state`, { recursive: true });
mkdirSync(`${TMP}/home/config`, { recursive: true });
writeFileSync(`${TMP}/home/state/.lock`, `${process.pid}\n`);
process.env.FM_HOME = `${TMP}/home`;
for (const name of ["afk", "wayfinder"]) {
  mkdirSync(`${TMP}/skills/${name}`, { recursive: true });
  writeFileSync(`${TMP}/skills/${name}/SKILL.md`, `---\nname: ${name}\ndescription: ${name} test skill\n---\n\n${`${name.toUpperCase()}-BODY `.repeat(2000)}\n`);
}
const pi = await import(pathToFileURL(`${PI_DIR}/dist/index.js`).href);
const faux = await import(pathToFileURL(`${PI_AI}/dist/providers/faux.js`).href);

// What the model is sent when the script below runs, with and without the extension.
async function sizes(withExtension) {
  const core = faux.createFauxCore({ api: "faux-api", provider: "faux", models: [{ id: "faux-1", contextWindow: 1000000 }] });
  const sent = [];
  core.setResponses(Array.from({ length: 12 }, () => (context) => {
    sent.push(JSON.stringify(context.messages).length);
    return faux.fauxAssistantMessage("ok");
  }));
  const dir = `${TMP}/${withExtension ? "after" : "before"}`;
  mkdirSync(dir, { recursive: true });
  const modelRuntime = await pi.ModelRuntime.create({ authPath: `${dir}/auth.json`, modelsPath: `${dir}/models.json` });
  modelRuntime.registerProvider("faux", {
    baseUrl: "http://faux.invalid",
    apiKey: "x",
    api: "faux-api",
    streamSimple: core.streamSimple,
    models: [{ id: "faux-1", name: "faux", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000000, maxTokens: 8000 }],
  });
  const loader = new pi.DefaultResourceLoader({
    cwd: dir,
    agentDir: `${dir}/agent`,
    noExtensions: true,
    noSkills: true,
    noPromptTemplates: true,
    noThemes: true,
    noContextFiles: true,
    additionalSkillPaths: [`${TMP}/skills`],
    additionalExtensionPaths: withExtension ? [PLUGIN] : [],
  });
  await loader.reload();
  const { session } = await pi.createAgentSession({
    cwd: dir,
    agentDir: `${dir}/agent`,
    model: modelRuntime.getModel("faux", "faux-1"),
    modelRuntime,
    resourceLoader: loader,
    sessionManager: pi.SessionManager.inMemory(dir),
    settingsManager: pi.SettingsManager.inMemory({ compaction: { enabled: false } }),
    tools: [],
  });
  await session.bindExtensions?.({});
  const users = [];
  for (const text of ["/skill:afk", "next", "/skill:afk again", "/skill:wayfinder chart it", "/skill:wayfinder again"]) {
    await session.prompt(text);
    const last = session.messages.filter((m) => m.role === "user").at(-1);
    users.push(typeof last.content === "string" ? last.content : last.content.map((b) => b.text ?? "").join(""));
  }
  session.dispose();
  return { sent, users };
}

try {
  const before = await sizes(false);
  const after = await sizes(true);
  const body = (name) => `${name.toUpperCase()}-BODY`;
  if (!before.users[2].includes(body("afk")) || !before.users[4].includes(body("wayfinder"))) throw new Error("the baseline does not paste the skills (the case is vacuous)");
  if (!after.users[0].includes(body("afk"))) throw new Error("the first load of a skill must stay in full");
  if (after.users[2].includes(body("afk")) || !after.users[2].includes("already loaded above")) throw new Error(`the repeated skill was pasted again: ${after.users[2].slice(0, 120)}`);
  if (after.users[3].includes(body("wayfinder")) || !after.users[3].includes("bin/fm-spawn-task.sh")) throw new Error(`wayfinder was not a shortcut: ${after.users[3].slice(0, 120)}`);
  const last = after.sent.length - 1;
  if (after.sent[last] * 2 > before.sent[last]) throw new Error(`the final request is not at most half the size: ${after.sent[last]} vs ${before.sent[last]}`);
  console.log("ok");
} catch (error) {
  console.log(`FAILED: ${error.message}`);
}
process.exit(0);
EOF
)
  expect_ok "real Pi" "$out"
  pass "a real Pi session sends a repeated skill as one line and wayfinder as a shortcut, and the request shrinks"
}

test_a_skill_already_in_the_context_is_not_pasted_again
test_a_skill_not_in_the_context_loads_normally
test_a_compacted_away_skill_loads_in_full_again
test_wayfinder_is_a_shortcut_that_opens_a_scout
test_config_chooses_the_shortcut_skills
test_only_the_lock_owner_is_rewritten_and_the_switch_turns_it_off
test_real_pi_sends_the_skill_once_and_wayfinder_as_a_shortcut
