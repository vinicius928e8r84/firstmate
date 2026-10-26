#!/usr/bin/env bash
# fm-review-rules.sh - print the standing rules every independent reviewer is given.
#
# Usage: fm-review-rules.sh
#
# The single owner of the reviewer's standing instructions, so a review
# launcher or a hand-written review request appends this text instead of
# restating it: $(fm-review-rules.sh) at the end of the request. The rules:
#   - the reviewer never runs the project's whole test suite locally; that suite
#     runs once, on a rented machine, at the exact final head, and the
#     orchestrator reads that result
#   - the reviewer may run focused tests of the changed paths only
#   - when the head moved past a reviewed head, the reviewer reads the
#     fm-review-delta.sh packet, not the whole PR again
# It reads nothing and changes nothing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cat <<RULES
Reviewer standing rules:
- Do not run the project's full test suite on this machine. The suite runs once, on a rented machine, at the exact final head, and the orchestrator reads that result; a local full run only loads the shared host and repeats it.
- Run only focused tests of the paths this change touches, and only when reading the code leaves a question a test can answer.
- If an earlier clean review exists and the head moved, read the packet from $SCRIPT_DIR/fm-review-delta.sh (the changed part only) instead of reading the whole PR again; a DELTA-OWN-CHANGED packet is the one case that calls for a fresh read of the own change.
RULES
