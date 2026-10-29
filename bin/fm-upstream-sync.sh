#!/usr/bin/env bash
# fm-upstream-sync.sh - keep this firstmate in step with the repository it was
# forked from and with the operator's own fork, without ever rewriting history.
#
# Usage:
#   fm-upstream-sync.sh        run once (meant for a daily cron line)
#
# Remotes: `upstream` (the original repository) and `fork` (the operator's
# fork). Every run does these steps and prints exactly one summary line:
#   1. Quietly stops (exit 0) when the primary checkout is not on main, has
#      uncommitted changes to tracked files, or another run holds the lock
#      (flock on state/.upstream-sync.lock).
#   2. `git fetch upstream` and `git fetch fork`, each bounded by a timeout.
#   3. Publish: when fork/main is an ancestor of main and behind it, a plain
#      `git push fork main:main`. No force flag is ever used; a refusal is
#      reported and the run stops.
#   4. Take in upstream: when upstream/main is already an ancestor of main (or
#      of fork/main) nothing happens. Otherwise a temporary worktree OUTSIDE the
#      primary checkout gets branch sync/upstream-YYYYMMDD from main and
#      `git merge --no-ff --no-edit upstream/main` runs there, so local main is
#      never touched.
#      - Clean merge: `bash -n` over the bin/*.sh files the merge changed, then
#        the branch is pushed to fork (no force) and ONE pull request is opened
#        against the fork's main. The pull request is never merged here. No new
#        pull request is opened while another sync/upstream-* one is open.
#      - Conflict (or a failed syntax check): the merge is aborted, the
#        temporary worktree removed, data/upstream-sync/YYYYMMDD.md lists the
#        files and both side commit ranges, and one `upstream-sync-conflict`
#        notice goes through the watcher webhook. The upstream head is
#        remembered in state/.upstream-sync.seen and is not retried.
#   5. Appends one line to state/.upstream-sync.log.
#
# Exit status: always 0; the summary line and the log carry the outcome.
#
# Environment:
#   FM_HOME                   firstmate home and primary checkout
#                             (default: the code root)
#   FM_UPSTREAM_SYNC_DRY=1    print what would be done; no push, pull request,
#                             notice, report, or seen record (the trial merge
#                             still runs in a throwaway worktree)
#   FM_UPSTREAM_SYNC_REPO     fork slug for gh
#                             (default: vinicius928e8r84/firstmate)
#   FM_UPSTREAM_SYNC_TIMEOUT  seconds bounding each network call (default 60)
#   FM_UPSTREAM_SYNC_NOW      fixed epoch for the date stamps (tests)
#   FM_UPSTREAM_SYNC_NO_NOTIFY=1  never send the webhook notice
#
# The webhook is the one fm-pod-budget.sh uses: ~/.config/fm/watcher-webhook.url
# and .key. The notice text carries file names and commit ranges, no secrets.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REPO_SLUG="${FM_UPSTREAM_SYNC_REPO:-vinicius928e8r84/firstmate}"
TMO="${FM_UPSTREAM_SYNC_TIMEOUT:-60}"
DRY="${FM_UPSTREAM_SYNC_DRY:-}"
LOG="$STATE/.upstream-sync.log"
SEEN="$STATE/.upstream-sync.seen"
NOW="${FM_UPSTREAM_SYNC_NOW:-$(date +%s)}"
STAMP=$(date -d "@$NOW" +%Y%m%d)
TAG="fm-upstream-sync"

mkdir -p "$STATE" 2>/dev/null
WT=""
BRANCH=""
KEEP_BRANCH=""
TMPD=""

g() { git -C "$FM_HOME" "$@"; }

cleanup() {
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    g worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
    g worktree prune >/dev/null 2>&1
  fi
  if [ -n "$BRANCH" ] && [ -z "$KEEP_BRANCH" ]; then
    g branch -D "$BRANCH" >/dev/null 2>&1
  fi
  [ -z "$TMPD" ] || rm -rf "$TMPD"
  WT=""; BRANCH=""; TMPD=""
}
trap cleanup EXIT

# finish <outcome> <detail>: log, print the one summary line, exit 0.
finish() {
  local pre=""
  [ -z "$DRY" ] || pre="DRY "
  printf '%s\t%s%s\t%s\n' "$(date -u -d "@$NOW" +%FT%TZ)" "$pre" "$1" "$2" >> "$LOG" 2>/dev/null
  printf '%s: %s%s - %s\n' "$TAG" "$pre" "$1" "$2"
  cleanup
  exit 0
}

