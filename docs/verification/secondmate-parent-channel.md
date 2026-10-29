# Secondmate parent channel: live verification

Maintainer-verification record for the guarantee in [`secondmate-parent-channel.md`](../secondmate-parent-channel.md): a captain-facing outcome recorded inside a secondmate home reaches the parent channel without the mate model writing it.
Refresh it by rerunning the fixture below after changing any publisher named in `bin/fm-parent-channel-lib.sh`.
This run predates emission-time stamping, so each published line below is the payload without its stamp: a rerun now writes the same bytes with an `[at=<epoch>]` tag closing the head, as in `done [key=child-outcome-child-done-05b032a1] [at=<epoch>]: child ...`.
[`bin/fm-classify-lib.sh`](../../bin/fm-classify-lib.sh) owns that tag's syntax; nothing this record proves about delivery depends on it.

## What was run

Date: 2026-09-03.
Tree: this change's branch on macOS with tmux 3.6a, bash 3.2 as `/bin/bash`, and the repo's own scripts.
Fixture: two isolated homes under a scratch directory, `$P` (parent) and `$M` (mate), with `config/backend` set to `tmux` in both.
The mate home carries `.fm-secondmate-home` (`mate`) and a local `.fm-secondmate-parent` binding to `$P`; the parent home carries `state/mate.meta` (`kind=secondmate`, `home=$M`).
The mate's child task `child` is a real tmux pane (`fmlive:fm-child`) recorded in `$M/state/child.meta` with `mode=no-mistakes` and `yolo=off`; the mate itself is a second real pane (`fmlive:fm-mate`).
Both homes run the real `bin/fm-watch.sh` (`FM_POLL=2`), re-armed after every wake through `bin/fm-wake-drain.sh` acknowledgement, exactly as fleet supervision re-arms a watcher after a handled turn.
No agent harness and no model runs anywhere in the fixture.

The child's only action is the ordinary crewmate status append, typed into its own pane with `tmux send-keys`.
The mate's only actions are the scripts a firstmate runs when it registers a PR and when it holds a task for the captain and records the answer.

## Transcript

```text
$ # Setup: mate home $M is a secondmate of parent home $P (local route); child task 'child' lives in a real tmux pane; both watchers are live

$ # Step 1: the child appends its terminal line from inside its own real tmux pane

$ tmux send-keys -t fmlive:fm-child "echo 'done: PR https://github.com/kunchenguid/firstmate/pull/9999 checks green' >> $M/state/child.status" Enter

$ cat $M/state/child.status
working: implementing the feature
done: PR https://github.com/kunchenguid/firstmate/pull/9999 checks green

$ cat $P/state/mate.status   (the parent channel)
working: delegated scope
done [key=child-outcome-child-done-05b032a1]: child child done: PR https://github.com/kunchenguid/firstmate/pull/9999 checks green pr=https://github.com/kunchenguid/firstmate/pull/9999 mode=no-mistakes yolo=off

$ mate watcher wakes so far
signal: $M/state/child.status

$ parent watcher wakes so far
signal: $P/state/mate.status

$ # Step 2: the mate registers the PR with fm-pr-check; the ready line with the canonical URL reaches the parent from the script itself

$ FM_HOME=$M FM_STATE_OVERRIDE=$M/state bin/fm-pr-check.sh child https://github.com/kunchenguid/firstmate/pull/9999
armed: state/child.check.sh

$ cat $P/state/mate.status
working: delegated scope
done [key=child-outcome-child-done-05b032a1]: child child done: PR https://github.com/kunchenguid/firstmate/pull/9999 checks green pr=https://github.com/kunchenguid/firstmate/pull/9999 mode=no-mistakes yolo=off
done [key=child-pr-child]: child child PR ready: https://github.com/kunchenguid/firstmate/pull/9999 mode=no-mistakes yolo=off

$ parent watcher wakes so far (2 signals)
signal: $P/state/mate.status
signal: $P/state/mate.status

$ # Step 3: the mate holds a task for the captain; the hold reaches the parent from fm-captain-hold itself

$ FM_HOME=$M bin/fm-captain-hold.sh hold child-call --title 'Pick the rollout window' --reason 'rollout window choice pending' --repo alpha
child-call

$ # Step 4: the captain's answer is recorded in the mate home; the close reaches the parent from fm-captain-hold itself

$ FM_HOME=$M bin/fm-captain-hold.sh answer child-call --decision-file decision.txt   (decision: roll out on Monday)
answered: child-call

$ cat $P/state/mate.status   (final parent channel)
working: delegated scope
done [key=child-outcome-child-done-05b032a1]: child child done: PR https://github.com/kunchenguid/firstmate/pull/9999 checks green pr=https://github.com/kunchenguid/firstmate/pull/9999 mode=no-mistakes yolo=off
done [key=child-pr-child]: child child PR ready: https://github.com/kunchenguid/firstmate/pull/9999 mode=no-mistakes yolo=off
needs-decision [key=captain-hold-child-call-1]: captain hold child-call: rollout window choice pending
resolved [key=captain-hold-child-call-1]: captain hold child-call: answered

$ parent watcher wakes, one per delivered line (4 signals)
signal: $P/state/mate.status
signal: $P/state/mate.status
signal: $P/state/mate.status
signal: $P/state/mate.status

$ mate watcher wakes
signal: $M/state/child.status
stale: fmlive:fm-child

$ # Every line above beginning 'done [key=child-' or carrying 'captain-hold-' was written by a script, never by a model; each one woke the parent watcher.
```

