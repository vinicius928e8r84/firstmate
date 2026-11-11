// Skill loading for the Pi primary.
//
// "/skill:<name>" makes Pi paste the whole SKILL.md into the conversation as a user
// message, and every later request rereads it until the next compaction. The primary
// ran "/skill:wayfinder" 11 times in one session (about 5.5k tokens each, 19% of the
// window) and the same copy was already in the context every time after the first.
//
// For the session that owns the fleet lock, this extension rewrites that command
// before Pi expands it:
//   - a skill whose "<skill name=...>" block is still in the model's context is not
//     pasted again; one line says it is already loaded above and the arguments follow;
//   - a skill named in config/skill-shortcuts (default: wayfinder) is not pasted at all;
//     a short instruction tells the primary to open a scout that reads the skill by
//     path, because the long flow belongs in a worker's context, not the primary's.
// The context is the compaction-aware projection, so a skill the compaction summarized
// away loads in full again. Nothing else is touched: the skill file, Pi's own
// expansion and every other input pass through unchanged.
//
// config/skill-shortcuts (docs/configuration.md): one skill name per line, "#"
// comments; absent means wayfinder, empty (or only comments) means no shortcut.
// FM_SKILL_ONCE=0 turns the whole extension off.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;

const DEFAULT_SHORTCUTS = ["wayfinder"];

type Block = { type?: unknown; text?: unknown };
type Message = { role?: unknown; content?: unknown };
type SkillCommand = { name: string; args: string };

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
// extension too and keep Pi's own skill loading.
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

// Pi's own parse: the name runs to the first space, the arguments are the trimmed rest.
export function parseSkillCommand(text: string): SkillCommand | null {
  if (!text.startsWith("/skill:")) return null;
  const space = text.indexOf(" ");
  const name = space === -1 ? text.slice(7) : text.slice(7, space);
  if (!name) return null;
  return { name, args: space === -1 ? "" : text.slice(space + 1).trim() };
}

export function parseShortcuts(file: string | null): string[] {
  if (file === null) return DEFAULT_SHORTCUTS;
  return file
    .split("\n")
    .map((line) => line.replace(/#.*/, "").trim())
    .filter(Boolean);
}

function readShortcuts(): string[] {
  try {
    return parseShortcuts(readFileSync(`${config}/skill-shortcuts`, "utf8"));
  } catch {
    return DEFAULT_SHORTCUTS;
  }
}

function messageText(message: Message): string {
  const content = message.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return (content as Block[])
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text as string)
    .join("\n");
}

const SKILL_BLOCK = /^<skill name="([^"]+)" location="([^"]+)">\n/;

// Skill name -> location of every skill block a user message in <messages> carries.
export function loadedSkills(messages: Message[]): Map<string, string> {
  const loaded = new Map<string, string>();
  for (const message of messages) {
    if (message.role !== "user") continue;
    const block = SKILL_BLOCK.exec(messageText(message));
    if (block) loaded.set(block[1], block[2]);
  }
  return loaded;
}

export function alreadyLoadedText(name: string, location: string, args: string): string {
  const line = `Skill "${name}" is already loaded above in this conversation (${location}); follow that copy.`;
  return args ? `${line}\n\n${args}` : line;
}

export function shortcutText(name: string, location: string, args: string): string {
  return [
    `Shortcut for skill "${name}": it is a long flow, so it runs in a worker, not in this conversation. Do not read it here.`,
    `Open a scout with bin/fm-spawn-task.sh (a ship only if the request asks for the change itself) whose task text is: read ${location} first and follow it for the request below.`,
    "Then tell the captain which scout is under way.",
    `Request: ${args || "(none given; ask the captain what to chart)"}`,
  ].join("\n");
}

function sessionMessages(ctx: unknown): Message[] {
  const manager = (ctx as { sessionManager?: { buildSessionProjection?: () => { messages?: Message[] } } }).sessionManager;
  try {
    return manager?.buildSessionProjection?.().messages ?? [];
  } catch {
    return [];
  }
}

export default function (pi: ExtensionAPI) {
  pi.on("input", async (event, ctx) => {
    if (process.env.FM_SKILL_ONCE === "0") return { action: "continue" };
    const command = parseSkillCommand(event.text);
    if (!command || !ownsFleetLock()) return { action: "continue" };
    if (readShortcuts().includes(command.name)) {
      const location = pi.getCommands().find((entry) => entry.name === `skill:${command.name}`)?.sourceInfo?.path;
      if (location) {
        return { action: "transform", text: shortcutText(command.name, location, command.args), images: event.images };
      }
    }
    const location = loadedSkills(sessionMessages(ctx)).get(command.name);
    if (location) {
      return { action: "transform", text: alreadyLoadedText(command.name, location, command.args), images: event.images };
    }
    return { action: "continue" };
  });
}
