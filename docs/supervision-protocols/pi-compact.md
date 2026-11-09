Mode: Pi extension background wake (compact re-emit form).

1. A watcher wake already carries its drain under WAKE DRAIN: do not drain or acknowledge it again; the extension acknowledges when this run settles.
   Drain, then run the printed WAKE_ACK_REQUIRED command yourself, only at session start (above) or when a wake message says to drain.
   Reconcile open decisions and unread status either way.
2. Continuity is extension-owned: call fm_watch_arm_pi only for the first cycle or when a notification reports the cycle missing, failed, or unhealthy; never run bin/fm-watch-arm.sh through bash and never use shell & for supervision.
3. Supervision branch (on while state/.afk-contract exists or config/supervision-branch turns it on): a hidden processing request lists [seq N, recorded <age> ago] task: summary; answer only the still-open outcomes, then call fm_branch_processed once with the highest listed sequence.
   Before steering, controlling, or cleaning up a task, run bin/fm-lease.sh claim <task> and release it afterwards.
Regression example - keep verbatim and never condense away: `[seq 41] claude-mod: implementation complete, ready for review` requires relaying a captain-facing outcome response, not just `Captain, shipshape.`.
Full protocol: bin/fm-supervision-instructions.sh --harness __FM_HARNESS__ - read it before any watcher repair, extension restart, or supervision-branch question.
