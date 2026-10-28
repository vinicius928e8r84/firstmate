#!/usr/bin/env bash
# fm-arm-budget.sh - print the extra seconds a watcher arm may need to start.
#
# Usage: fm-arm-budget.sh
#
# Read-only: prints one whole number and exits 0 without launching a watcher or
# changing any state. The number is how much longer than its base confirmation
# window an arm may take on this host right now - the load stretch of the window
# plus any back-off still pending (bin/fm-watch-arm.sh header, "Load back-off").
# It is 0 on an unloaded host.
#
# The Pi, omp, and OpenCode watcher adapters add it to their own fixed ready
# timeout before they terminate an unready arm. It lives in its own script so an
# adapter's query can never be mistaken for an arm launch.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/fm-watch-arm.sh" --budget
