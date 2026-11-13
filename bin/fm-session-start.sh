#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/captain-shared.md, data/learnings.md, then run
# fm-lock.sh, fm-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# fm-wake-drain.sh, and fm-startup-network.sh as real subprocesses and prints
# their real output. It never re-implements their logic; all
# sequencing/formatting logic added here stays local to this file. Those four
# scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its six mutating
# sweeps - is an opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag on fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   1b. home role    - the resolved firstmate-repository role line
#                      (bin/fm-role.sh report), purely local, no network.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                       when this session actually holds the lock. Detect-only
#                       diagnostics always run. Bootstrap's six MUTATING sweeps
#                       (same-home backlog reconciliation,
#                       secondmate convergence, secondmate liveness, pending remote
#                       handoff retry, X-mode artifact writes, fleet sync) also run only when
#                       locked; the four network sweeps run in the deferred
#                       stage rather than this synchronous bootstrap section.
#   3. wake-drain     - presents durable wakes and advances recovery handling
#                       state, so it only runs when locked. The local bounded
#                       inactive-outcome startup scan runs in the deferred worker.
#                       First, on every harness and away posture, it seeds the
#                       outcome store's display tail copy when that is absent
#                       (bin/fm-branch-outcome.sh seed-tail).
#   4. supervision-instructions - the one emitted operating block for the
#                       detected primary harness.
#   5. read-once contract - the do-not-re-read contract covering every source
#                       represented by the two digests below.
#   6. fleet digest   - a compact data/backlog.md listing, one line per
#                       state/*.meta task (see COMPACT VIEWS below),
#                       the away posture (state/.afk-contract and the legacy
#                       state/.afk daemon flag), and a cheap per-task
#                       endpoint-liveness read, each bounded and crash-
#                       isolated so one task's read can never abort the
#                       digest: read-only, always runs. The per-task reads
#                       run serially, so with a wedged backend the stage's
#                       ceiling is tasks x the per-read bound
#                       (FM_SESSION_START_ENDPOINT_TIMEOUT, default 10s) and
#                       can itself reach the digest's runtime bound.
#   7. network checks - the result of the deferred network stage started back at
#                       step 1, harvested WITHOUT waiting for it.
#   8. context digest - data/projects.md, data/secondmates.md, data/captain.md,
#                       data/captain-shared.md, data/learnings.md: read-only,
#                       always safe, always runs.
#   9. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# Those ten names are also the runtime-bound stage list below, so a truncated
# startup can name exactly which of them never ran - and the parent banners
# EVERY nonzero child exit, not only the bound: a child that dies or is killed
# mid-stage must never truncate the digest silently.
#
# NO NETWORK ON THE BLOCKING PATH. This digest runs on a session-open hook that
# blocks session initialization, so anything it waits for is time the captain
# waits before the first turn - and every external-network call it used to make
# was individually unbounded. One unreachable remote secondmate could burn the
# entire FM_SESSION_START_TIMEOUT and truncate the digest, so a slow network
# could cost the work queue itself.
# So no step between here and the last line below makes an external-network
# call. The five that did - `gh auth status`, secondmate liveness, secondmate
# convergence, pending remote handoff delivery, and the fleet-sync fetch - are
# started as one detached bounded worker right after the lock (step 1) and
# harvested at step 7 without ever blocking on it. The bounded inactive-outcome
# startup scan joins that worker because its local current-state reads can also
# be slow. bin/fm-startup-network.sh owns that stage and its safety argument;
# bin/fm-bootstrap.sh and bin/fm-inactive-reconcile.sh remain the owners of the
# work itself and still run it.
# The digest is therefore composed from bounded local reads and local
# subprocesses only, while slow network or inactive-state reconciliation delays
# a reported check rather than startup.
# What this deliberately trades: on a slow network the digest prints "IN
# PROGRESS" and names exactly which checks are not yet confirmed, instead of
# waiting for them. It never reports an unconfirmed check as passed.
#
# ORDERING, and why FLEET STATE now runs before CONTEXT: this digest is
# delivered through a harness that truncates an oversized payload from the TAIL,
# and it has really been truncated in practice - a 70KB digest arrived as lines
# 1-435 of 578, cutting off eight lines before the live-task inventory. What a
# truncated tail drops must therefore be the CHEAPEST thing to lose. Curated
# memory is stable session to session, is already governed by a captain-set
# budget (config/startup-memory-budget), and is recoverable with one targeted
# read; live fleet identity - which tasks exist, their windows, worktrees,
# backends, and endpoint liveness - changes every session and is exactly what
# recovery depends on. So fleet state goes first and the memory files absorb the
# truncation. The read-once contract moves ahead of both for the same reason: a
# contract that only arrives after the payload it governs is the first thing a
# truncated digest loses, and it carries the truncation caveat that keeps it
# honest when a stage below it never ran.
# The LOCK/BOOTSTRAP/WAKE-QUEUE safety preamble keeps its order: it establishes
# mutation authority and this turn's work queue before anything else is read.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - converging
# secondmate homes, retrying pending handoff outboxes and receiver wakes, writing
# X-mode artifacts, and fetching or fast-forwarding every project clone - before
# ever discovering another session already holds the lock. Two sessions racing
# those sweeps is exactly the hazard the lock exists to prevent, so locking first closes the
# hole outright: only the session that actually wins the lock ever touches
# shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its local read-only detect lines - missing tools, the worktree-tangle
# check, the harness override, crew-dispatch validation, tasks-axi and quota-axi
# tool checks, and tasks-axi availability - none of which mutate shared state
# and all of which are safe to compute without verified lock ownership.
# It deliberately skips the network-only GitHub-auth probe because a read-only
# session has no dispatch, spawn, steer, or merge action for that verdict to gate.
# Only projection cleanup, the six bootstrap mutating sweeps, and wake-queue
# presentation are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: the startup listing is a RECOVERY input, not a reporting
# surface, so it carries what this turn can act on and nothing else.
#   - `done` rows are never listed. Retained completion history belongs to the
#     reporting surfaces (bin/fm-bearings-snapshot.sh, /ahoy), and at startup it
#     is pure weight - 10 done rows cost 3.3KB in an observed main-home digest.
#   - Every in-flight, held, and blocked row is listed, with its hold_kind/
#     hold_reason and blocked_by. Those are the rows AGENTS.md sections 7 and
#     10 make actionable at startup, so they are never bounded away; the
#     compact view (COMPACT VIEWS below) only shortens their text.
#   - Only the plain queued (dispatchable-now) listing is bounded, by
#     FM_SESSION_START_QUEUED_LIMIT, default 20. Anything it omits is disclosed
#     with an exact remainder count and the command that shows the rest, so a
#     deep queue costs a counter rather than kilobytes.
#     (This replaces FM_SESSION_START_BACKLOG_LIMIT, which bounded the whole
#     listing indiscriminately and so could drop a held or blocked row.)
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script asks
# `tasks-axi list` for the compact identity fields plus blocked_by, hold_kind,
# and hold_reason, never body. The groups are the tool's own filters
# (`--state in_flight`, `--state held`, `--state queued --blocked`, and
# `tasks-axi ready`), so this script never reimplements task state; the groups
# can overlap, because an in-flight item that is also held appears under both.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest; the same never-bound-a-held-or-blocked-row
# rule applies, recognized there from the title line's own hold/blocked-by
# markers.
# Full bodies are targeted follow-up only: `bin/fm-tasks-axi.sh show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# STATUS TAILS (full task view): FM_SESSION_START_STATUS_TAIL bounds how many
# lines each task's tail prints, and bin/fm-line-cap-lib.sh bounds how long each
# of those lines may be. Both bounds are safe because the section prints every
# task's full status log path, and AGENTS.md section 8 treats a status line as a
# wake EVENT rather than current state - bin/fm-crew-state.sh owns current state.
# ORPHAN STATUS LOGS (no matching .meta) are listed only while they hold an
# open decision or their newest event is inside FM_SESSION_START_ORPHAN_DAYS
# (default 3); every older one is counted in a single line.
#
# COMPACT VIEWS: a context re-emit reprints this digest after every compaction,
# so each bulky block prints what a turn acts on and leaves the rest one command
# away. Each block has its own switch, each switch falls back to
# FM_SESSION_START_VIEW, and only the exact word `full` restores that block's
# previous long form; anything else keeps it compact.
#   FM_SESSION_START_TASK_VIEW - Work under way and listed orphan logs print one
#     line per task: id, kind, delivery mode, yolo, remote host, endpoint
#     liveness (ep=), open=N when N decisions or blockers are still open, and the
#     newest status line that is not pending-reply bookkeeping (capped), plus a
#     pr= line. The full record stays in state/<id>.meta and state/<id>.status.
#     A locked digest lists every open decision in the drain's OPEN DECISIONS
#     section; a read-only one, which runs no drain, lists them under the task.
#   FM_SESSION_START_BACKLOG_VIEW - the tasks-axi listing caps titles and hold
#     reasons, carries an in-flight item's hold on its in-flight row instead of
#     repeating the row under held, and counts the dispatchable rows in one line
#     unless FM_SESSION_START_QUEUED_LIMIT asks for that many of them. Full rows:
#     bin/fm-tasks-axi.sh show <id> --full and bin/fm-tasks-axi.sh ready.
#   FM_SESSION_START_SECONDMATES_VIEW - data/secondmates.md prints one line per
#     route (id, host, capped routing scope); the charters stay in the file.
#   FM_SESSION_START_SUPERVISION_VIEW - a Pi-family context re-emit renders the
#     compact supervision block (fm-supervision-instructions.sh --compact 1),
#     which names the command that prints the full protocol.
#   FM_SESSION_START_FRAME_VIEW - the RE-EMIT CUE is left out on a Pi-family
#     harness, which delivers the digest as its own message and marks a cut;
#     the re-emit header and the read-once contract are one paragraph each; and
#     a Pi-family re-emit's NEXT STEP is one line.
#   FM_SESSION_START_LEARNINGS_VIEW - after a compaction (a re-emit that is not a
#     /clear), data/learnings.md prints one capped line per item and names the
#     file for the full text; the first start of a session, a /clear, and a bare
#     read keep the full file. The compaction summary and the system prompt carry
#     what the learnings taught, the file keeps the detail, and this digest is
#     reread by every later request. The captain preference files, the held
#     backlog rows, and every open decision stay whole.
# A memory budget overrun (bin/fm-startup-memory-budget.sh report) adds one
# STARTUP_MEMORY line to the bootstrap section while it lasts.
#
# RUNTIME BOUND: the digest is now executed through a native session-open
# adapter (see bin/fm-sessionstart-run.sh), which blocks either hook-driven
# session initialization or Pi's first provider preflight while it runs, so an
# unbounded digest is no longer merely slow - it can strand a whole session or
# first turn behind one hung subprocess. Every remaining step is local, but
# local is not the same as bounded: tool version probes and the backlog
# listing are unbounded subprocesses, while each per-task endpoint read runs
# in its own crash-isolated child under FM_SESSION_START_ENDPOINT_TIMEOUT
# (default 10s). So the whole digest still runs as ONE bounded child of this
# script (FM_SESSION_START_TIMEOUT, default 120s). The deferred network stage
# deliberately sits OUTSIDE that bound,
# in its own process group under its own aggregate deadline, so a truncated
# digest neither waits for it nor orphans it unbounded. The
# child writes the digest straight to this script's stdout, so everything it
# emitted before the child stopped is already delivered; the parent then prints
# a loud STARTUP TRUNCATED banner on ANY nonzero child exit - the runtime bound
# or an unexpected child death, named with its exit status - naming the stage
# that did not finish and the sections that were therefore never emitted, and
# still exits 0. The child
# records its progress in FM_SESSION_START_STAGE_FILE, which is also the flag
# that tells a child it is the child - the parent never recurses.
# Two things keep one slow part from costing the rest. A context re-emit prints
# bin/fm-fleet-card.sh first, outside that bound (FM_SESSION_START_FLEET_CARD=0
# removes it; FM_SESSION_START_CARD_TIMEOUT bounds it), so the state a compaction
# cannot carry survives a truncation. And the wake-queue drain has its own stage
# bound, FM_SESSION_START_DRAIN_TIMEOUT (default 45s, 0 removes it): a drain that
# hits it is disclosed, leaves every row queued and unacknowledged, and the later
# stages still run inside the whole-digest bound.
# Hosts without timeout, gtimeout, or perl use the shared pure-Bash watchdog, so
# the digest never runs without the same hard bound and process-group cleanup.
#
# Usage: fm-session-start.sh [--reemit] [--source <source>]
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
#
#   --reemit  This process ALREADY took the helm at its own startup and has
#             only lost its context (a /clear or a compaction). Skip the
#             mutating sweeps that startup already reconciled - the stale Herdr
#             projection cleanup and bootstrap's six mutating sweeps (fleet
#             sync, same-home backlog reconciliation, secondmate convergence and
#             liveness, pending remote handoff retry, X-mode
#             artifact writes) - and
#             re-emit the rest. Wake-queue presentation is NOT skipped: queued
#             records are this turn's work queue, they arrived after startup,
#             and a session that owns the lock is exactly the session that must
#             handle and acknowledge them. Lock acquisition still runs, because
#             ownership must be re-verified rather than assumed: fm-lock.sh
#             already treats a lock owned through shared ancestry or a trusted
#             same-session Claude id as its own, so the re-emit proceeds, while
#             a lock another live session took meanwhile still produces the
#             ordinary read-only path. A re-emit prints a short RE-EMIT CUE
#             first, so a harness that spills a large output and shows only its
#             head still tells the model to read the saved full output; a
#             Pi-family harness never spills it, so the compact frame view
#             leaves the cue out there.
#
#   --source  The native session-open source, supplied only by
#             fm-sessionstart-run.sh. A genuine `startup` that owns the active
#             session lock records AGENTS.md's SHA-256 baseline only after the
#             digest completion record is published, keyed to that lock's
#             harness pid. No resume, clear, reset, compact, or other rebuild
#             creates or replaces it, except by the age proof below. Pi and pi-signed compaction are the only
#             supported stale-cache rebuild pair: a missing baseline, a baseline
#             for another harness pid, or a changed hash causes the complete
#             current AGENTS.md to print before the bulky digest. The baseline
#             remains immutable so every later drifted compaction refreshes
#             again, while an equal baseline emits no instruction refresh. A
#             process with no baseline of its own whose start is later than
#             AGENTS.md's last change already read the current file at start,
#             so it gets no refresh and that file becomes its baseline; a file
#             changed after the process started is still delivered.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
COMPLETION_FILE="$STATE/.session-start-complete"
AGENTS_BASELINE_FILE="$STATE/.session-start-agents-baseline"

