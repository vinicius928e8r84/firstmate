// Compaction shape for the Pi primary.
//
// When the context passes Pi's compaction threshold, Pi summarizes the older part
// of the conversation, and every later request rereads that summary until the next
// compaction. Pi's default prompt asks the summarizer to preserve everything it was
// given, so in the firstmate primary the summary grew with each compaction and kept
// re-teaching hand-made helper recipes after one-command tools replaced them. Its
// input also carried the session-start digest that is printed again right after the
// compaction, the assistant's thinking, and lists that every wake repeats.
//
// For the session that owns the fleet lock, this extension summarizes a shaped copy
// of Pi's compaction preparation instead, and leaves Pi's own preparation untouched:
//   - session-start digest messages are left out (the digest is re-emitted after the
//     compaction);
//   - assistant thinking is left out;
//   - a watcher wake keeps its reason line, each queue row the first time the row
//     appears in the span, and its one-time sections; the lists every drain repeats
//     (open decisions, record divergence, merge-ready, status-outcome backstop), the
//     warning lines and the drain boilerplate are left out;
//   - no file lists: the read and modified sets are emptied, and <read-files> and
//     <modified-files> blocks are stripped from the previous summary and the result.
// CHECKPOINT_RULES go to the summarizer as custom instructions (after any /compact
// focus text), the request goes through the model registry's provider stream like
// Pi's own compaction (the Claude bridge routes such one-off summaries to its
// isolated Claude Code process), and the summary is capped at SUMMARY_LIMIT_BYTES by
// trimming its least-needed sections first. Any failure returns nothing, so Pi runs
// its default compaction on the untouched preparation.
//
// The summary request is a one-off that nothing rereads, so it asks the provider for
// no prompt cache (DISABLE_PROMPT_CACHING in the stream's provider env, which the
// Claude bridge hands to its isolated Claude Code process): the input is billed once
// at the plain input rate instead of as a one-hour cache write. FM_COMPACT_SUMMARY_CACHE=1
// gives the provider's own default back.
//
// FM_COMPACT_SHAPE=0 turns this off and FM_COMPACT_SHAPE=1 turns it on. Unset, it is
// on except for a claude-bridge model: bridge releases before 0.9.3 summarize in
// their own session_before_compact hook, which runs before any project extension,
// so shaping next to it would pay for a second summary of the whole input. Set
// FM_COMPACT_SHAPE=1 in the primary's launcher once that hook is gone (bridge 0.9.3
// or later) or patched to stand aside under the same variable.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { compact } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI, SessionBeforeCompactEvent } from "@earendil-works/pi-coding-agent";

type Preparation = SessionBeforeCompactEvent["preparation"];
type Message = Preparation["messagesToSummarize"][number];
type StreamFn = NonNullable<Parameters<typeof compact>[7]>;
type Block = { type?: unknown; text?: unknown };

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;

export const SUMMARY_LIMIT_BYTES = 8000;

export function summaryEnv(flag: string | undefined, env: Record<string, string> | undefined): Record<string, string> | undefined {
  return flag === "1" ? env : { ...env, DISABLE_PROMPT_CACHING: "1" };
}

