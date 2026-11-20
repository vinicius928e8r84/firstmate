# Cloudroom crewmates

Cloudroom (https://cloudroom.dev) runs coding agents in cloud sandboxes.
When firstmate itself runs as a Cloudroom cloud thread, `bin/fm-cloudroom.sh` dispatches crewmates as Cloudroom child threads.
Each one gets its own sandbox and branch, so it needs no terminal backend and no Treehouse worktree.

## Setup

1. Add this repository (or your fork) as a Cloudroom project and start a Claude Code cloud thread in it.
   The thread opens in the clone, so `AGENTS.md` and the `.claude/` hooks load as in any primary session.
2. Check: `bin/fm-cloudroom.sh doctor` (needs `room-cli` and `jq`).
3. Optional, for an SSH-reachable fleet host such as a VPS: put the host's private key in a Cloudroom secret, configure an SSH alias, and provision it as a [remote secondmate](remote-secondmates.md).

## Shape

| Contract step ([`codex-app-backend.md`](codex-app-backend.md#acceptance-contract)) | Cloudroom |
| --- | --- |
| Create, durable id | `room-cli thread spawn`; `state/<id>.meta` records `backend=cloudroom` and `cloudroom_thread_id=` |
| Send | `room-cli thread tell` (queued while the worker is busy) |
| Read | `room-cli thread show`, `output`, `log` |
| Archive | `room-cli thread stop`, `archive` |
| Status return | parent-side `sync` (below) |

A child runs in another sandbox and cannot write this home's `state/<id>.status`.
The worker prompt therefore makes every reply end with ordinary status lines, and `fm-cloudroom.sh sync` appends new ones to the status file once per finished reply.
A finished reply with no status line is recorded as `blocked` so it is never silently lost.
Cloudroom messages the parent thread whenever a child finishes a turn, which is the wake that triggers `sync`.

## Limits

- Not an `FM_BACKEND` value: `fm-spawn.sh`, `fm-peek.sh`, `fm-send.sh`, and `fm-control.sh` do not route `backend=cloudroom` tasks; use `fm-cloudroom.sh` for them.
- Ship tasks deliver as `direct-PR`; `no-mistakes` and `local-only` need a local worktree.
- No secondmate spawns through Cloudroom; remote secondmates use SSH.
- A cloud sandbox stops background jobs after two hours, so the bash watcher is not a durable wake source there; the Cloudroom completion message is.
- Workers spend Cloud Credits.

## Verification

`tests/fm-cloudroom.test.sh` pins spawn metadata, sync dedupe and the missing-status rule, scout report capture, and the close refusal against a fake `room-cli`.