REEMIT=0
SESSION_SOURCE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reemit)
      REEMIT=1
      shift
      ;;
    --source)
      SESSION_SOURCE=${2:-}
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*)
      SESSION_SOURCE=${1#--source=}
      shift
      ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-session-start.sh" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'fm-session-start: unknown argument: %s\n' "$1" >&2
      printf 'usage: fm-session-start.sh [--reemit] [--source <source>]\n' >&2
      exit 2
      ;;
  esac
done

# --- 0. runtime bound ---------------------------------------------------------
# The ordered stage list is the contract behind the truncation banner: the child
# names the stage it is entering, and the parent reports every stage at or after
# that one as never emitted. Keep it in the exact order the digest prints.
SESSION_START_STAGES='lock role bootstrap wake-queue supervision-instructions read-once fleet-state network-checks context next-step'

stage() {  # <stage-name>: breadcrumb for the parent's truncation banner
  [ -n "${FM_SESSION_START_STAGE_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$FM_SESSION_START_STAGE_FILE" 2>/dev/null || true
}

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ -z "${FM_SESSION_START_STAGE_FILE:-}" ]; then
  SESSION_START_BUDGET=${FM_SESSION_START_TIMEOUT:-120}
  # A non-positive or non-numeric budget is not a budget (`timeout 0` disables
  # the deadline outright), so an unusable value falls back to the default
  # rather than silently removing the bound.
  case "$SESSION_START_BUDGET" in ''|*[!0-9]*) SESSION_START_BUDGET=120 ;; esac
  [ "$SESSION_START_BUDGET" -gt 0 ] 2>/dev/null || SESSION_START_BUDGET=120
  SESSION_START_STAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-session-start-stage.XXXXXX" 2>/dev/null) || SESSION_START_STAGE_FILE=
  if [ -z "$SESSION_START_STAGE_FILE" ]; then
    # Without a breadcrumb the bound still holds; only the banner's precision
    # is lost, so the child still runs bounded.
    SESSION_START_STAGE_FILE=/dev/null
  fi
  # A context re-emit prints the fleet card FIRST, outside the bounded child
  # (bin/fm-fleet-card.sh: plain files, no lock, a fixed process count), so the
  # state a compaction summary cannot carry arrives even when a later stage is
  # cut by the bound below. Its own short bound keeps it from ever being the slow
  # stage; FM_SESSION_START_FLEET_CARD=0 restores the digest without a card.
  if [ "$REEMIT" -eq 1 ] && [ "${FM_SESSION_START_FLEET_CARD:-1}" != 0 ] && [ -x "$SCRIPT_DIR/fm-fleet-card.sh" ]; then
    CARD_BOUND=${FM_SESSION_START_CARD_TIMEOUT:-10}
    case "$CARD_BOUND" in ''|*[!0-9]*) CARD_BOUND=10 ;; esac
    [ "$CARD_BOUND" -gt 0 ] 2>/dev/null || CARD_BOUND=10
    fm_run_timed "$CARD_BOUND" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-fleet-card.sh"
    CARD_RC=$?
    [ "$CARD_RC" -eq 0 ] || printf 'FLEET CARD UNAVAILABLE (exit %s); the digest below is the whole record.\n' "$CARD_RC"
    printf '\n'
  fi
  if [ "$REEMIT" -eq 1 ]; then
    if [ -n "$SESSION_SOURCE" ]; then
      fm_run_timed "$SESSION_START_BUDGET" \
        env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/fm-session-start.sh" --reemit --source "$SESSION_SOURCE"
    else
      fm_run_timed "$SESSION_START_BUDGET" \
        env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/fm-session-start.sh" --reemit
    fi
  elif [ -n "$SESSION_SOURCE" ]; then
    fm_run_timed "$SESSION_START_BUDGET" \
      env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/fm-session-start.sh" --source "$SESSION_SOURCE"
  else
    fm_run_timed "$SESSION_START_BUDGET" \
      env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/fm-session-start.sh"
  fi
  SESSION_START_RC=$?
  # ANY nonzero child exit is a truncation: the banner contract promises that
  # a stage that cannot print is named. Exit 124 is the bound firing; any
  # other status means the child died or was killed mid-stage, which truncates
  # silently when unbanned - the parent must banner it, never exit 0 around it.
  if [ "$SESSION_START_RC" -ne 0 ]; then
    SESSION_START_LAST_STAGE=$(cat "$SESSION_START_STAGE_FILE" 2>/dev/null) || SESSION_START_LAST_STAGE=
    [ -n "$SESSION_START_LAST_STAGE" ] || SESSION_START_LAST_STAGE=unknown
    SESSION_START_PENDING=$(
      printf '%s\n' "$SESSION_START_STAGES" | tr ' ' '\n' |
        awk -v from="$SESSION_START_LAST_STAGE" '$0 == from {seen = 1} seen' | tr '\n' ' '
    )
    [ -n "${SESSION_START_PENDING# }" ] || SESSION_START_PENDING='(unknown - the digest may be incomplete anywhere)'
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '\n%s\n' "$BAR"
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  STARTUP TRUNCATED - SESSION START HIT ITS %ss RUNTIME BOUND\n' "$SESSION_START_BUDGET"
    else
      printf '●  STARTUP TRUNCATED - SESSION START DIED UNEXPECTEDLY (exit %s, not its runtime bound)\n' "$SESSION_START_RC"
    fi
    printf '●  It stopped during the "%s" stage, so everything above is COMPLETE\n' "$SESSION_START_LAST_STAGE"
    printf '●  only up to that point.\n'
    printf '●  RECONCILE these stages before acting on anything they would have shown:\n'
    printf '●    %s\n' "${SESSION_START_PENDING% }"
    printf '●  Rerun bin/fm-session-start.sh now to finish taking the helm. If it truncates\n'
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  again, raise FM_SESSION_START_TIMEOUT and report the slow stage - a stage that\n'
      printf '●  cannot finish inside the bound is a fleet problem, not a reporting detail.\n'
    else
      printf '●  again, report the exit status and the stage - raising the runtime bound\n'
      printf '●  cannot help a digest that died, and a stage that dies is a fleet problem.\n'
    fi
    printf '%s\n' "$BAR"
  fi
  rm -f "$SESSION_START_STAGE_FILE" 2>/dev/null || true
  exit 0