// The summarizer's instructions, appended by Pi after its own format as "Additional focus".
export const CHECKPOINT_RULES = [
  "FIRSTMATE CHECKPOINT RULES (they override the instructions above where they conflict, including any instruction to preserve everything from the previous summary):",
  "1. Size: keep the whole summary under 6,000 characters. Cut older detail first.",
  "2. Do not restate what the next request shows again anyway: the system prompt (AGENTS.md and the skills list) and the session-start digest re-emitted right after this compaction (data/captain.md, data/captain-shared.md, data/learnings.md, data/projects.md, data/secondmates.md, the backlog, each task's record and latest status). Name a path only when the next step needs it.",
  "3. Procedures: never write step recipes, sed templates, hand-written stand-in records or /tmp helper scripts; the hand-copied /tmp/fm-main helpers (spawn-rvf.sh, spawn-imp.sh, spawn-pm.sh, m<N>.sh merge scripts made with sed) are retired. Name the one command that does the job: bin/fm-merge-pr.sh --by captain|yolo <pr-url> (merge a reviewed PR: review pin, gate, stand-in, merge, sync and cleanup); bin/fm-spawn-task.sh scout|ship <id> <project> --title T --files <prefix> (file, brief, profile, spawn and launch check); bin/fm-steer.sh <task> --file - (steer a worker); bin/fm-review-sweep.sh (open the missing PR reviews); bin/fm-host-sweep.sh (clean idle agents and leftovers on every machine); data/tools/fm-pr-ready.sh (what each open PR waits on); data/tools/fm-report-head.sh <id> (a report's verdict and summary); bin/fm-captain-hold.sh (captain decisions); bin/fm-pending-reply-close-ghost.sh (ghost replies); bin/fm-procevent.sh handled (process-event wakes). If no command exists, write \"no command yet: <one line>\".",
  "4. Keep exactly: every ask from the captain in this span that is still open, with its time and the captain's own words when the wording matters; every decision the captain gave that is not yet written into data/captain.md or a task, with the task id; each task still in flight as \"<id> - what it waits for\"; PR URLs and head SHAs still in play; ids and numbers the next turns need.",
  "5. Done: at most 10 bullets, newest first, only work finished in this span that the captain has not been told about yet. Older history lives in the backlog Done list and the status logs.",
  "6. Constraints & Preferences: only constraints the captain stated in this span that are not yet in data/captain.md; otherwise write \"(none new)\".",
  "7. No file lists: no <read-files> and no <modified-files>.",
  "Write the summary in the language of the conversation.",
].join("\n");

export function checkpointInstructions(customInstructions?: string): string {
  const focus = customInstructions?.trim();
  return focus ? `${CHECKPOINT_RULES}\nFocus requested for this compaction: ${focus}` : CHECKPOINT_RULES;
}

export function shapeEnabled(flag: string | undefined, modelBaseUrl: string | undefined): boolean {
  if (flag === "0") return false;
  if (flag === "1") return true;
  return modelBaseUrl !== "claude-bridge";
}

function bytes(text: string): number {
  return Buffer.byteLength(text, "utf8");
}

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim() : "";
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

// Same ownership walk as the other primary extensions: the lock names this
// process or one of its ancestors. Workers in this repository load the
// extension too and keep Pi's default compaction.
function ownsFleetLock(): boolean {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return false;
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1" || !pidAlive(lockPid)) return false;
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return true;
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return false;
}

// Firstmate operational inputs carry "U+2063 FIRSTMATE_OP: v1 <kind>: " (bin/fm-operational-input.sh).
const SESSION_START_INPUT = /^\u2063?FIRSTMATE_OP: v1 session-start: /;
const WATCHER_INPUT = /^(\u2063?FIRSTMATE_OP: v1 watcher: )?FIRSTMATE WATCHER WAKE: /;
const SESSION_START_MESSAGE_TYPE = "firstmate-sessionstart-nudge";

function contentOf(message: Message): unknown {
  return (message as { content?: unknown }).content;
}

function messageText(message: Message): string {
  const content = contentOf(message);
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return (content as Block[])
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text as string)
    .join("\n");
}

export function isSessionStartDigest(message: Message): boolean {
  const { role, customType } = message as { role?: string; customType?: string };
  if (role === "custom" && customType === SESSION_START_MESSAGE_TYPE) return true;
  return (role === "user" || role === "custom") && SESSION_START_INPUT.test(messageText(message));
}

// Wake-drain sections that every drain prints again until the underlying record
// changes; the durable records and the next drain still hold them.
const REPEATED_SECTIONS = new Set([
  "STATUS OUTCOME BACKSTOP",
  "OPEN DECISIONS",
  "RECORD DIVERGENCE",
  "MERGE-READY WAITING",
  "WARNING",
]);
const SECTION_HEADER = /^([A-Z][A-Z0-9_ /-]*[A-Z0-9])(?: \([^)]*\))?:/;
// <epoch> <seq> <kind> <key> <reason>, tab-separated (bin/fm-wake-drain.sh).
const QUEUE_ROW = /^[0-9]+\t([0-9]+)\t[^\t]*\t[^\t]*\t/;

