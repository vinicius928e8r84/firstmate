---
name: firstmate-cloudroom
description: >-
  Load when firstmate runs inside a Cloudroom cloud thread (`room-cli` on PATH or ROOM_THREAD_ID set) before dispatching, steering, reading, or cleaning up a cloud worker, and on every Cloudroom "child thread completed" message.
user-invocable: false
metadata:
  internal: true
---

# firstmate-cloudroom

## Overview

Inside Cloudroom, a crewmate is a Cloudroom child thread with its own cloud sandbox and branch, driven by `bin/fm-cloudroom.sh`.
[`docs/cloudroom-backend.md`](../../../docs/cloudroom-backend.md) owns the shape, limits, and why it is a companion helper rather than an `FM_BACKEND` value; the script header owns flags.

## Boundary

- Cloudroom forbids starting `claude`, `codex`, or any agent CLI from a shell in its sandbox, and forbids harness-native subagents. So in a Cloudroom primary, never use `bin/fm-spawn.sh` with a local terminal backend; dispatch every local crewmate through `bin/fm-cloudroom.sh spawn`.
- Remote secondmates on SSH hosts (the VPS fleet) keep their ordinary path: `secondmate-provisioning`, `fm-on.sh`, `fm-send.sh`. Their own workers stay on that host.
- Each cloud worker spends the captain's Cloud Credits; check `room-cli usage` before a large fan-out and mention cost when much is running.

## Dispatch

1. Do the normal intake (section 7): project, ship or scout, delivery mode. Cloud workers deliver `direct-PR` or scout; `local-only` and `no-mistakes` need a local worktree and stay on a remote secondmate.
2. Write the captain's intent and firstmate spec to `data/<id>/task.md`.
3. `bin/fm-cloudroom.sh spawn <id> --repo <owner/name> --task-file data/<id>/task.md [--kind scout] [--provider P --model M --effort E]`.
   Resolve provider, model, and effort from dispatch profiles as usual; `room-cli provider list` and `room-cli provider models <P>` are the catalog.

## Supervise

- Cloudroom messages this thread each time a child finishes a turn. That message is the wake: run `bin/fm-cloudroom.sh sync --all`, then act on the new status lines exactly as on any status wake.
- A sync that reports `blocked: worker ended a turn without a status line` means read the reply with `peek` and steer it.
- Steer with `bin/fm-cloudroom.sh send <id> '<text>'`; interrupt with `stop`.
- Before ending a turn with cloud work under way, no extra watcher is needed: the Cloudroom completion message is the backstop.

## Land and clean up

- Ship: the `done` line carries the PR URL; merge authority and `bin/fm-pr-merge.sh` are unchanged.
- Scout: `sync` saves the done reply to `data/<id>/report.md`; load `scout-completion`.
- `bin/fm-cloudroom.sh close <id>` archives the thread and refuses unless the last status is done or failed; `--force` only under hard rule 3.