fi

PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

# One tasks-axi compatibility verdict per session start. The probe costs three
# tasks-axi subprocesses and this digest needs the same answer twice - here for
# the backlog listing and again inside the fm-bootstrap.sh child, which reports
# an incompatible build as OUTDATED. Computing it once and handing it, with the
# reason behind it, to that child collapses six subprocesses to three; the reason
# travels too so the child's OUTDATED requirement text names a missing capability
# without running the child's own `--help` probes over again. fm-tasks-axi-lib.sh
# owns both reuse layers and the one-hop consumption rule that keeps them out of
# any agent's environment.
if fm_tasks_axi_compatible; then TASKS_AXI_COMPATIBLE=1; else TASKS_AXI_COMPATIBLE=0; fi
TASKS_AXI_CHECK_REASON=$(fm_tasks_axi_check_reason)

STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac
ORPHAN_DAYS=${FM_SESSION_START_ORPHAN_DAYS:-3}
case "$ORPHAN_DAYS" in ''|*[!0-9]*) ORPHAN_DAYS=3 ;; esac
QUEUED_LIMIT=${FM_SESSION_START_QUEUED_LIMIT:-20}
case "$QUEUED_LIMIT" in ''|*[!0-9]*|0) QUEUED_LIMIT=20 ;; esac
# The compact tasks-axi view lists dispatchable rows only when a count is asked for.
QUEUED_LIMIT_ASKED=0
case "${FM_SESSION_START_QUEUED_LIMIT:-}" in
  ''|*[!0-9]*) ;;
  *) [ "$FM_SESSION_START_QUEUED_LIMIT" -gt 0 ] && QUEUED_LIMIT_ASKED=1 ;;
esac
# COMPACT VIEWS (header): each block's switch falls back to FM_SESSION_START_VIEW,
# and only the exact word `full` restores that block's long form.
VIEW_DEFAULT=${FM_SESSION_START_VIEW:-compact}
view_of() {  # <variable> <block-switch-value>
  case "${2:-$VIEW_DEFAULT}" in full) printf -v "$1" full ;; *) printf -v "$1" compact ;; esac
}
view_of TASK_VIEW "${FM_SESSION_START_TASK_VIEW:-}"
view_of BACKLOG_VIEW "${FM_SESSION_START_BACKLOG_VIEW:-}"
view_of SECONDMATES_VIEW "${FM_SESSION_START_SECONDMATES_VIEW:-}"
view_of SUPERVISION_VIEW "${FM_SESSION_START_SUPERVISION_VIEW:-}"
view_of FRAME_VIEW "${FM_SESSION_START_FRAME_VIEW:-}"
view_of LEARNINGS_VIEW "${FM_SESSION_START_LEARNINGS_VIEW:-}"
# Only a compaction has a summary to lean on: a first start and a /clear keep the full file.
{ [ "$REEMIT" -eq 1 ] && [ "$SESSION_SOURCE" != clear ]; } || LEARNINGS_VIEW=full
LEARNINGS_LINE_CAP=160
PI_FAMILY=0
case "$PRIMARY_HARNESS" in pi|pi-signed) PI_FAMILY=1 ;; esac
# One per-task endpoint read may never outlive this bound: a hung backend CLI
# becomes that task's endpoint: error line instead of the digest's whole
# runtime budget.
ENDPOINT_TIMEOUT=${FM_SESSION_START_ENDPOINT_TIMEOUT:-10}
case "$ENDPOINT_TIMEOUT" in ''|*[!0-9]*) ENDPOINT_TIMEOUT=10 ;; esac
[ "$ENDPOINT_TIMEOUT" -gt 0 ] 2>/dev/null || ENDPOINT_TIMEOUT=10
BACKLOG_FIELDS=blocked_by,hold_kind,hold_reason

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (captain.md absent = firstmate
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present
# file, so the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

# print_secondmates_compact <path>: one line per route, from the shared registry
# parser (bin/fm-secondmate-registry-lib.sh): id, SSH host or local, and the
# routing scope capped by the shared line cap. A line that is not a route record
# prints capped, so nothing in the file is silently dropped.
print_secondmates_compact() {
  local path=$1 line
  subsection "data/secondmates.md - one line per second mate (full charters: data/secondmates.md - read before routing work to a second mate, relaunching, or retiring one)"
  [ -f "$path" ] || { printf 'ABSENT\n'; return 0; }
  [ -s "$path" ] || { printf '(present, empty)\n'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    if secondmate_registry_parse_line "$line"; then
      fm_cap_line_var "$SECONDMATE_REGISTRY_SCOPE" 140
      printf -- '- %s (%s): %s\n' "$SECONDMATE_REGISTRY_ID" "${SECONDMATE_REGISTRY_HOST:-local}" "$FM_LINE_CAP_LINE"
    else
      fm_cap_line "$line" 140
    fi
  done < "$path"
}

# print_learnings_compact <path>: one line per non-blank line of the file, headings
# and comments included, each capped by the shared line cap. The full text stays
# in the file, named in the label, so nothing is dropped without a pointer.
print_learnings_compact() {
  local path=$1 line items=0 cut=0
  subsection "data/learnings.md - one capped line per item (full text: $path - open it before acting on a topic named here)"
  [ -f "$path" ] || { printf 'ABSENT\n'; return 0; }
  [ -s "$path" ] || { printf '(present, empty)\n'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    items=$((items + 1))
    fm_cap_line_var "$line" "$LEARNINGS_LINE_CAP"
    [ "$FM_LINE_CAP_LINE" = "$line" ] || cut=$((cut + 1))
    printf '%s\n' "$FM_LINE_CAP_LINE"
  done < "$path"
  printf '(%s line(s), %s cut at %s characters)\n' "$items" "$cut" "$LEARNINGS_LINE_CAP"
}

print_backlog_pointer() {
  printf 'Full task bodies remain available on demand: bin/fm-tasks-axi.sh show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}

# A queued title line whose own text already marks it held or blocked. The
# manual renderer has no task model, so this is the only signal it gets, and it
# is the one tasks-axi's markdown backend writes: "(hold: ...)", "(hold-kind:
# ...)", and "blocked-by: ...". Bracket expressions rather than backslashes,
# because awk's -v applies escape processing before the regex is ever compiled.
MANUAL_KEEP_RE='[(]hold|blocked-by:'

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to %s; indented task bodies omitted)\n' \
    "$reason" "$QUEUED_LIMIT"
  awk -v max="$QUEUED_LIMIT" -v keep_re="$MANUAL_KEEP_RE" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      # The Done heading is recognized so its items are skipped, never printed.
      if (state != "" && state != "done") print $0
      next
    }
    state == "in_flight" && /^[-*][[:space:]]+/ { in_flight++; print $0; next }
    state == "done" && /^[-*][[:space:]]+/ { done_total++; next }
    state == "queued" && /^[-*][[:space:]]+/ {
      queued_total++
      if ($0 ~ keep_re) { gated++; print $0; next }
      if (plain_shown < max) { plain_shown++; print $0 }
      next
    }
    END {
      plain_total = queued_total - gated
      if (in_flight + queued_total + done_total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d in-flight, %d held or blocked queued, %d of %d other queued title line(s); %d done row(s) omitted)\n", \
          in_flight, gated, plain_shown, plain_total, done_total
        if (plain_total > plain_shown) {
          printf "(%d more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)\n", plain_total - plain_shown
        }
      }
    }
  ' "$path" | fm_hold_reason_decode_stream markdown
}

