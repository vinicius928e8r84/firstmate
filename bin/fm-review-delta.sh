#!/usr/bin/env bash
# fm-review-delta.sh - print the compact packet a re-reviewer needs after the
# PR head moved past the head a review covered.
#
# Usage:
#   fm-review-delta.sh --repo DIR (--reviewed SHA | --pin OWNER/REPO PR)
#                      [--head REF] [--base REF] [--max-lines N]
#
# DIR is a clone or worktree holding both the reviewed commit and the head.
# --pin reads reviewed_head from the review pin fm-review-pin.sh recorded
# ($FM_HOME/data/review-pins/<owner>__<repo>-<pr>.pin); --reviewed names it
# directly. --head defaults to HEAD, --base to origin/main (the branch whose
# tip the PR merged; the merge-base of each head with it is that head's
# "main it contains"). --max-lines (default 400) caps each hunk section.
#
# The packet is the first line, then only what is new to the reviewer:
#   DELTA-NONE           the PR's own +/- lines are byte-identical to the
#                        reviewed head and no merge was hand-resolved
#   DELTA-RESOLVED-ONLY  own +/- lines identical, but a merge commit carries
#                        hand-resolved hunks: review only those hunks
#   DELTA-OWN-CHANGED    the PR's own change differs: review the range-diff
# Sections follow the first line:
#   own change   an explicit sentence for the identical case, with the file and
#                line counts; the PR's own change is compared on its +/- lines
#                only (git diff -U0 per head, from the merge-base with --base),
#                so context lines a main merge moved around do not count
#   range-diff   git range-diff of the PR's own commits (merge-base..reviewed
#                against merge-base..head); merge commits are not commits of
#                the range, so a stacked PR whose base landed compares cleanly
#   resolved     per merge commit in reviewed..head, only what git did not do
#                itself: the hand edits on top of a clean automatic merge, or the
#                combined diff (--cc) of a conflict resolution; an automatic
#                merge has none (needs git with `merge-tree --write-tree`)
# Exit status: 0 DELTA-NONE, 1 anything to review, 2 usage, 3 git error.
# Read-only: it never changes DIR, its refs, or any remote.
set -uo pipefail

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() { sed -n 2,38p "$0"; }

repo= reviewed= pin_slug= pin_pr= head=HEAD base=origin/main max=400
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --reviewed) reviewed=${2:-}; shift 2 ;;
    --pin) pin_slug=${2:-}; pin_pr=${3:-}; shift 3 ;;
    --head) head=${2:-}; shift 2 ;;
    --base) base=${2:-}; shift 2 ;;
    --max-lines) max=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$repo" ] && [ -d "$repo" ] || { echo "--repo must name an existing directory" >&2; exit 2; }
[ -z "$pin_slug" ] || [ -z "$reviewed" ] || { echo "--reviewed and --pin are alternatives" >&2; exit 2; }
if [ -n "$pin_slug" ]; then
  [ -n "$pin_pr" ] || { echo "--pin takes OWNER/REPO and PR" >&2; exit 2; }
  pin_file=$FM_HOME/data/review-pins/${pin_slug//\//__}-$pin_pr.pin
  [ -f "$pin_file" ] || { echo "no review pin recorded: $pin_file" >&2; exit 3; }
  reviewed=$(sed -n 's/^reviewed_head=//p' "$pin_file")
fi
[ -n "$reviewed" ] || { echo "name the reviewed head with --reviewed or --pin" >&2; usage >&2; exit 2; }
case "$max" in ''|*[!0-9]*) echo "--max-lines must be a number" >&2; exit 2 ;; esac

g() { git -C "$repo" "$@"; }
rev=$(g rev-parse --verify -q "$reviewed^{commit}") || { echo "reviewed commit not in $repo: $reviewed (fetch it first)" >&2; exit 3; }
tip=$(g rev-parse --verify -q "$head^{commit}") || { echo "head not found in $repo: $head" >&2; exit 3; }
base_tip=$(g rev-parse --verify -q "$base^{commit}") || { echo "base not found in $repo: $base" >&2; exit 3; }
base_rev=$(g merge-base "$base_tip" "$rev") || { echo "no merge-base between $base and the reviewed head" >&2; exit 3; }
base_tipm=$(g merge-base "$base_tip" "$tip") || { echo "no merge-base between $base and the head" >&2; exit 3; }

