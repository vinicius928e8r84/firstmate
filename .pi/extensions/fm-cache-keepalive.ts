// Prompt-cache keep-alive for the Pi primary.
//
// The orchestrator re-reads a context of hundreds of thousands of tokens on
// every call, almost all of it from the provider's prompt cache. After the
// cache's lifetime passes with no call, the next call rewrites the whole
// context at the cache-write price instead of reading it at a tenth of that.
// While the primary session is idle this extension sends one tiny turn shortly
// before that lifetime ends, so the next real call still reads from cache.
//
// A ping costs a tenth of the context in cache-read units plus a few output
// tokens; a miss costs about eleven times that. The cap on consecutive pings
// bounds the spend of a long idle night, and any real activity resets it.
//
// The same idle hook also resumes a session whose last turn the provider cut
// with a usage-limit refusal: a "do nothing" ping would burn the first call
// after the reset on nothing, and the cut work would wait for someone to notice.
// Such a session is polled cheaply (bin/fm-quota-silence.sh status reads
// quota-axi, no model call) and, once the limit has lifted, is told to continue
// the turn that was cut.
//
// Only the session that owns the fleet lock pings. The extension is project-
// local, so it is also loaded in every worker that works on this repository,
// and those sessions must stay silent.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;

function numberFromEnv(name: string, fallback: number, minimum: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  return Number.isFinite(value) && value >= minimum ? value : fallback;
}

// 50 minutes: inside the one-hour cache lifetime the measured misses followed
// (FM_CACHE_KEEPALIVE_* in docs/configuration.md).
const idleMs = numberFromEnv("FM_CACHE_KEEPALIVE_IDLE_MS", 50 * 60 * 1000, 1);
const maxConsecutivePings = numberFromEnv("FM_CACHE_KEEPALIVE_MAX_PINGS", 4, 0);
// Below this much context a miss costs less than the machinery is worth.
const minContextTokens = numberFromEnv("FM_CACHE_KEEPALIVE_MIN_TOKENS", 30000, 0);
const enabled = process.env.FM_CACHE_KEEPALIVE !== "0";
// Seconds-level knobs for the limit resume; the poll is a quota-axi read, not a model call.
const resumePollMs = numberFromEnv("FM_LIMIT_RESUME_POLL_MS", 5 * 60 * 1000, 1);
// Model turns spent on resume attempts per cut; a limit that still refuses after these gives up.
const maxResumeAttempts = numberFromEnv("FM_LIMIT_RESUME_MAX_ATTEMPTS", 4, 0);
const resumeEnabled = process.env.FM_LIMIT_RESUME !== "0";
const resumeStatusCommand = process.env.FM_LIMIT_RESUME_STATUS || `${root}/bin/fm-quota-silence.sh`;

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

// Same ownership walk as the watcher and guard extensions: the lock names this
// process or one of its ancestors.
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

export const KEEPALIVE_MESSAGE_TYPE = "fm-cache-keepalive";
export const RESUME_MESSAGE_TYPE = "fm-limit-resume";
const resumeText =
  "Resume instruction from the harness, not from the captain or the fleet. " +
  "The usage limit that cut your previous turn has reset. " +
  "Continue the work you were doing when it stopped; if that turn had already finished, say so in one line.";

// Provider wordings of an exhausted subscription or usage limit, as carried by an
// errored assistant message's errorMessage (pi has no typed rate-limit error). The
// Claude bridge leads with "Claude rate limit" before 0.9.3 and "Claude quota exceeded" since.
const usageLimitPattern =
  /claude rate limit|claude quota exceeded|you(?:'|’)ve (?:hit|reached) your|you(?:'|’)re out of (?:extra )?usage|usage (?:limit|allocation)|(?:weekly|5-hour|five.hour|session) limit/i;

export function isUsageLimitCut(messages: unknown): boolean | undefined {
  if (!Array.isArray(messages)) return undefined;
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const message = messages[i] as { role?: string; stopReason?: string; errorMessage?: string } | undefined;
    if (!message || message.role !== "assistant") continue;
    return message.stopReason === "error" && usageLimitPattern.test(String(message.errorMessage ?? ""));
  }
  return undefined;
}

// 0 while the configured account's limit still stands; anything else (clear,
// unknown, no script) lets the resume go, since a refused attempt is cheap.
function limitStillStands(): boolean {
  const result = spawnSync(resumeStatusCommand, ["status"], { encoding: "utf8", timeout: 60000, env: { ...process.env, FM_HOME: fmHome } });
  return result.status === 0;
}
const keepaliveText =
  "Cache keep-alive ping from the harness, not from the captain or the fleet. " +
  "Take no action and call no tool. Reply with exactly: ok";

export default function (pi: ExtensionAPI) {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let pingInFlight = false;
  let consecutivePings = 0;
  let cutByLimit = false;
  let resumeAttempts = 0;

  const clear = (): void => {
    if (timer) clearTimeout(timer);
    timer = null;
  };

  const schedule = (ctx: { isIdle?: () => boolean; getContextUsage?: () => { tokens?: number | null } | undefined }): void => {
    clear();
    if (!enabled || consecutivePings >= maxConsecutivePings) return;
    timer = setTimeout(() => {
      timer = null;
      if (!ownsFleetLock()) return;
      try {
        // A context from a replaced session throws; the next settle schedules afresh.
        if (ctx.isIdle && !ctx.isIdle()) return;
        const tokens = ctx.getContextUsage?.()?.tokens;
        if (typeof tokens === "number" && tokens < minContextTokens) return;
        pingInFlight = true;
        pi.sendMessage(
          { customType: KEEPALIVE_MESSAGE_TYPE, content: keepaliveText, display: false },
          { triggerTurn: true },
        );
      } catch {
        pingInFlight = false;
      }
    }, idleMs);
    timer.unref();
  };

  // Poll until the limit lifts, then continue the cut turn. A session that is not
  // idle, or does not own the fleet lock, is left alone; the next settle reschedules.
  const scheduleResume = (ctx: { isIdle?: () => boolean }): void => {
    clear();
    if (!resumeEnabled || resumeAttempts >= maxResumeAttempts) return;
    timer = setTimeout(() => {
      timer = null;
      if (!ownsFleetLock()) return;
      try {
        if (ctx.isIdle && !ctx.isIdle()) return;
        if (limitStillStands()) {
          scheduleResume(ctx);
          return;
        }
        resumeAttempts += 1;
        pi.sendMessage(
          { customType: RESUME_MESSAGE_TYPE, content: resumeText, display: false },
          { triggerTurn: true },
        );
      } catch {
        // A context from a replaced session throws; the next settle schedules afresh.
      }
    }, resumePollMs);
    timer.unref();
  };

  pi.on?.("agent_start", () => {
    clear();
    // A run the ping started keeps the count; anything else is real activity.
    if (!pingInFlight) consecutivePings = 0;
  });
  pi.on?.("agent_end", (event) => {
    const cut = isUsageLimitCut((event as { messages?: unknown } | undefined)?.messages);
    if (cut === undefined) return;
    cutByLimit = cut;
    // A turn that went through ends the cut; the attempt budget starts over.
    if (!cut) resumeAttempts = 0;
  });
  pi.on?.("agent_settled", (_event, ctx) => {
    if (pingInFlight) {
      pingInFlight = false;
      consecutivePings += 1;
    }
    if (cutByLimit) scheduleResume(ctx);
    else schedule(ctx);
  });
  pi.on?.("session_shutdown", () => {
    clear();
  });
}