# tasks-axi closes every listing with its own help block. This section composes
# four listings, so keeping them would repeat the same pointers four times, once
# per group, each carrying this home's full backlog path. The section prints one
# equivalent pointer of its own (print_backlog_pointer), so the per-group help
# blocks stop at their `help[` header instead.
strip_axi_help() {
  awk '/^help\[/ { exit } { print }'
}

# Bound the dispatchable-now listing without rewriting the tool's own rendering:
# `tasks-axi ready` rows are the indented lines under its ready[N]{...} header,
# and every other line it prints (its count, its public-followup line) passes
# through untouched. Whatever is cut is disclosed exactly.
print_ready_queued_bounded() {
  local ready=$1
  printf '%s\n' "$ready" | awk -v max="$QUEUED_LIMIT" '
    /^help\[/ { exit }
    /^ready\[/ { rows = 1; print; next }
    rows && /^[[:space:]]/ {
      total++
      if (shown < max) { print; shown++ }
      next
    }
    { rows = 0; print }
    END {
      if (total > 0) {
        printf "(shown %d of %d ready queued item(s))\n", shown, total
        if (total > shown) {
          printf "(%d more queued - bin/fm-tasks-axi.sh ready)\n", total - shown
        }
      }
    }
  '
}

# toon_rows_fields: the indented rows of tasks-axi TOON listings on stdin, one
# record per row with the unit separator between id, state, kind, repo, title,
# blocked_by, hold_kind, and hold_reason, in that order whatever order the
# listing's own field header uses. A quoted field is a JSON string; a title that
# tasks-axi itself cut keeps its first line, so its cut notice is dropped.
toon_rows_fields() {
  perl -MJSON::PP -e '
    use strict;
    use warnings;
    binmode STDIN, ":encoding(UTF-8)";
    binmode STDOUT, ":encoding(UTF-8)";
    my $json = JSON::PP->new->allow_nonref;
    my @names;
    while (my $line = <STDIN>) {
      chomp $line;
      if ($line =~ /^[a-z_]+\[\d+\]\{([^}]*)\}:$/) { @names = split /,/, $1; next; }
      if ($line !~ /^  (.*)$/) { @names = () if $line =~ /^[a-z_]/; next; }
      next unless @names;
      my ($rest, @values) = ($1);
      while (length $rest) {
        if ($rest =~ s/^("(?:[^"\\]|\\.)*")(?:,|$)//) {
          push @values, eval { $json->decode($1) } // $1;
        } elsif ($rest =~ s/^([^,]*)(?:,|$)//) {
          push @values, $1;
        } else {
          last;
        }
      }
      my %row;
      @row{@names} = @values;
      $row{title} = (split /\n/, $row{title} // "")[0] // "";
      print join("\x1f", map { my $v = $row{$_} // ""; $v =~ s/[\x1f\r\n\t]+/ /g; $v }
        qw(id state kind repo title blocked_by hold_kind hold_reason)), "\n";
    }
  '
}

# compact_backlog_group <toon-listing> <skip-ids> [<limit>]: one row line per
# listed task, title capped at 70 and hold reason at 150 characters by the shared
# line cap, into COMPACT_GROUP_ROWS; rows whose id is in the space-separated
# <skip-ids> are left out, and <limit> (0 = none) bounds the rows kept.
# COMPACT_GROUP_TOTAL counts every row not skipped, COMPACT_GROUP_SHOWN the kept
# ones, and COMPACT_GROUP_IDS names them all.
compact_backlog_group() {
  local skip=" ${2:-} " limit=${3:-0} id state kind repo title blocked hold_kind hold_reason row
  COMPACT_GROUP_ROWS=
  COMPACT_GROUP_TOTAL=0
  COMPACT_GROUP_SHOWN=0
  COMPACT_GROUP_IDS=
  while IFS=$'\x1f' read -r id state kind repo title blocked hold_kind hold_reason; do
    [ -n "$id" ] || continue
    case "$skip" in *" $id "*) continue ;; esac
    COMPACT_GROUP_TOTAL=$((COMPACT_GROUP_TOTAL + 1))
    COMPACT_GROUP_IDS="$COMPACT_GROUP_IDS $id"
    [ "$limit" -le 0 ] || [ "$COMPACT_GROUP_SHOWN" -lt "$limit" ] || continue
    fm_cap_line_var "$title" 70
    row="  $id ${kind:--} ${repo:--} $FM_LINE_CAP_LINE"
    case "$hold_kind" in
      ''|-|none) ;;
      *)
        fm_cap_line_var "$hold_reason" 150
        row="$row | held $hold_kind: $FM_LINE_CAP_LINE"
        ;;
    esac
    case "$blocked" in ''|-|none) ;; *) row="$row | blocked by $blocked" ;; esac
    COMPACT_GROUP_ROWS="$COMPACT_GROUP_ROWS$row"$'\n'
    COMPACT_GROUP_SHOWN=$((COMPACT_GROUP_SHOWN + 1))
  done < <(printf '%s\n' "$1" | toon_rows_fields)
}

# The compact tasks-axi listing (COMPACT VIEWS in the header): every in-flight,
# held, and blocked row stays, shortened; an in-flight item's hold rides on its
# in-flight row instead of repeating it under held; the dispatchable rows are
# one count line unless FM_SESSION_START_QUEUED_LIMIT asks for some of them.
print_backlog_tasks_axi_short() {  # <in-flight> <held> <blocked> <ready>
  local in_flight_ids followups
  printf 'compact backlog (tasks-axi; done rows omitted; titles capped at 70 and hold reasons at 150 characters):\n'
  compact_backlog_group "$1" ''
  in_flight_ids=$COMPACT_GROUP_IDS
  printf 'in flight (%s):\n%s' "$COMPACT_GROUP_TOTAL" "$COMPACT_GROUP_ROWS"
  compact_backlog_group "$2" "$in_flight_ids"
  printf 'held queued (%s):\n%s' "$COMPACT_GROUP_TOTAL" "$COMPACT_GROUP_ROWS"
  compact_backlog_group "$3" ''
  printf 'blocked queued (%s):\n%s' "$COMPACT_GROUP_TOTAL" "$COMPACT_GROUP_ROWS"
  if [ "$QUEUED_LIMIT_ASKED" -eq 1 ]; then
    compact_backlog_group "$4" '' "$QUEUED_LIMIT"
    printf 'ready queued (shown %s of %s; bin/fm-tasks-axi.sh ready lists them all):\n%s' \
      "$COMPACT_GROUP_SHOWN" "$COMPACT_GROUP_TOTAL" "$COMPACT_GROUP_ROWS"
  else
    compact_backlog_group "$4" '' 1
    printf 'ready queued: %s item(s) - run bin/fm-tasks-axi.sh ready at the next heartbeat or after a cleanup (AGENTS.md section 10); full rows: bin/fm-tasks-axi.sh show <id> --full\n' \
      "$COMPACT_GROUP_TOTAL"
  fi
  # Public follow-ups are never dispatchable; a pending one is a signal, a zero is not.
  followups=$(printf '%s\n' "$4" | awk '/^ready_public_followups:/ && $2 != "0"')
  [ -z "$followups" ] || printf '%s\n' "$followups"
}

