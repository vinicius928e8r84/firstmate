#!/usr/bin/env bash
# fm-verification-stale.sh - list docs/verification records whose cited bin/ files changed after the record's date.
# Usage: fm-verification-stale.sh [--root <repo>] [--check] [record.md ...]
# A record's date is the latest YYYY-MM-DD it mentions. A cited file is any existing tracked file under bin/ that the
# record names (for example bin/fm-spawn.sh). A file is stale for a record when a commit touched it on a UTC date
# later than the record's date. Records are docs/verification/*.md unless named on the command line.
# Output, one tab-separated line per stale file: STALE record record-date file commits-since last-change-date.
# A record with no date prints UNDATED record; a record with no cited file prints UNCITED record. Neither is a failure.
# Read-only: it runs git log and reads the records, and never edits anything. It is not wired into CI or the watcher.
# Exit: 0 when it ran (even if records are stale), 1 with --check when at least one STALE line was printed, 2 on usage error.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK=0
RECORDS=()
while [ $# -gt 0 ]; do
  case $1 in
    --root) [ $# -ge 2 ] || { echo "fm-verification-stale: --root needs a directory" >&2; exit 2; }
      ROOT=$(cd "$2" && pwd) || exit 2; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "fm-verification-stale: unknown option $1" >&2; exit 2 ;;
    *) RECORDS+=("$1"); shift ;;
  esac
done

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "fm-verification-stale: $ROOT is not a git repository" >&2; exit 2; }
if [ ${#RECORDS[@]} -eq 0 ]; then
  for f in "$ROOT"/docs/verification/*.md; do [ -f "$f" ] && RECORDS+=("$f"); done
fi

# One pass over history: "<UTC commit date> <file>" for every commit touching bin/, newest first.
CHANGES=$(TZ=UTC git -C "$ROOT" log --date=format-local:%Y-%m-%d --format=@%cd --name-only -- bin \
  | awk '/^@/ { d = substr($0, 2); next } NF { print d, $0 }')

STALE=0
for rec in "${RECORDS[@]}"; do
  [ -f "$rec" ] || { echo "fm-verification-stale: no such record: $rec" >&2; exit 2; }
  name=$(basename "$rec")
  date=$(grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$rec" | sort -u | tail -1)
  if [ -z "$date" ]; then printf 'UNDATED\t%s\n' "$name"; continue; fi
  cited=0
  while IFS= read -r file; do
    file=${file%%[.,:;]}
    [ -n "$(git -C "$ROOT" ls-files -- "$file")" ] || continue
    cited=1
    # Commits touching the file on a UTC date after the record's date make it stale.
    changes=$(printf '%s\n' "$CHANGES" | awk -v d="$date" -v f="$file" '$2 == f && $1 > d { print $1 }')
    [ -n "$changes" ] || continue
    STALE=1
    printf 'STALE\t%s\t%s\t%s\t%s\t%s\n' "$name" "$date" "$file" "$(printf '%s\n' "$changes" | wc -l | tr -d ' ')" "$(printf '%s\n' "$changes" | head -1)"
  done < <(grep -oE 'bin/[A-Za-z0-9_./-]+' "$rec" | sort -u)
  [ "$cited" -eq 1 ] || printf 'UNCITED\t%s\n' "$name"
done

[ "$CHECK" -eq 1 ] && [ "$STALE" -eq 1 ] && exit 1
exit 0