// <seenRows> carries the queue sequence numbers already kept earlier in the span.
// A kept row drops its reason when it only repeats the wake's own reason line.
export function trimWakeText(text: string, seenRows: Set<string>): string {
  const lines = text.split("\n");
  const kept = [lines[0]];
  const wakeReason = lines[0].replace(WATCHER_INPUT, "");
  let dropping = false;
  for (const line of lines.slice(1)) {
    const header = SECTION_HEADER.exec(line);
    if (header) {
      dropping = REPEATED_SECTIONS.has(header[1]);
      if (dropping || header[1] === "WAKE DRAIN") continue;
    } else if (line.trim() === "") {
      dropping = false;
    } else if (dropping) {
      continue;
    }
    const row = QUEUE_ROW.exec(line);
    if (row) {
      if (seenRows.has(row[1])) continue;
      seenRows.add(row[1]);
      kept.push(line.slice(row[0].length) === wakeReason ? row[0].slice(0, -1) : line);
      continue;
    }
    if (line.endsWith("Watcher continuity is extension-owned.")) continue;
    kept.push(line);
  }
  return kept.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd();
}

function replaceText(message: Message, text: string): Message {
  const content = contentOf(message);
  if (typeof content === "string") return { ...message, content: text } as Message;
  if (!Array.isArray(content)) return message;
  let placed = false;
  const blocks = (content as Block[]).flatMap((block) => {
    if (block?.type !== "text") return [block];
    if (placed) return [];
    placed = true;
    return [{ ...block, text }];
  });
  return { ...message, content: blocks } as Message;
}

// Returns new message objects; the session's own messages are never modified.
export function shapeMessages(messages: Message[], seenRows: Set<string>): Message[] {
  const shaped: Message[] = [];
  for (const message of messages) {
    if (isSessionStartDigest(message)) continue;
    const role = (message as { role?: unknown }).role;
    const content = contentOf(message);
    if (role === "assistant" && Array.isArray(content)) {
      const visible = (content as Block[]).filter((block) => block?.type !== "thinking");
      shaped.push({ ...message, content: visible } as Message);
      continue;
    }
    if (role === "user") {
      const text = messageText(message);
      if (WATCHER_INPUT.test(text)) {
        shaped.push(replaceText(message, trimWakeText(text, seenRows)));
        continue;
      }
    }
    shaped.push(message);
  }
  return shaped;
}

// Pi appends each list as its own block, the tags alone on their lines; a tag
// mentioned inside a line of prose is left alone.
export function stripFileLists(text: string): string {
  return text.replace(/\n*^<(read-files|modified-files)>$[\s\S]*?^<\/\1>$/gm, "").trimEnd();
}

export function shapePreparation(preparation: Preparation): Preparation {
  const seenRows = new Set<string>();
  return {
    ...preparation,
    messagesToSummarize: shapeMessages(preparation.messagesToSummarize, seenRows),
    turnPrefixMessages: shapeMessages(preparation.turnPrefixMessages, seenRows),
    previousSummary: preparation.previousSummary === undefined ? undefined : stripFileLists(preparation.previousSummary),
    fileOps: { ...preparation.fileOps, read: new Set<string>(), written: new Set<string>(), edited: new Set<string>() },
  };
}

type Section = { title: string; lines: string[]; rank: number };