print_backlog_tasks_axi_compact() {
  local path=$1 in_flight held blocked ready err
  if ! in_flight=$(tasks-axi list --file "$path" --state in_flight --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$in_flight
  elif ! held=$(tasks-axi list --file "$path" --state held --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$held
  elif ! blocked=$(tasks-axi list --file "$path" --state queued --blocked --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$blocked
  elif ! ready=$(tasks-axi ready --file "$path" 2>&1); then
    err=$ready
  elif [ "$BACKLOG_VIEW" = compact ]; then
    print_backlog_tasks_axi_short \
      "$(printf '%s\n' "$in_flight" | fm_hold_reason_decode_stream)" \
      "$(printf '%s\n' "$held" | fm_hold_reason_decode_stream)" \
      "$(printf '%s\n' "$blocked" | fm_hold_reason_decode_stream)" \
      "$ready"
    # Its ready line already names the full-row command.
    BACKLOG_POINTER_SHOWN=1
    return 0
  else
    printf 'compact backlog listing (tasks-axi; done rows omitted; every in-flight, held, and blocked row shown in full; ready queued bounded to %s; task bodies omitted)\n' \
      "$QUEUED_LIMIT"
    printf '\nin flight:\n'
    printf '%s\n' "$in_flight" | fm_hold_reason_decode_stream | strip_axi_help
    printf '\nheld (captain- or time-gated; an in-flight item that is also held appears in both groups):\n'
    printf '%s\n' "$held" | fm_hold_reason_decode_stream | strip_axi_help
    printf '\nblocked queued:\n'
    printf '%s\n' "$blocked" | fm_hold_reason_decode_stream | strip_axi_help
    printf '\nready queued (dispatchable now):\n'
    print_ready_queued_bounded "$ready"
    return 0
  fi
  printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
  printf '%s\n' "$err"
  print_backlog_manual_compact "$path" "fallback"
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      [ "${BACKLOG_POINTER_SHOWN:-0}" -eq 1 ] || print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1 line
  printf 'status tail (last %s line(s), each capped at %s characters, wake-EVENT history, not current state; full log: %s):\n' \
    "$STATUS_TAIL" "$FM_LINE_CAP_DEFAULT" "$status"
  # A crewmate writes its own status lines, so their length is unbounded: one
  # observed line ran 865 characters. Cap each one the way the wake digest's
  # OPEN DECISIONS section does; the lede carries the state word and the key,
  # and the full log path above reaches the rest.
  while IFS= read -r line || [ -n "$line" ]; do
    fm_cap_line "$line"
  done < <(tail -n "$STATUS_TAIL" "$status")
}

# newest_task_event <status-file>: the newest status line that is not
# pending-reply bookkeeping. A record under a reserved key (bin/fm-classify-lib.sh)
# tracks a request this home sent, not something the task did; one still open is
# counted by open=N and listed by OPEN DECISIONS, and a closed one is history.
newest_task_event() {
  local keys='' prefix
  for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    keys="$keys${keys:+|}$prefix"
  done
  if [ -z "$keys" ]; then
    grep -v -E '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1
    return 0
  fi
  grep -v -E -e '^[[:space:]]*$' -e "^[^:[]*(\\[[^]]*\\][[:space:]]*)*\\[key=($keys)" "$1" 2>/dev/null | tail -n 1
}

# print_task_line <id> <meta-file-or-empty> <endpoint-word-or-empty> <status-file> [<open-set>]
# One task in the compact task view (COMPACT VIEWS in the header). <open-set> is
# the decision fold's "<key>\t<verb>\t<note>" lines; when it is not given it comes
# from the cursor-backed fold, which the drain above has just brought up to date.
print_task_line() {
  local id=$1 meta=$2 ep=$3 status=$4 open line kind='' mode='' yolo='' host='' pr='' last='' n=0 key verb note
  line=$id
  if [ -n "$meta" ]; then
    kind=$(fm_meta_get "$meta" kind)
    mode=$(fm_meta_get "$meta" mode)
    yolo=$(fm_meta_get "$meta" yolo)
    host=$(fm_meta_get "$meta" remote_host)
    pr=$(fm_meta_get "$meta" pr)
    line="$line ${kind:-?}"
    [ -z "$mode" ] || [ "$mode" = "$kind" ] || line="$line $mode"
    [ -z "$yolo" ] || line="$line yolo=$yolo"
    [ -z "$host" ] || line="$line host=$host"
  fi
  [ -z "$ep" ] || line="$line ep=$ep"
  if [ "$#" -ge 5 ]; then
    open=$5
  else
    open=$(status_open_decisions_incremental "$status" 2>/dev/null || true)
  fi
  while IFS= read -r key; do
    [ -z "$key" ] || n=$((n + 1))
  done <<EOF
$open
EOF
  [ "$n" -eq 0 ] || line="$line open=$n"
  [ ! -f "$status" ] || last=$(newest_task_event "$status")
  fm_cap_line_var "${last:-no status event yet}" 200
  printf '%s | %s\n' "$line" "$FM_LINE_CAP_LINE"
  [ -z "$pr" ] || printf '  pr=%s\n' "$pr"
  # A read-only digest runs no drain, so it has no OPEN DECISIONS section.
  [ "$READ_ONLY" -eq 1 ] && [ "$n" -gt 0 ] || return 0
  while IFS=$'\t' read -r key verb note; do
    [ -n "$verb" ] || continue
    fm_cap_line_var "open: $verb [key=$key]: $note" 200
    printf '  %s\n' "$FM_LINE_CAP_LINE"
  done <<EOF
$open
EOF
}

# fm_session_start_endpoint_read <backend> <target> [expected-label]: ONE
# bounded, crash-isolated endpoint-liveness read. The read runs in its own
# bash under fm_run_timed's bound instead of in this digest process, because
# a per-task backend liveness read that dies mid-read would otherwise take
# every later stage with it. Isolation turns any death, hang, or nonzero
# surprise in one task's read into that task's own endpoint line - never a
# silently missing rest of digest. The inner bash re-sources fm-backend.sh
# per read; that cost is a few milliseconds per task and buys the isolation.
fm_session_start_endpoint_read() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 label=${3:-}
  # shellcheck disable=SC2016  # Positional parameters expand inside the child bash, not here.
  fm_run_timed "$ENDPOINT_TIMEOUT" bash -c '
    . "$1"
    fm_backend_target_exists "$2" "$3" "$4"
  ' _ "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" "$label"
}

hash_file_sha256() {
  local file=$1 digest
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  return 1
}

# The baseline describes instructions this true session started with, not the
# most recently emitted instructions. It is intentionally immutable for this
# lock owner: every later stale-context rebuild needs the current file again.
write_agents_baseline() {  # <lock-pid> <agents-hash>
  local lock_pid=$1 agents_hash=$2 tmp
  [ -n "$lock_pid" ] && [ -n "$agents_hash" ] || return 1
  tmp=$(mktemp "$STATE/.session-start-agents-baseline.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n%s\n' "$lock_pid" "$agents_hash" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$AGENTS_BASELINE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# Seconds since the epoch at which <pid> started, or nothing when ps cannot say.
fm_pid_start_epoch() {  # <pid>
  local lstart
  lstart=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) || return 1
  [ -n "$lstart" ] || return 1
  date -d "$lstart" +%s 2>/dev/null || LC_ALL=C date -j -f '%a %b %e %T %Y' "$lstart" +%s 2>/dev/null
}

fm_file_mtime_epoch() {  # <file>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# True (0) when the AGENTS.md this process started with may differ from the file
# now. A baseline recorded for this very process decides by hash. With none for
# it (resumed with --continue, helm taken by hand, a new pid after a restart),
# the process read AGENTS.md when it started, so a file older than the process
# cannot have drifted: that file becomes this process's baseline (never written
# by a read-only session, which is not the lock owner), and a mid-process change
# - a local landing - is still delivered once because the file is then newer
# than the process. Anything unprovable counts as drifted.
agents_baseline_drifted() {  # <rebuilding-session-pid>
  local lock_pid=$1 baseline_pid='' baseline_hash='' current_hash started mtime
  current_hash=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
  [ -n "$current_hash" ] || return 0
  if [ -f "$AGENTS_BASELINE_FILE" ] && [ ! -L "$AGENTS_BASELINE_FILE" ]; then
    baseline_pid=$(sed -n '1p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
    baseline_hash=$(sed -n '2p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  fi
  if [ -n "$lock_pid" ] && [ "$baseline_pid" = "$lock_pid" ]; then
    [ "$baseline_hash" = "$current_hash" ] && return 1
    return 0
  fi
  [ -n "$lock_pid" ] || return 0
  started=$(fm_pid_start_epoch "$lock_pid") || return 0
  mtime=$(fm_file_mtime_epoch "$FM_ROOT/AGENTS.md") || return 0
  case "$started$mtime" in *[!0-9]*) return 0 ;; esac
  [ "$mtime" -lt "$started" ] || return 0
  [ "${READ_ONLY:-0}" -ne 0 ] || write_agents_baseline "$lock_pid" "$current_hash" || true
  return 1
}

# Only run-tier source pairs with both a stale native instruction cache and a
# working Firstmate delivery path arrive here. Claude fresh-reads on reset, and
# Codex has no tracked interactive reset delivery path.
agents_refresh_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  case "$PRIMARY_HARNESS:$SESSION_SOURCE" in
    pi:compact|pi-signed:compact) ;;
    *) return 1 ;;
  esac
  agents_baseline_drifted "$lock_pid"
}

print_agents_refresh_if_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  agents_refresh_required "$lock_pid" || return 0
  section "CURRENT AGENTS.md - INSTRUCTION REFRESH"
  if [ -f "$FM_ROOT/AGENTS.md" ]; then
    cat <<'EOF'
The complete on-disk AGENTS.md below supersedes the instruction copy this session
started with. Apply it as the current Firstmate instruction contract.

EOF
    cat "$FM_ROOT/AGENTS.md"
  else
    printf 'The original AGENTS.md baseline no longer matches, but the current file is absent.\n'
  fi
}

AGENTS_START_HASH=
if [ "$REEMIT" -eq 0 ] && [ "$SESSION_SOURCE" = startup ]; then
  AGENTS_START_HASH=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
fi

if [ "$REEMIT" -eq 1 ]; then
  # First in the output on purpose: a harness that spills a large hook output
  # delivers only a short head inline (Claude: about 2,000 characters), and
  # CONTEXT prints last, so this cue is the part that must survive the spill.
  # A Pi-family harness delivers the digest as its own message and marks a cut.
  if [ "$FRAME_VIEW" = full ] || [ "$PI_FAMILY" -eq 0 ]; then
    printf 'RE-EMIT CUE: if this output ends with "Output too large ... Full output saved to <path>",\n'
    printf 'read that whole file now, before acting. Otherwise read data/captain.md, data/captain-shared.md,\n'
    printf 'and data/learnings.md under %s now if any of them is missing below.\n' "$DATA"
  fi
  if [ "$FRAME_VIEW" = full ]; then
    section "SESSION START (CONTEXT RE-EMIT) - $FM_HOME"
    printf 'This session already took the helm at its own startup and has only lost its\n'
    printf 'context. Lock ownership is re-verified and the durable records below are\n'
    printf 'reprinted, but the sweeps startup already reconciled - project clone refresh,\n'
    printf 'secondmate convergence and liveness, pending remote handoff\n'
    printf 'retry, X-mode artifact writes, and stale Herdr child cleanup - are NOT repeated.\n'
    printf 'Queued wakes ARE still drained: they arrived after startup and are this turn work.\n'
  else
    section "SESSION START (CONTEXT RE-EMIT) - $FM_HOME: this session only lost its context; the lock is re-verified, startup sweeps are not repeated, and the wakes below are this turn's work."
  fi
else
  section "SESSION START - $FM_HOME"
fi
# --- 1. lock -----------------------------------------------------------
stage lock
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: stale Herdr child cleanup,\n'
    printf '●  secondmate convergence, secondmate liveness, pending remote handoff retry,\n'
    printf '●  X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi
REBUILDING_SESSION_PID=$(fm_harness_ancestry_pid 2>/dev/null || true)
print_agents_refresh_if_required "$REBUILDING_SESSION_PID"

# --- 1b. home role -------------------------------------------------------
# This home's firstmate-repository role: user/operator unless an explicit
# local or receipt-proven inherited grant says otherwise (bin/fm-role-lib.sh).
# Purely local resolution - no network, no gh call.
stage role
subsection "HOME ROLE"
FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-role.sh" report 2>/dev/null \
  || printf 'fm-role: unknown (bin/fm-role.sh report failed)\n'

if [ "$READ_ONLY" -eq 0 ]; then
  if [ "$REEMIT" -eq 0 ]; then
    rm -f "$COMPLETION_FILE" 2>/dev/null || true
  fi
  fm_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
  # A full locked start publishes this home's current structured summary.
  # Publication is side-band and best-effort, so it can never change the
  # session-start result, and nothing below reads it. It is built by a detached,
  # lowered-priority process that owns its atomic publication and its own
  # FM_HOME_SUMMARY_TIMEOUT bound (180s here, because no digest waits on it),
  # as the watcher launches it. Run in line on a CPU-contended host it cost 90
  # seconds of this script's runtime bound for a ledger no digest section reads.
  # A context re-emit is not another session start.
  if [ "$REEMIT" -eq 0 ]; then
    FM_HOME_SUMMARY_TIMEOUT=${FM_HOME_SUMMARY_TIMEOUT:-180} \
      nice -n 10 "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort \
      </dev/null >/dev/null 2>&1 &
  fi
  # Every network call and the potentially slow inactive-outcome startup scan
  # are launched HERE, detached and bounded, so they run concurrently with the
  # whole digest below instead of in front of it. Step 7 harvests whatever has
  # finished, without ever waiting.
  # --reemit passes --locked 0 for the same reason it runs bootstrap detect-only:
  # this process already ran the mutating sweeps at its own startup, so only the
  # read-only GitHub-auth probe is owed. A read-only session starts nothing at
  # all: it holds no mutation authority for the sweeps, and it must not spawn,
  # steer, or merge anyway, so it has no action left for an auth verdict to gate.
  NETWORK_STAGE_LOCKED=1
  [ "$REEMIT" -eq 0 ] || NETWORK_STAGE_LOCKED=0
  "$SCRIPT_DIR/fm-startup-network.sh" start \
    --locked "$NETWORK_STAGE_LOCKED" --harvest-pid $$ >/dev/null 2>&1 || true
fi

# --- 2. bootstrap --------------------------------------------------------
# FM_BOOTSTRAP_NETWORK=skip on every path: bootstrap's own network half is what
# the deferred stage above is running right now, and running it twice would both
# re-block this digest and race the worker's sweeps against themselves.
stage bootstrap
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
    FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
elif [ "$REEMIT" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_LOCKED=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
    FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/fm-herdr-session-cleanup.sh" 2>&1 || true
    FM_BOOTSTRAP_NETWORK=skip FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
      FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" \
      "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1
  )
fi
# A startup-memory budget overrun is standing curation debt: name it while it
# lasts. The report is a local read and prints nothing usable without a budget.
MEMORY_LINE=
MEMORY_REPORT=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
  "$SCRIPT_DIR/fm-startup-memory-budget.sh" report 2>/dev/null) || MEMORY_REPORT=
