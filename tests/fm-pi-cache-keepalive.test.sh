#!/usr/bin/env bash
# tests/fm-pi-cache-keepalive.test.sh - the Pi primary's prompt-cache keep-alive
# (.pi/extensions/fm-cache-keepalive.ts). Each case drives the real extension in
# node with a mock Pi and a few-millisecond idle interval, and reports how many
# keep-alive turns it asked for.
# The JavaScript case bodies below are single-quoted on purpose, template literals included.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-cache-keepalive)
EXT="$ROOT/.pi/extensions/fm-cache-keepalive.ts"
export NODE_NO_WARNINGS=1

# <case> <script-body> [env...]: the script body sees `pings` (the recorded
# sendMessage calls), `settle()` (fire agent_settled), `start()` (agent_start),
# `wait(ms)`, `endRun(messages)` (fire agent_end), and `owner` set by KEEPALIVE_OWN=no
# to drop the fleet lock.
run_keepalive() {
  local name=$1 body=$2 home
  shift 2
  home="$TMP_ROOT/$name-home"
  mkdir -p "$home/state"
  env PLUGIN="$EXT" FM_HOME="$home" FM_CACHE_KEEPALIVE_IDLE_MS=60 "$@" BODY="$body" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pings = [];
let idle = true;
let tokens = 200000;
const pi = {
  on(name, fn) { handlers.set(name, fn); },
  sendMessage(message, options) { pings.push({ message, options }); },
};
if (process.env.KEEPALIVE_OWN !== "no") writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const ctx = { isIdle: () => idle, getContextUsage: () => ({ tokens }) };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settle = () => handlers.get("agent_settled")?.({ type: "agent_settled" }, ctx);
const start = () => handlers.get("agent_start")?.({ type: "agent_start" }, ctx);
const endRun = (messages) => handlers.get("agent_end")?.({ type: "agent_end", messages }, ctx);
const wait = (ms) => new Promise((resolve) => setTimeout(() => resolve(), ms));
const setIdle = (value) => { idle = value; };
const setTokens = (value) => { tokens = value; };
const body = new Function("pings", "settle", "start", "wait", "setIdle", "setTokens", "endRun", `return (async () => { ${process.env.BODY} })();`);
try {
  await body(pings, settle, start, wait, setIdle, setTokens, endRun);
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

test_idle_session_gets_one_cheap_turn_before_the_cache_expires() {
  local out
  out=$(run_keepalive idle '
    settle();
    await wait(200);
    if (pings.length < 1) throw new Error("no keep-alive turn was requested after the idle interval");
    const ping = pings[0];
    if (ping.options?.triggerTurn !== true) throw new Error("the keep-alive must start a turn");
    if (ping.message.display !== false) throw new Error("the keep-alive must not be shown");
    if (!/Take no action and call no tool/.test(ping.message.content)) throw new Error("the keep-alive must tell the model to do nothing");
  ')
  expect_ok "idle session" "$out"
  pass "an idle primary gets a hidden keep-alive turn before the cache lifetime ends"
}

test_real_activity_cancels_the_pending_keepalive() {
  local out
  out=$(run_keepalive activity '
    settle();
    await wait(20);
    start();
    await wait(200);
    if (pings.length !== 0) throw new Error(`a session that became active still pinged ${pings.length} time(s)`);
  ')
  expect_ok "activity" "$out"
  pass "a run that starts before the interval ends cancels the keep-alive"
}

test_consecutive_pings_are_capped_and_real_activity_resets_the_cap() {
  local out
  out=$(run_keepalive cap '
    // Pi runs a ping as agent_start then agent_settled; two pings reach the cap of 2.
    settle();
    await wait(150);
    start(); settle();
    await wait(150);
    start(); settle();
    await wait(300);
    if (pings.length !== 2) throw new Error(`expected exactly the 2 capped pings, saw ${pings.length}`);
  ' FM_CACHE_KEEPALIVE_MAX_PINGS=2)
  expect_ok "cap" "$out"
  out=$(run_keepalive reset '
    settle();
    await wait(150);
    start(); settle();            // the ping run itself: counts toward the cap of 1
    await wait(300);
    if (pings.length !== 1) throw new Error(`the cap of 1 was exceeded: ${pings.length}`);
    start(); settle();            // real activity: resets the count
    await wait(150);
    if (pings.length !== 2) throw new Error(`real activity did not re-arm the keep-alive: ${pings.length}`);
  ' FM_CACHE_KEEPALIVE_MAX_PINGS=1)
  expect_ok "reset" "$out"
  pass "consecutive keep-alive turns stop at the cap and real activity resets it"
}

test_a_session_without_the_fleet_lock_never_pings() {
  local out
  out=$(run_keepalive nolock '
    settle();
    await wait(200);
    if (pings.length !== 0) throw new Error(`a worker session pinged ${pings.length} time(s)`);
  ' KEEPALIVE_OWN=no)
  expect_ok "no lock" "$out"
  pass "a session that does not own the fleet lock stays silent"
}

test_small_contexts_busy_agents_and_the_off_switch_do_not_ping() {
  local out
  out=$(run_keepalive small '
    setTokens(1000);
    settle();
    await wait(200);
    if (pings.length !== 0) throw new Error("a tiny context still pinged");
  ')
  expect_ok "small context" "$out"
  out=$(run_keepalive busy '
    setIdle(false);
    settle();
    await wait(200);
    if (pings.length !== 0) throw new Error("a busy agent still pinged");
  ')
  expect_ok "busy" "$out"
  out=$(run_keepalive off '
    settle();
    await wait(200);
    if (pings.length !== 0) throw new Error("FM_CACHE_KEEPALIVE=0 still pinged");
  ' FM_CACHE_KEEPALIVE=0)
  expect_ok "off switch" "$out"
  pass "small contexts, busy agents, and the off switch do not ping"
}

# limit_status <name> <exit-code>: a fake `fm-quota-silence.sh` whose `status` exits with the code in <dir>/code.
limit_status() {
  local dir="$TMP_ROOT/$1-status"
  mkdir -p "$dir"
  printf '%s\n' "$2" > "$dir/code"
  printf '#!/usr/bin/env bash\nexit "$(cat "%s/code")"\n' "$dir" > "$dir/status.sh"
  chmod +x "$dir/status.sh"
  printf '%s\n' "$dir"
}

test_a_turn_cut_by_the_usage_limit_is_told_to_continue_once_the_limit_lifts() {
  local out dir
  dir=$(limit_status resume 0)
  out=$(run_keepalive resume '
    endRun([{ role: "assistant", stopReason: "error", errorMessage: "You'"'"'ve hit your limit · resets 10:20am" }]);
    settle();
    await wait(300);
    if (pings.length !== 0) throw new Error(`a standing limit was probed with ${pings.length} model turn(s)`);
    // The limit lifts: the status helper now exits non-zero.
    const { writeFileSync } = await import("node:fs");
    writeFileSync(`${process.env.LIMIT_DIR}/code`, "1\n");
    await wait(300);
    if (pings.length !== 1) throw new Error(`expected one resume turn, saw ${pings.length}`);
    const ping = pings[0];
    if (ping.options?.triggerTurn !== true) throw new Error("the resume must start a turn");
    if (ping.message.customType !== "fm-limit-resume") throw new Error(`wrong message type ${ping.message.customType}`);
    if (!/Continue the work you were doing/.test(ping.message.content)) throw new Error("the resume must tell the model to continue");
    if (/Take no action/.test(ping.message.content)) throw new Error("the resume must not be the do-nothing ping");
  ' FM_LIMIT_RESUME_STATUS="$dir/status.sh" FM_LIMIT_RESUME_POLL_MS=60 LIMIT_DIR="$dir")
  expect_ok "resume" "$out"
  pass "a turn cut by the usage limit gets a continue instruction, not the do-nothing ping, once the limit lifts"
}

test_resume_attempts_are_capped_and_a_good_turn_ends_the_cut() {
  local out dir
  dir=$(limit_status cap 1)
  out=$(run_keepalive resume-cap '
    // The Claude bridge wording since 0.9.3, then the one before it.
    endRun([{ role: "assistant", stopReason: "error", errorMessage: "Claude quota exceeded — rate limit (seven_day) — resets 6:30:00 PM: refused" }]); settle();
    const cut = [{ role: "assistant", stopReason: "error", errorMessage: "Claude rate limit (five_hour): refused" }];
    await wait(200);
    start(); endRun(cut); settle();     // the resume was refused again
    await wait(200);
    start(); endRun(cut); settle();
    await wait(400);
    if (pings.length !== 2) throw new Error(`expected the 2 allowed resume turns, saw ${pings.length}`);
    // A turn that goes through ends the cut and re-arms the ordinary keep-alive.
    start(); endRun([{ role: "assistant", stopReason: "stop" }]); settle();
    await wait(200);
    if (pings.length !== 3 || !/Take no action/.test(pings[2].message.content)) throw new Error("a good turn did not return to the ordinary keep-alive");
  ' FM_LIMIT_RESUME_STATUS="$dir/status.sh" FM_LIMIT_RESUME_POLL_MS=60 FM_LIMIT_RESUME_MAX_ATTEMPTS=2)
  expect_ok "resume cap" "$out"
  pass "resume attempts are capped per cut and a turn that goes through restores the ordinary keep-alive"
}

test_ordinary_errors_and_a_session_without_the_lock_never_resume() {
  local out dir
  dir=$(limit_status other 1)
  out=$(run_keepalive other-error '
    endRun([{ role: "assistant", stopReason: "error", errorMessage: "connection reset" }]);
    settle();
    await wait(200);
    if (pings.some((p) => p.message.customType === "fm-limit-resume")) throw new Error("a non-limit error was resumed");
  ' FM_LIMIT_RESUME_STATUS="$dir/status.sh" FM_LIMIT_RESUME_POLL_MS=60)
  expect_ok "other error" "$out"
  out=$(run_keepalive resume-nolock '
    endRun([{ role: "assistant", stopReason: "error", errorMessage: "You'"'"'re out of extra usage" }]);
    settle();
    await wait(200);
    if (pings.length !== 0) throw new Error("a worker session resumed");
  ' KEEPALIVE_OWN=no FM_LIMIT_RESUME_STATUS="$dir/status.sh" FM_LIMIT_RESUME_POLL_MS=60)
  expect_ok "resume no lock" "$out"
  out=$(run_keepalive resume-off '
    endRun([{ role: "assistant", stopReason: "error", errorMessage: "You'"'"'ve hit your limit" }]);
    settle();
    await wait(200);
    if (pings.some((p) => p.message.customType === "fm-limit-resume")) throw new Error("FM_LIMIT_RESUME=0 still resumed");
  ' FM_LIMIT_RESUME=0 FM_LIMIT_RESUME_STATUS="$dir/status.sh" FM_LIMIT_RESUME_POLL_MS=60)
  expect_ok "resume off" "$out"
  pass "non-limit errors, sessions without the fleet lock, and the off switch never resume"
}

test_idle_session_gets_one_cheap_turn_before_the_cache_expires
test_real_activity_cancels_the_pending_keepalive
test_consecutive_pings_are_capped_and_real_activity_resets_the_cap
test_a_session_without_the_fleet_lock_never_pings
test_small_contexts_busy_agents_and_the_off_switch_do_not_ping
test_a_turn_cut_by_the_usage_limit_is_told_to_continue_once_the_limit_lifts
test_resume_attempts_are_capped_and_a_good_turn_ends_the_cut
test_ordinary_errors_and_a_session_without_the_lock_never_resume