notify() { # <event> <message>
  local u k m
  [ -z "$DRY" ] && [ -z "${FM_UPSTREAM_SYNC_NO_NOTIFY:-}" ] || return 0
  u=$(cat "$HOME/.config/fm/watcher-webhook.url" 2>/dev/null)
  k=$(cat "$HOME/.config/fm/watcher-webhook.key" 2>/dev/null)
  { [ -n "$u" ] && [ -n "$k" ]; } || return 0
  m=$(printf %s "$2" | tr -d '"\134' | tr '\n\t' '  ')
  timeout 20 curl -fsS -X POST "$u" -H "Authorization: Bearer $k" -H "Content-Type: application/json" \
    --data "{\"event\":\"$1\",\"message\":\"$m\"}" >/dev/null 2>&1 || true
}

range() { # <base> <tip> -> "short..short (N commits)"
  printf '%s..%s (%s commits)' "$(g rev-parse --short "$1")" "$(g rev-parse --short "$2")" "$(g rev-list --count "$1..$2")"
}

# --- 1. guards -------------------------------------------------------------
g rev-parse --git-dir >/dev/null 2>&1 || finish skip "not a git checkout: $FM_HOME"
[ "$(g symbolic-ref --short -q HEAD)" = main ] || finish skip "primary checkout is not on main"
[ -z "$(g status --porcelain --untracked-files=no 2>/dev/null)" ] || finish skip "primary checkout has uncommitted tracked changes"
command -v flock >/dev/null 2>&1 || finish skip "flock is not installed"
exec 9>"$STATE/.upstream-sync.lock"
flock -n 9 || finish skip "another sync is running"

# --- 2. fetch --------------------------------------------------------------
for r in upstream fork; do
  timeout "$TMO" git -C "$FM_HOME" fetch "$r" >/dev/null 2>&1 || finish fetch-failed "git fetch $r failed or timed out"
done
g rev-parse -q --verify refs/remotes/upstream/main >/dev/null || finish skip "no upstream/main"
g rev-parse -q --verify refs/remotes/fork/main >/dev/null || finish skip "no fork/main"
MAIN=$(g rev-parse main)

# --- 3. publish ------------------------------------------------------------
PUBLISHED=""
FORK=$(g rev-parse refs/remotes/fork/main)
if [ "$FORK" != "$MAIN" ] && g merge-base --is-ancestor "$FORK" "$MAIN"; then
  if [ -n "$DRY" ]; then
    PUBLISHED="would push main to fork ($(g rev-list --count "$FORK..$MAIN") commits); "
  elif timeout "$TMO" git -C "$FM_HOME" push fork main:main >/dev/null 2>&1; then
    PUBLISHED="pushed main to fork ($(g rev-list --count "$FORK..$MAIN") commits); "
  else
    finish push-refused "fork refused or timed out on the plain push of main; stopped"
  fi
fi

# --- 4. take in upstream ---------------------------------------------------
UP=$(g rev-parse refs/remotes/upstream/main)
if g merge-base --is-ancestor "$UP" "$MAIN"; then
  finish ok "${PUBLISHED}upstream/main ${UP:0:8} is already in main"
fi
if g merge-base --is-ancestor "$UP" "$FORK"; then
  finish ok "${PUBLISHED}upstream/main ${UP:0:8} is already in fork/main; pull it into local main"
fi
if grep -q "^$UP	" "$SEEN" 2>/dev/null; then
  finish ok "${PUBLISHED}upstream/main ${UP:0:8} was already handled (see state/.upstream-sync.seen)"
fi
command -v gh >/dev/null 2>&1 || finish skip "${PUBLISHED}gh is not installed"
OPEN=$(timeout "$TMO" gh pr list --repo "$REPO_SLUG" --state open --json headRefName \
  --jq '[.[]|select(.headRefName|startswith("sync/upstream-"))]|length' 2>/dev/null) || OPEN=err
case "$OPEN" in
  0) ;;
  err) finish skip "${PUBLISHED}could not list open pull requests" ;;
  *) finish ok "${PUBLISHED}a sync/upstream-* pull request is already open; not opening another" ;;
esac

NAME=$(g config user.name); MAIL=$(g config user.email)
{ [ -n "$NAME" ] && [ -n "$MAIL" ]; } || finish skip "${PUBLISHED}no git identity configured for firstmate commits"

BRANCH="sync/upstream-$STAMP"; n=1
while g rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null || g rev-parse -q --verify "refs/remotes/fork/$BRANCH" >/dev/null; do
  n=$((n + 1)); BRANCH="sync/upstream-$STAMP-$n"
done
TMPD=$(mktemp -d /tmp/fm-upstream-sync.XXXXXX) || finish skip "no temporary directory"
WT="$TMPD/wt"
g worktree add -q -b "$BRANCH" "$WT" main >/dev/null 2>&1 || { BRANCH=""; WT=""; finish skip "${PUBLISHED}could not create the temporary worktree"; }