## Why this proves the hole is closed

- The observed defect was a mate model that handled its child's outcome and then addressed the captain in its own chat instead of appending to the parent channel.
  In this run there is no model at all, and four captain-facing lines still appeared on `$P/state/mate.status`: the child's terminal done line with its note, canonical PR, mode, and posture; the PR-ready line at registration; the captain hold; and the hold's answer.
- Each line was written by the script that recorded the underlying fact: `bin/fm-inactive-reconcile.sh` on the mate watcher's poll, `bin/fm-pr-check.sh`, and `bin/fm-captain-hold.sh`.
- Each line produced one `signal:` wake in the real parent watcher, which is the event that starts the parent firstmate's turn and therefore the captain-facing report.
- The mate watcher's own `signal:` on `child.status` shows the mate was woken as before; whatever the mate model would have said in its chat afterward is irrelevant to delivery.
- The trailing `stale:` line in the mate watcher log is the idle real pane after the child's final line, ordinary liveness escalation unrelated to delivery.

## Re-run on Linux, 2026-10-29

The same four steps were re-run on 2026-10-29 on Linux 6.8.0 x86_64 with tmux 3.4, bash 5.2.21 as `bash`, git 2.43.0, and this repository's scripts at the commit that added this section.
The fixture matches the one above with three differences.
Both homes use `config/backend` `tmux` on a private tmux server (`TMUX_TMPDIR` in the scratch directory).
The child task has a real git worktree with an `origin/main` ref, so its done line passes the named-head check.
Each home's real watcher (`bin/fm-watch.sh`) runs in a loop that acknowledges through `bin/fm-wake-drain.sh --ack-through` and re-arms.
No agent harness and no model ran, and the host was heavily loaded (load average above 25), which only lengthened the waits.

The final parent channel in the saved run was:

```text
working: delegated scope
done [key=child-outcome-child-done-7d1065d2] [at=1793269105]: child child done: PR https://github.com/kunchenguid/firstmate/pull/9999 checks green pr=https://github.com/kunchenguid/firstmate/pull/9999 mode=no-mistakes yolo=off
done [key=child-pr-child] [at=1793269134]: child child PR ready: https://github.com/kunchenguid/firstmate/pull/9999 mode=no-mistakes yolo=off
needs-decision [key=captain-hold-child-call-1] [at=1793269165]: captain hold child-call: rollout window choice pending
resolved [key=captain-hold-child-call-1] [at=1793269192]: captain hold child-call: answered
```

What this run proves on Linux: all four captain-facing lines reached the parent channel with no model writing any of them.
Each came from the script that recorded the fact: `bin/fm-inactive-reconcile.sh` on the mate watcher's poll, `bin/fm-pr-check.sh`, and `bin/fm-captain-hold.sh` for the hold and for the answer.
Each now carries the `[at=<epoch>]` stamp the opening paragraph predicts.
The real parent watcher woke on `mate.status`: it printed a `signal:` reason once, and two further wake rows with the reason `needs-decision:` were queued for the hold and its answer.

What this run does not claim: the macOS run recorded one parent wake per delivered line (four signals), and this run did not.
The parent watcher produced three wake events for four lines, so one wake per line is not re-proven on Linux and the macOS count remains the only evidence for it.
Whether the missing wake is coalescing by the watcher or a gap in this run's simple re-arm loop was not determined.
`bin/fm-pr-check.sh` also printed `fm-guard.sh: No such file or directory` because the fixture's code-root override is an empty directory, and it still armed the poll and published the ready line.