// Over the cap, sections are cut by rank, lowest first, each from its last line
// up: first what the backlog, the status logs, the task records and the re-emitted
// digest can restore, last what only this summary holds - the captain's decisions,
// the plan, the captain's constraints and open asks, the split turn's context and
// any text before the first heading. The first matching pattern gives the rank.
const SECTION_RANKS: Array<[RegExp, number]> = [
  [/^#+\s*done\b/i, 0],
  [/^#+\s*critical context\b/i, 1],
  [/^#+\s*blocked\b/i, 2],
  [/^#+\s*in progress\b/i, 4],
  [/^#+\s*key decisions\b/i, 5],
  [/^#+\s*next steps\b/i, 6],
  [/^#+\s*constraints\b/i, 7],
  [/^#+\s*goal\b/i, 8],
];
const OTHER_SECTION_RANK = 3;
const TURN_CONTEXT_RANK = 9;
const PREAMBLE_RANK = 10;

function splitSections(text: string): Section[] {
  const sections: Section[] = [{ title: "", lines: [], rank: PREAMBLE_RANK }];
  // Pi joins a split turn's own summary after this marker; every section after it belongs to that turn.
  let inTurnContext = false;
  for (const line of text.split("\n")) {
    if (line.startsWith("**Turn Context")) inTurnContext = true;
    if (/^#{1,6} /.test(line) || line.startsWith("**Turn Context")) {
      const rank = inTurnContext
        ? TURN_CONTEXT_RANK
        : SECTION_RANKS.find(([pattern]) => pattern.test(line))?.[1] ?? OTHER_SECTION_RANK;
      sections.push({ title: line, lines: [], rank });
    } else {
      sections[sections.length - 1].lines.push(line);
    }
  }
  return sections;
}

function joinSections(sections: Section[]): string {
  return sections
    .flatMap((section) => (section.title ? [section.title, ...section.lines] : section.lines))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function cutToBytes(text: string, limit: number): string {
  if (bytes(text) <= limit) return text;
  let used = 0;
  let end = 0;
  for (const char of text) {
    used += bytes(char);
    if (used > limit) break;
    end += char.length;
  }
  const cut = text.slice(0, end);
  const lastBreak = cut.lastIndexOf("\n");
  return lastBreak > 0 ? cut.slice(0, lastBreak) : cut;
}

export function capSummary(summary: string, limitBytes = SUMMARY_LIMIT_BYTES): string {
  const text = stripFileLists(summary).trim();
  if (bytes(text) <= limitBytes) return text;
  const note = `[summary cut to ${limitBytes} bytes, least-needed sections first; older history: backlog Done list, data/<id>/report.md, state/<id>.status]`;
  const budget = limitBytes - bytes(note) - 2;
  const sections = splitSections(text);
  // Every line plus its newline: never less than the joined text, so a fit here is a real fit.
  let size = sections.reduce(
    (total, section) => total + section.lines.reduce((sum, line) => sum + bytes(line) + 1, section.title ? bytes(section.title) + 1 : 0),
    0,
  );
  for (let rank = 0; rank <= PREAMBLE_RANK && size > budget; rank += 1) {
    for (const section of sections.filter((candidate) => candidate.rank === rank).reverse()) {
      while (size > budget && section.lines.length > 0) size -= bytes(section.lines.pop() as string) + 1;
    }
  }
  return `${cutToBytes(joinSections(sections), budget)}\n\n${note}`;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_before_compact", async (event, ctx) => {
    const model = ctx.model;
    if (!model || !shapeEnabled(process.env.FM_COMPACT_SHAPE, model.baseUrl) || !ownsFleetLock()) return undefined;
    try {
      // The registry's stream is the same class as the one StreamFn names; the cast
      // only bridges the two package copies a consumer install can resolve them from.
      const streamFn: StreamFn = (requestModel, context, options) =>
        ctx.modelRegistry.streamSimple(requestModel, context, {
          ...options,
          env: summaryEnv(process.env.FM_COMPACT_SUMMARY_CACHE, options?.env),
        }) as unknown as ReturnType<StreamFn>;
      const result = await compact(
        shapePreparation(event.preparation),
        model,
        undefined,
        undefined,
        checkpointInstructions(event.customInstructions),
        event.signal,
        undefined,
        streamFn,
      );
      const summary = capSummary(result.summary);
      if (!summary || event.signal.aborted) return undefined;
      return { compaction: { ...result, summary, details: { readFiles: [], modifiedFiles: [] } } };
    } catch (error) {
      if (!event.signal.aborted) {
        const reason = error instanceof Error ? error.message : String(error);
        ctx.ui?.notify?.(`Compaction shape failed (${reason}); Pi's default compaction runs instead.`, "warning");
      }
      return undefined;
    }
  });
}