case "$MEMORY_REPORT" in
  *budget_status=over-budget*)
    MEMORY_LINE=$(printf '%s\n' "$MEMORY_REPORT" | awk -F= '
      $1 == "total_estimated_tokens" { total = $2 }
      $1 == "effective_budget_tokens" { budget = $2 }
      END { printf "STARTUP_MEMORY: %s/%s estimated tokens - over budget; curate with /stow", total, budget }')
    ;;
esac
if [ -n "$BOOT_OUT" ] || [ -n "$MEMORY_LINE" ]; then
  [ -z "$BOOT_OUT" ] || printf '%s\n' "$BOOT_OUT"
  [ -z "$MEMORY_LINE" ] || printf '%s\n' "$MEMORY_LINE"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain ---------------------------------------------------------
# The inactive-outcome startup scan runs in the deferred worker launched above,
# where its potentially slow current-state reads cannot block this digest. It
# publishes findings through the same durable queue drained here; the watcher's
# separate 900-second cadence remains unchanged.
# Presented records are this turn's first work queue and remain durable until
# post-handling acknowledgement. The drain's separate OPEN DECISIONS section
# remains actionable even when that queue is empty (AGENTS.md sections 3 and 8).
# The drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue because it lacks mutation
# authority, and another session may be actively handling it. It still runs
# fm-guard.sh directly with non-mutating advisory text, so the same alarms
# surface without repair commands.
stage wake-queue
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-branch-outcome.sh" seed-tail >/dev/null 2>&1 || true
  # Pi supervision-branch recovery, locked path only: clear leases whose
  # supervising session died, and surface outcomes the branch stored durably
  # that never reached main (docs/pi-supervision-branch.md). Gated to the
  # pi/pi-signed primary so a non-Pi home runs neither step - homes on any
  # other harness stay entirely untouched (captain-decided criterion).
  if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lease.sh" sweep 2>/dev/null || true
    BRANCH_REPLAY_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-branch-outcome.sh" startup-replay 2>&1) || BRANCH_REPLAY_OUT=
    if [ -n "$BRANCH_REPLAY_OUT" ]; then
      printf '%s\n' "$BRANCH_REPLAY_OUT"
    fi
  fi
  # The drain prints its own WAKE_ACK_REQUIRED line for the rows it presents,
  # so the guard it runs need not tell this turn to drain them again.
  # The drain gets its own stage bound (FM_SESSION_START_DRAIN_TIMEOUT, default
  # 45s; 0 removes it), so one slow queue can no longer spend the whole digest
  # budget and cut every later stage. A cut drain loses nothing: its rows stay
  # queued until acknowledged, and the notice below names the command that
  # presents them.
  DRAIN_BOUND=${FM_SESSION_START_DRAIN_TIMEOUT:-45}
  case "$DRAIN_BOUND" in ''|*[!0-9]*) DRAIN_BOUND=45 ;; esac
  if [ "$DRAIN_BOUND" -gt 0 ]; then
    DRAIN_OUT=$(fm_run_timed "$DRAIN_BOUND" env FM_OPEN_DECISIONS_VIEW=all FM_GUARD_QUEUE_PRESENTED="${FM_GUARD_QUEUE_PRESENTED:-1}" \
      "$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  else
    DRAIN_OUT=$(FM_OPEN_DECISIONS_VIEW=all FM_GUARD_QUEUE_PRESENTED="${FM_GUARD_QUEUE_PRESENTED:-1}" \
      "$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  fi
  DRAIN_RC=$?
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  elif [ "$DRAIN_RC" -ne 124 ]; then
    printf '(no queued wakes)\n'
  fi
  if [ "$DRAIN_RC" -eq 124 ]; then
    printf 'WAKE DRAIN CUT AT %ss (its own stage bound): the queue is intact and nothing was acknowledged.\n' "$DRAIN_BOUND"
    printf 'Run bin/fm-wake-drain.sh yourself after this digest; a queue that stays slow is a fleet problem to report.\n'
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
stage supervision-instructions
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
AFK_MODE=$(fm_afk_mode "$STATE")
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_RESTART_COMMAND=$PRIMARY_HARNESS
  [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
  PI_WATCH_VERSION=$(fm_pi_extension_version "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(fm_pi_extension_version "$PI_TURNEND_EXT" || printf '')
  if ! fm_pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" active \
    || ! fm_pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
# omp (Oh My Pi) has no project-trust gate: it auto-discovers <cwd>/.omp/extensions
# with no dialog, so the only ways both tracked primary extensions fail to load
# are a session started outside this home, an extension disabled in the omp
# config, or a build older than the tracked file. The markers carry the loaded
# build plus the loading pid, exactly as the Pi ones do (bin/fm-wake-lib.sh).
if [ "$PRIMARY_HARNESS" = omp ]; then
  OMP_EXT="$FM_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
  OMP_TURNEND_EXT="$FM_ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
  OMP_WATCH_MARKER="$STATE/.omp-watch-extension-loaded"
  OMP_TURNEND_MARKER="$STATE/.omp-turnend-extension-loaded"
  OMP_LOCK="$STATE/.lock"
  OMP_WATCH_VERSION=$(fm_pi_extension_version "$OMP_EXT" || printf '')
  OMP_TURNEND_VERSION=$(fm_pi_extension_version "$OMP_TURNEND_EXT" || printf '')
  if ! fm_pi_extension_loaded "$OMP_WATCH_MARKER" "$OMP_WATCH_VERSION" "$OMP_LOCK" \
    || ! fm_pi_extension_loaded "$OMP_TURNEND_MARKER" "$OMP_TURNEND_VERSION" "$OMP_LOCK"; then
    OMP_HOME_PHYS=$(cd -P "$FM_HOME" 2>/dev/null && pwd -P || printf '%s' "$FM_HOME")
    OMP_ROOT_PHYS=$(cd -P "$FM_ROOT" 2>/dev/null && pwd -P || printf '%s' "$FM_ROOT")
    if [ "$OMP_HOME_PHYS" = "$OMP_ROOT_PHYS" ]; then
      printf 'OMP_WATCH_EXTENSION: not loaded - restart omp with this home as its working directory so %s and %s auto-load from .omp/extensions/ for turn-end guard and background wake coverage; pass -e %s -e %s only when omp must start from another directory, never together with auto-discovery (omp loads a file named both ways twice)\n' "$OMP_TURNEND_EXT" "$OMP_EXT" "$OMP_TURNEND_EXT" "$OMP_EXT"
    else
      # shellcheck disable=SC2016  # backticks are literal text in the diagnostic
      printf 'OMP_WATCH_EXTENSION: not loaded - exit omp and relaunch through `fm <project>` (the launcher sets FM_HOME and --cwd) so %s and %s auto-load for this home; a bare omp or /resume from the firstmate checkout does not register the extensions for this home\n' "$OMP_TURNEND_EXT" "$OMP_EXT"
    fi
    # Warning only: name the cause when existing facts establish it.
    OMP_MARKER_PID=$(sed -n '2p' "$OMP_WATCH_MARKER" 2>/dev/null || true)
    OMP_CURRENT_PID=${REBUILDING_SESSION_PID:-$(sed -n '1p' "$OMP_LOCK" 2>/dev/null || true)}
    if [ -n "$OMP_MARKER_PID" ] && [ -n "$OMP_CURRENT_PID" ] && [ "$OMP_MARKER_PID" != "$OMP_CURRENT_PID" ]; then
      printf 'OMP_WATCH_CAUSE: the extension marker %s names pid %s, which is not this session (pid %s)\n' "$OMP_WATCH_MARKER" "$OMP_MARKER_PID" "$OMP_CURRENT_PID"
    fi
  fi
fi
# A Pi-family context re-emit gets the compact block (COMPACT VIEWS in the header).
SUPERVISION_COMPACT=0
if [ "$REEMIT" -eq 1 ] && [ "$PI_FAMILY" -eq 1 ] && [ "$SUPERVISION_VIEW" = compact ]; then
  SUPERVISION_COMPACT=1
fi
"$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --afk-mode "$AFK_MODE" \
  --x-mode "$X_MODE_PRESENT" \
  --compact "$SUPERVISION_COMPACT"

# --- 5. read-once contract -------------------------------------------------
# Ahead of the two digests it governs, not after them: a truncated tail is
# exactly what drops a closing reminder, and this contract is what stops the
# next turn from re-reading everything the digest just printed. Because it now
# arrives BEFORE its subject, it also names the one condition that voids it -
# a stage that never ran, which the truncation banner names by stage.
stage read-once
section "READ-ONCE CONTRACT"
if [ "$FRAME_VIEW" = compact ]; then
  READ_ONCE_TASKS='every state/*.meta (one line each)'
  [ "$TASK_VIEW" = compact ] || READ_ONCE_TASKS='every state/*.meta with a bounded state/*.status tail'
  READ_ONCE_MATES='data/secondmates.md (compact)'
  [ "$SECONDMATES_VIEW" = compact ] || READ_ONCE_MATES='data/secondmates.md'
  printf 'This digest prints %s, a compact backlog, data/projects.md, %s,\n' "$READ_ONCE_TASKS" "$READ_ONCE_MATES"
  cat <<'EOF'
data/captain.md, data/captain-shared.md and data/learnings.md. Do not re-read them.
Go to a source only when it is flagged ABSENT or corrupt, a capped line or older
history matters (state/<id>.status), a full task body is needed
(bin/fm-tasks-axi.sh show <id> --full), or a STARTUP TRUNCATED banner names a stage
that never ran.
EOF
else
cat <<'EOF'
Everything below is printed in full for this session start: every state/*.meta,
a compact data/backlog.md listing, a bounded tail of every state/*.status,
data/projects.md, data/secondmates.md, data/captain.md, data/captain-shared.md,
and data/learnings.md.
Do NOT re-read any of them after reading this digest, and do NOT bulk-read
data/backlog.md or state/*.status: re-reading everything defeats the entire
point of this command.

Go to a source directly only when:
  - this digest flagged it ABSENT (then rebuild or create it per AGENTS.md),
  - its contents looked unparseable or corrupt,
  - an individual full status log is needed for older wake-event history, or a
    status line was capped and its tail matters (each task's full log path is
    printed with its tail),
  - a full task body is needed (bin/fm-tasks-axi.sh show <id> --full, or data/backlog.md),
  - the backlog listing disclosed omitted queued items and this turn needs them,
  - the NETWORK CHECKS section reported its checks still IN PROGRESS and this
    turn needs their verdict (bin/fm-startup-network.sh report),
  - or a STARTUP TRUNCATED banner named the stage that would have printed it, in
    which case that stage's sources were never emitted and must be reconciled,
  - or a context re-emit opened with a read cue because the
    harness cut the digest short.
EOF
fi

if [ "$LEARNINGS_VIEW" = compact ]; then
  printf 'data/learnings.md is printed as one capped line per item after this compaction; open the file for an item'"'"'s full text.\n'
fi

# --- 6. fleet-state digest ---------------------------------------------
# Before CONTEXT: see this file's ORDERING note. Live fleet identity is what a
# truncated tail must never take.
stage fleet-state
section "FLEET STATE"
print_backlog_compact "$DATA/backlog.md" "data/backlog.md"

if [ "$TASK_VIEW" = full ]; then
  subsection "Work under way (state/*.meta)"
else
  subsection "Work under way - one line per task (full record: state/<id>.meta and state/<id>.status; read them only before steering, controlling, or cleaning up that task):"
fi
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  if [ "$TASK_VIEW" = full ]; then
    printf '\n--- %s ---\n' "$id"
    cat "$meta"
  fi

  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    endpoint_rc=0
    fm_session_start_endpoint_read "$backend" "${target:-$window}" "fm-$id" || endpoint_rc=$?
    # Only the timeout owner's own statuses mean the read itself failed: 124 is
    # the bound firing and >=128 is a signal death. Every other nonzero status
    # is the probe's own verdict that the endpoint is gone.
    if [ "$endpoint_rc" -eq 0 ]; then
      endpoint_word=alive
      endpoint_line="endpoint: alive (backend=$backend window=$window)"
    elif [ "$endpoint_rc" -eq 124 ] || [ "$endpoint_rc" -ge 128 ]; then
      endpoint_word="error(the read died or hit its ${ENDPOINT_TIMEOUT}s bound)"
      endpoint_line="endpoint: error (backend=$backend window=$window - the endpoint read died or hit its ${ENDPOINT_TIMEOUT}s bound; the digest continued past it)"
    else
      endpoint_word=dead
      endpoint_line="endpoint: dead (backend=$backend window=$window)"
    fi
  else
    endpoint_word=unknown
    endpoint_line='endpoint: unknown (no window recorded)'
  fi

  status="$STATE/$id.status"
  if [ "$TASK_VIEW" = compact ]; then
    print_task_line "$id" "$meta" "$endpoint_word" "$status"
    continue
  fi
  printf '%s\n' "$endpoint_line"
  if [ -f "$status" ]; then
    print_status_tail "$status"
  else
    printf 'status tail: (no status file yet: %s)\n' "$status"
  fi
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Orphan status logs (state/*.status without matching .meta)"
# A log with no task behind it matters only while it holds an open decision or a
# recent event; the rest is history, summarised by one count line. Recent means
# the newest line's own time tag (file mtime when untagged) is inside
# FM_SESSION_START_ORPHAN_DAYS days.
ORPHAN_STATUS_FOUND=0
ORPHAN_STATUS_OMITTED=0
ORPHAN_NOW=$(date +%s 2>/dev/null || printf 0)
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  orphan_last=$(tail -n 1 "$status" 2>/dev/null || true)
  orphan_at=$(status_line_at_epoch "$orphan_last" 2>/dev/null || true)
  [ -n "$orphan_at" ] || orphan_at=$(_fm_status_file_mtime "$status" 2>/dev/null || true)
  orphan_open=$(status_open_decisions "$status" 2>/dev/null || true)
  if [ -z "$orphan_open" ] && [ -n "$orphan_at" ] && [ "$ORPHAN_NOW" -gt 0 ] \
    && [ $((ORPHAN_NOW - orphan_at)) -gt $((ORPHAN_DAYS * 86400)) ]; then
    ORPHAN_STATUS_OMITTED=$((ORPHAN_STATUS_OMITTED + 1))
    continue
  fi
  ORPHAN_STATUS_FOUND=1
  if [ "$TASK_VIEW" = compact ]; then
    print_task_line "$id" '' '' "$status" "$orphan_open"
    continue
  fi
  printf '\n--- %s ---\n' "$id"
  print_status_tail "$status"
done
if [ "$ORPHAN_STATUS_OMITTED" -gt 0 ]; then
  printf '\n%s older orphan status log(s) with no open decision omitted (idle more than %s day(s); logs in %s).\n' \
    "$ORPHAN_STATUS_OMITTED" "$ORPHAN_DAYS" "$STATE"
elif [ "$ORPHAN_STATUS_FOUND" -ne 1 ]; then
  printf '(none)\n'
fi

subsection "AFK"
# The away posture is the record (bin/fm-afk-contract.sh); the legacy flag
# still marks a running daemon on the harnesses that launch one.
# A quiet record (bin/fm-afk-contract.sh mode) is a present captain: it holds
# nothing for a return.
if [ -f "$STATE/.afk-contract" ]; then
  if [ "$("$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" = quiet ]; then
    printf 'present - quiet mode recorded at %s (the captain is present and nothing is held for a return: requested actions proceed under ordinary attended authority; only an explicit /quiet off exits it)' \
      "$("$SCRIPT_DIR/fm-afk-contract.sh" field entered 2>/dev/null || printf unknown)"
  else
    printf 'present - away posture recorded at %s (hold-for-return only; bin/fm-afk-contract.sh readback for the mandate)' \
      "$("$SCRIPT_DIR/fm-afk-contract.sh" field entered 2>/dev/null || printf unknown)"
  fi
  if [ -e "$STATE/.afk" ]; then
    if [ "$AFK_MODE" = quiet ]; then
      printf '; the quiet daemon owns the watcher.\n'
    else
      printf '; the away daemon owns the watcher.\n'
    fi
  else
    printf '; no daemon runs, the ordinary supervision session continues.\n'
  fi
elif [ -e "$STATE/.afk" ]; then
  if [ "$AFK_MODE" = quiet ]; then
    printf 'present - quiet-mode supervision is active; the daemon owns the watcher, only an explicit /quiet off exits it (legacy flag with no posture record).\n'
  else
    printf 'present - away-mode supervision is active; the daemon owns the watcher (legacy flag with no posture record).\n'
  fi
else
  printf 'absent\n'
fi

# Public commitments made through the myfirstmate relay. A promise to reply in a
# public thread must survive compaction and restart, so it is surfaced from disk
# here rather than from conversation memory. fm-public-followup-lib.sh owns both
# gates: a home that never opted into the relay runs one [ -f ] test, prints no
# subsection, and never reaches fm-public-followup.sh.
if fm_pf_relay_active "$FM_HOME" \
  && { fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE"; }; then
  PUBLIC_FOLLOWUP=$("$SCRIPT_DIR/fm-public-followup.sh" pending 2>/dev/null) || PUBLIC_FOLLOWUP=
  if [ -n "$PUBLIC_FOLLOWUP" ]; then
    subsection "Public commitments"
    printf '%s\n' "$PUBLIC_FOLLOWUP"
    printf '\nEach line is a public loop this home still holds: a reply still owed, or an open loop with nothing owed.\n'
    printf 'Reconcile terminal results with %s/bin/fm-public-followup.sh consume, then deliver a ready one with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh deliver <id>. Hand a delivered loop on with rechain, or close it with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh retire <id> --reason "...". Load fmx-respond for the procedure.\n' "$FM_ROOT"
  fi
fi

# --- 7. network checks ------------------------------------------------------
# Deliberately here and not later: these lines are actionable (a stuck clone, a
# secondmate that could not be relaunched, broken GitHub auth), and the section
# after this one is the curated memory a truncated tail is meant to take first.
# Deliberately here and not earlier: this is the last point in the digest, so the
# worker started at step 1 has had the whole composition above to finish in. It
# is a NON-BLOCKING read either way - whatever the worker has published by now is
# printed, and whatever it has not is named as not yet confirmed.
stage network-checks
section "NETWORK CHECKS"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - GitHub authentication, project clone refresh,\n'
  printf 'secondmate liveness and convergence, and pending handoff delivery were not run.\n'
  printf 'They need the fleet lock, and this session must not spawn, steer, or merge, so it\n'
  printf 'has no action they would gate. The session holding the lock runs them.\n'
else
  "$SCRIPT_DIR/fm-startup-network.sh" harvest --pid $$ 2>&1 || true
fi

# --- 8. context digest -----------------------------------------------------
# Last of the bulk sections deliberately: curated memory is stable session to
# session, already governed by config/startup-memory-budget, and recoverable
# with one targeted read, so it is the cheapest thing for a truncated tail to
# take (see this file's ORDERING note).
stage context
section "CONTEXT"
print_file_or_absent "$DATA/projects.md" "data/projects.md"
if [ "$SECONDMATES_VIEW" = compact ]; then
  print_secondmates_compact "$DATA/secondmates.md"
else
  print_file_or_absent "$DATA/secondmates.md" "data/secondmates.md"
fi
print_file_or_absent "$DATA/captain.md" "data/captain.md"
print_file_or_absent "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)"
if [ "$LEARNINGS_VIEW" = compact ]; then
  print_learnings_compact "$DATA/learnings.md"
else
  print_file_or_absent "$DATA/learnings.md" "data/learnings.md"
fi

# --- 9. closing reminder -----------------------------------------------
stage next-step
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ] && [ "$AFK_MODE" = quiet ]; then
  cat <<'EOF'
Quiet mode is active. Follow the supervision operating instructions block
above: load /quiet and ensure the daemon is running, because the daemon owns
watcher supervision. Ordinary captain chat does not exit it; only an
explicit /quiet off does.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
elif [ "$REEMIT" -eq 1 ] && [ "$PI_FAMILY" -eq 1 ] && [ "$FRAME_VIEW" = compact ]; then
  printf 'Handle the queued wakes above; the Pi extension owns watcher continuity, so do not arm another cycle.\n'
  NEXT_STEP_SHORT=1
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
[ "${NEXT_STEP_SHORT:-0}" -eq 1 ] || cat <<'EOF'
The digest above is complete for this session start. The READ-ONCE CONTRACT
section near the top of it governs what may still be read from disk.
EOF

if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  COMPLETION_RECORDED=0
  COMPLETION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$COMPLETION_PID" || COMPLETION_PID=
  COMPLETION_TMP=$(mktemp "$STATE/.session-start-complete.XXXXXX" 2>/dev/null || true)
  if [ -n "$COMPLETION_PID" ] && [ -n "$COMPLETION_TMP" ] \
    && printf '%s\n' "$COMPLETION_PID" > "$COMPLETION_TMP" 2>/dev/null \
    && mv -f "$COMPLETION_TMP" "$COMPLETION_FILE" 2>/dev/null; then
    COMPLETION_RECORDED=1
  else
    [ -z "$COMPLETION_TMP" ] || rm -f "$COMPLETION_TMP" 2>/dev/null || true
    printf '\nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.\n'
  fi
  if [ "$SESSION_SOURCE" = startup ] && [ "$COMPLETION_RECORDED" -eq 1 ] && [ -n "$AGENTS_START_HASH" ]; then
    if ! write_agents_baseline "$COMPLETION_PID" "$AGENTS_START_HASH"; then
      printf '\nSESSION_START_AGENTS_BASELINE: not recorded - a later supported rebuild will re-emit AGENTS.md.\n'
    fi
  fi
fi

exit 0