BASE=$(g merge-base main "$UP")
OURS=$(range "$BASE" main); THEIRS=$(range "$BASE" "$UP")
COUNT=$(g rev-list --count "main..$UP")

GM=(git -C "$WT" -c "user.name=$NAME" -c "user.email=$MAIL" -c core.hooksPath=/dev/null -c commit.gpgsign=false)
if "${GM[@]}" merge --no-ff --no-edit "$UP" >/dev/null 2>&1; then
  CONFLICTS=""
else
  CONFLICTS=$(git -C "$WT" diff --name-only --diff-filter=U 2>/dev/null)
  [ -n "$CONFLICTS" ] || CONFLICTS="(merge failed without conflicting files)"
  git -C "$WT" merge --abort >/dev/null 2>&1
fi

SYNTAX_BAD=""
CHANGED=""
if [ -z "$CONFLICTS" ]; then
  CHANGED=$(git -C "$WT" diff --name-only main HEAD 2>/dev/null)
  while IFS= read -r f; do
    case "$f" in bin/*.sh) ;; *) continue ;; esac
    [ -f "$WT/$f" ] || continue
    bash -n "$WT/$f" >/dev/null 2>&1 || SYNTAX_BAD="$SYNTAX_BAD$f"$'\n'
  done <<<"$CHANGED"
fi

if [ -n "$CONFLICTS" ] || [ -n "$SYNTAX_BAD" ]; then
  if [ -n "$CONFLICTS" ]; then WHAT="merge conflicts"; LIST="$CONFLICTS"
  else WHAT="syntax check failed after a clean merge"; LIST=$(printf '%s' "$SYNTAX_BAD"); fi
  if [ -z "$DRY" ]; then
    mkdir -p "$DATA/upstream-sync"
    {
      printf '# Upstream sync %s: %s\n\n' "$STAMP" "$WHAT"
      printf 'Upstream head: %s\n\n' "$UP"
      printf 'Merge base: %s\n\n' "$BASE"
      printf 'Local main since the base: %s\n\n' "$OURS"
      printf 'Upstream main since the base: %s\n\n' "$THEIRS"
      printf 'Files:\n\n'
      printf '%s\n' "$LIST" | sed 's/^/- /'
    } > "$DATA/upstream-sync/$STAMP.md"
    printf '%s\t%s\t%s\n' "$UP" "$STAMP" "conflict" >> "$SEEN"
    notify upstream-sync-conflict "Upstream sync $STAMP stopped: $WHAT in $(printf '%s\n' "$LIST" | wc -l | tr -d ' ') file(s). Upstream head ${UP:0:8}, local main $OURS, upstream $THEIRS. Details in data/upstream-sync/$STAMP.md. Not retried."
  fi
  finish conflict "${PUBLISHED}$WHAT; upstream ${UP:0:8} left alone$([ -n "$DRY" ] || printf ', report in data/upstream-sync/%s.md' "$STAMP")"
fi

if [ -n "$DRY" ]; then
  finish ok "${PUBLISHED}would push $BRANCH to fork and open a pull request ($COUNT upstream commits)"
fi

KEEP_BRANCH=1
timeout "$TMO" git -C "$FM_HOME" push fork "$BRANCH:refs/heads/$BRANCH" >/dev/null 2>&1 \
  || finish push-refused "${PUBLISHED}fork refused or timed out on $BRANCH; branch kept locally"

BODY="$TMPD/body.md"
{
  printf 'Merges %s upstream commit(s) from upstream/main (%s) into main with a merge commit.\n\n' "$COUNT" "${UP:0:8}"
  printf 'The bin/*.sh files changed by the merge pass bash -n.\n\n'
  printf 'Files changed (%s):\n\n' "$(printf '%s\n' "$CHANGED" | grep -c .)"
  printf '%s\n' "$CHANGED" | head -200 | sed 's/^/- /'
} > "$BODY"
if PR=$(timeout "$TMO" gh pr create --repo "$REPO_SLUG" --base main --head "$BRANCH" \
  --title "Sync with upstream main ($STAMP)" --body-file "$BODY" 2>&1); then
  KEEP_BRANCH=""
  printf '%s\t%s\t%s\n' "$UP" "$STAMP" "pr" >> "$SEEN"
  finish pr-opened "${PUBLISHED}$(printf '%s\n' "$PR" | tail -n 1) ($COUNT upstream commits)"
fi
finish pr-failed "${PUBLISHED}pushed $BRANCH but gh pr create failed: $(printf '%s' "$PR" | tr '\n' ' ' | cut -c1-160)"