# The PR's own change as bare +/- lines (and file-mode lines), so shifted
# context and hunk offsets never make an unchanged change look different.
own_lines() { g diff --no-renames --no-ext-diff --no-color -U0 "$1" "$2" | grep -E '^([-+]|new file mode|deleted file mode|old mode|new mode)'; }
old_sum=$(own_lines "$base_rev" "$rev" | sha256sum | cut -d' ' -f1)
new_sum=$(own_lines "$base_tipm" "$tip" | sha256sum | cut -d' ' -f1)

capped() { # stdin -> at most $max lines, then a truncation note
  awk -v max="$max" 'NR<=max {print} NR==max+1 {print "... truncated at " max " lines"; exit}'
}

# merge_hunks <merge-commit>: what a person must read in one merge commit, or
# nothing. A two-parent merge is replayed with `git merge-tree --write-tree`:
# the same tree means git did it alone (nothing to read), a clean replay with a
# different tree means hand edits on top (shown against the replay), and a
# conflicting replay means a hand resolution (shown as the combined diff, which
# keeps only hunks matching no parent). The combined diff alone is not used for
# the clean case: it also shows hunks where two parents changed lines near each
# other and git merged them untouched.
merge_hunks() {
  local c=$1 parents auto auto_rc
  parents=$(g rev-list --parents -n1 "$c")
  # shellcheck disable=SC2086 # the line is "<commit> <parent>..." split on purpose
  set -- $parents
  if [ "$#" -eq 3 ]; then
    auto=$(g merge-tree --write-tree "$2" "$3" 2>/dev/null); auto_rc=$?
    if [ "$auto_rc" -eq 0 ]; then
      [ "$auto" = "$(g rev-parse "$c^{tree}")" ] && return 0
      g diff --no-ext-diff --no-color "$auto" "$c"
      return 0
    fi
  fi
  g show --cc --format= "$c"
}

resolved=
merges=$(g rev-list --merges --reverse "$rev..$tip")
for c in $merges; do
  hunks=$(merge_hunks "$c")
  [ -z "$hunks" ] || resolved+=$'\n'"merge $(g rev-parse --short=8 "$c") $(g log -1 --format=%s "$c" | cut -c1-70)"$'\n'"$(printf '%s\n' "$hunks" | capped)"$'\n'
done

if [ "$old_sum" = "$new_sum" ]; then
  [ -n "$resolved" ] && verdict=DELTA-RESOLVED-ONLY || verdict=DELTA-NONE
else
  verdict=DELTA-OWN-CHANGED
fi

echo "$verdict $(g rev-parse --short=8 "$rev")..$(g rev-parse --short=8 "$tip")"
echo
echo "== own change (compared on +/- lines, main ${base_rev:0:8} -> ${base_tipm:0:8})"
if [ "$old_sum" = "$new_sum" ]; then
  stat=$(g diff --no-renames --numstat "$base_tipm" "$tip" | awk '{f++; a+=$1; d+=$2} END {printf "%d files, +%d/-%d", f, a, d}')
  echo "The PR's own +/- lines are byte-identical to the reviewed head ($stat)."
else
  echo "The PR's own +/- lines DIFFER from the reviewed head."
  echo
  echo "== range-diff of the PR's own commits (reviewed first, head second)"
  g range-diff --no-color "$base_rev..$rev" "$base_tipm..$tip" | capped
fi
echo
echo "== hand-resolved merge hunks"
if [ -n "$resolved" ]; then
  printf '%s\n' "$resolved"
else
  echo "none: every merge in the range is exactly what git does on its own."
fi
[ "$verdict" = DELTA-NONE ] && exit 0
exit 1
