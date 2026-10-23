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
const keepaliveText =
  "Cache keep-alive ping from the harness, not from the captain or the fleet. " +
  "Take no action and call no tool. Reply with exactly: ok";

export default function (pi: ExtensionAPI) {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let pingInFlight = false;
  let consecutivePings = 0;

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

  pi.on?.("agent_start", () => {
    clear();
    // A run the ping started keeps the count; anything else is real activity.
    if (!pingInFlight) consecutivePings = 0;
  });
  pi.on?.("agent_settled", (_event, ctx) => {
    if (pingInFlight) {
      pingInFlight = false;
      consecutivePings += 1;
    }
    schedule(ctx);
  });
  pi.on?.("session_shutdown", () => {
    clear();
  });
}
