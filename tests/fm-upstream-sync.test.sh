#!/usr/bin/env bash
# Behavior tests for bin/fm-upstream-sync.sh (the daily upstream/fork sync).
#
# Drives the public environment interface against local bare repositories that
# stand in for `upstream` and `fork`, with fake gh and curl on PATH, so no case
# touches the network, GitHub, or the real webhook. Pins:
#   1. quiet exits for a checkout off main, a dirty tracked file, and a held lock;
#   2. a plain fast-forward publish of main to fork, and nothing when in step;
#   3. a clean upstream merge lands on a sync branch pushed to fork with one
#      pull request, and local main, the primary checkout, and the worktree
#      list are untouched;
#   4. the same upstream head is not handled twice, and an open sync pull
#      request stops a second one;
#   5. a conflict (or a bash -n failure) is aborted, reported in
#      data/upstream-sync/, notified once, remembered, and never pushed;
#   6. FM_UPSTREAM_SYNC_DRY=1 changes nothing on the remotes;
#   7. a refused push and a failed fetch are reported and exit 0.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-upstream-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-sync)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=$PATH
HOME_DIR="$TMP_ROOT/home"
GH_LOG="$TMP_ROOT/gh.log"
CURL_LOG="$TMP_ROOT/curl.log"
mkdir -p "$HOME_DIR/.config/fm"
printf 'https://hook.invalid/x\n' > "$HOME_DIR/.config/fm/watcher-webhook.url"
printf 'not-a-real-key\n' > "$HOME_DIR/.config/fm/watcher-webhook.key"
NOW=$(date -d '2026-10-29 12:00' +%s)
STAMP=$(date -d "@$NOW" +%Y%m%d)

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "${FAKE_GH_OPEN:-0}" ;;
  "pr create")
    printf '%s\n' "$*" >> "${GH_LOG:?}"
    while [ $# -gt 0 ]; do
      [ "$1" = --body-file ] && cp "$2" "${GH_LOG}.body"
      shift
    done
    printf 'https://github.com/example/firstmate/pull/7\n' ;;
  *) exit 2 ;;
esac
SH
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
SH
chmod +x "$FAKEBIN/gh" "$FAKEBIN/curl"

G() { git -c user.name=Tester -c user.email=tester@example.invalid "$@"; }

# new_world <name>: bare upstream + bare fork + a primary checkout on main.
new_world() {
  W="$TMP_ROOT/$1"
  mkdir -p "$W"
  G init -q --bare -b main "$W/upstream.git"
  G clone -q "$W/upstream.git" "$W/seed" 2>/dev/null
  mkdir -p "$W/seed/bin"
  printf '#!/usr/bin/env bash\necho a\n' > "$W/seed/bin/a.sh"
  printf 'line1\nline2\n' > "$W/seed/notes.txt"
  G -C "$W/seed" add -A
  G -C "$W/seed" commit -qm base
  G -C "$W/seed" push -q origin HEAD:main
  G clone -q --bare "$W/upstream.git" "$W/fork.git"
  G clone -q "$W/upstream.git" "$W/home" 2>/dev/null
  G -C "$W/home" remote rename origin upstream >/dev/null 2>&1
  G -C "$W/home" remote add fork "$W/fork.git"
  G -C "$W/home" config user.name 'Fleet Captain'
  G -C "$W/home" config user.email 'captain@users.noreply.example'
  G -C "$W/home" fetch -q fork
  : > "$GH_LOG"; : > "$CURL_LOG"; rm -f "$GH_LOG.body"
}

# commit_in <clone> <file> <content> [push-ref]: commit a file; push to origin when given.
commit_in() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s' "$3" > "$1/$2"
  G -C "$1" add -A
  G -C "$1" commit -qm "change $2"
  [ -z "${4:-}" ] || G -C "$1" push -q origin "HEAD:$4"
}

run_sync() { # extra env assignments as args
  env PATH="$FAKEBIN:$BASE_PATH" HOME="$HOME_DIR" FM_HOME="$W/home" FM_UPSTREAM_SYNC_NOW="$NOW" \
    GH_LOG="$GH_LOG" CURL_LOG="$CURL_LOG" FM_UPSTREAM_SYNC_REPO=example/firstmate "$@" "$TOOL" 2>&1
}
last_log() { tail -n 1 "$W/home/state/.upstream-sync.log"; }
sha() { G -C "$W/$1" rev-parse "$2"; }

# 1. quiet exits ---------------------------------------------------------------
new_world quiet
G -C "$W/home" checkout -q -b other
OUT=$(run_sync); CODE=$?
expect_code 0 "$CODE" "off main exits 0"
assert_contains "$OUT" "not on main" "off main is a quiet skip"
[ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] || fail "exactly one stdout line"
G -C "$W/home" checkout -q main
printf 'dirty\n' >> "$W/home/notes.txt"
OUT=$(run_sync); assert_contains "$OUT" "uncommitted tracked" "dirty tracked file is a quiet skip"
G -C "$W/home" checkout -q -- notes.txt
mkdir -p "$W/home/state"
( exec 8> "$W/home/state/.upstream-sync.lock"; flock 8; sleep 4 ) &
HOLDER=$!
sleep 1
OUT=$(run_sync); assert_contains "$OUT" "another sync is running" "a held lock is a quiet skip"
wait "$HOLDER"
assert_equals "" "$(cat "$GH_LOG")" "no pull request from a skipped run"
[ "$(wc -l < "$W/home/state/.upstream-sync.log")" = 3 ] || fail "every run appends one log line"
pass "sync: quiet exits for off-main, dirty, and locked runs, each logged"

# 2. publish and in-step --------------------------------------------------------
new_world publish
commit_in "$W/home" bin/local.sh $'#!/usr/bin/env bash\necho local\n'
OUT=$(run_sync); CODE=$?
expect_code 0 "$CODE" "publish exits 0"
assert_contains "$OUT" "pushed main to fork (1 commits)" "publish is reported"
assert_equals "$(sha home main)" "$(sha fork.git main)" "fork main fast-forwarded to local main"
OUT=$(run_sync)
assert_contains "$OUT" "already in main" "nothing to take in when upstream is behind"
assert_not_contains "$OUT" "pushed" "a second run publishes nothing"
pass "sync: publishes by plain fast-forward and is a no-op once in step"

# 3. clean upstream merge -> one PR ---------------------------------------------
commit_in "$W/seed" bin/up.sh $'#!/usr/bin/env bash\necho up\n' main
UPHEAD=$(sha seed HEAD)
MAIN_BEFORE=$(sha home main)
OUT=$(run_sync); CODE=$?
expect_code 0 "$CODE" "clean merge exits 0"
assert_contains "$OUT" "pr-opened" "a pull request is opened"
assert_contains "$OUT" "https://github.com/example/firstmate/pull/7" "the pull request URL is reported"
assert_contains "$(cat "$GH_LOG")" "--repo example/firstmate" "gh targets the fork repository"
assert_contains "$(cat "$GH_LOG")" "--head sync/upstream-$STAMP" "the PR head is the dated sync branch"
assert_contains "$(cat "$GH_LOG")" "--title Sync with upstream main ($STAMP)" "the PR title carries the date"
assert_contains "$(cat "$GH_LOG.body")" "1 upstream commit" "the body counts the merged commits"
assert_contains "$(cat "$GH_LOG.body")" "- bin/up.sh" "the body lists the changed files"
assert_not_contains "$(cat "$GH_LOG.body")" "captain" "the body has no direct address"
assert_equals "$MAIN_BEFORE" "$(sha home main)" "local main is untouched by the merge"
assert_equals "" "$(G -C "$W/home" status --porcelain --untracked-files=no)" "the primary checkout stays clean"
assert_equals 1 "$(G -C "$W/home" worktree list | wc -l)" "the temporary worktree is removed"
G -C "$W/home" rev-parse -q --verify "refs/heads/sync/upstream-$STAMP" >/dev/null && fail "the local sync branch is removed after the PR"
G -C "$W/fork.git" rev-parse -q --verify "refs/heads/sync/upstream-$STAMP" >/dev/null || fail "the sync branch is on fork"
G -C "$W/fork.git" merge-base --is-ancestor "$UPHEAD" "sync/upstream-$STAMP" || fail "the sync branch contains upstream main"
assert_equals 2 "$(G -C "$W/fork.git" rev-list --parents -n 1 "sync/upstream-$STAMP" | wc -w | awk '{print $1-1}')" "the sync head is a --no-ff merge commit"
assert_equals "Fleet Captain" "$(G -C "$W/fork.git" log -1 --format=%an "sync/upstream-$STAMP")" "the merge uses the configured firstmate identity"
assert_not_contains "$(G -C "$W/fork.git" log -1 --format=%B "sync/upstream-$STAMP")" "Co-authored" "no co-author trailer"
pass "sync: a clean upstream merge becomes one pull request on a pushed branch, local main untouched"

# 4. same head not repeated; open sync PR stops another -------------------------
: > "$GH_LOG"
OUT=$(run_sync)
assert_contains "$OUT" "already handled" "the same upstream head is not handled twice"
assert_equals "" "$(cat "$GH_LOG")" "no second pull request for the same head"
commit_in "$W/seed" bin/up2.sh $'#!/usr/bin/env bash\necho up2\n' main
OUT=$(run_sync FAKE_GH_OPEN=1)
assert_contains "$OUT" "already open" "an open sync pull request blocks another"
assert_equals "" "$(cat "$GH_LOG")" "and none is created"
pass "sync: a handled head and an open sync pull request are not repeated"

# 5. conflict and syntax failure -------------------------------------------------
new_world conflict
commit_in "$W/home" notes.txt $'line1\nlocal side\n'
commit_in "$W/seed" notes.txt $'line1\nupstream side\n' main
MAIN_BEFORE=$(sha home main)
OUT=$(run_sync); CODE=$?
expect_code 0 "$CODE" "a conflict exits 0"
assert_contains "$OUT" "conflict" "the conflict is reported"
assert_equals "$MAIN_BEFORE" "$(sha fork.git main)" "main was published before the merge attempt"
REPORT="$W/home/data/upstream-sync/$STAMP.md"
assert_present "$REPORT" "a conflict report is written"
assert_grep "- notes.txt" "$REPORT" "the report lists the conflicting file"
assert_grep "Local main since the base:" "$REPORT" "the report has the local range"
assert_grep "Upstream main since the base:" "$REPORT" "the report has the upstream range"
assert_equals 1 "$(wc -l < "$CURL_LOG")" "one notice is sent"
assert_contains "$(cat "$CURL_LOG")" '"event":"upstream-sync-conflict"' "the notice names the event"
assert_not_contains "$(sed 's/.*--data //' "$CURL_LOG")" "not-a-real-key" "no secret is in the notice text"
assert_equals "$MAIN_BEFORE" "$(sha home main)" "local main is untouched"
assert_equals "" "$(G -C "$W/home" status --porcelain --untracked-files=no)" "the primary checkout stays clean"
assert_equals 1 "$(G -C "$W/home" worktree list | wc -l)" "the temporary worktree is removed after the abort"
assert_equals "" "$(G -C "$W/home" branch --list 'sync/*')" "no sync branch is left behind"
assert_equals "" "$(G -C "$W/fork.git" branch --list 'sync/*')" "nothing is pushed on a conflict"
assert_equals "" "$(cat "$GH_LOG")" "no pull request on a conflict"
OUT=$(run_sync)
assert_contains "$OUT" "already handled" "the conflicted head is not retried"
assert_equals 1 "$(wc -l < "$CURL_LOG")" "and no second notice is sent"
pass "sync: a conflict is aborted, reported once, remembered, and never pushed"

new_world syntax
commit_in "$W/seed" bin/bad.sh $'#!/usr/bin/env bash\nif then fi (\n' main
OUT=$(run_sync)
assert_contains "$OUT" "syntax check failed" "a bash -n failure stops the sync"
assert_grep "- bin/bad.sh" "$W/home/data/upstream-sync/$STAMP.md" "the report names the file"
assert_equals "" "$(G -C "$W/fork.git" branch --list 'sync/*')" "a failing merge is not pushed"
assert_equals "" "$(cat "$GH_LOG")" "and no pull request is opened"
pass "sync: a clean merge that fails bash -n is held back like a conflict"

# 6. dry run --------------------------------------------------------------------
new_world dry
commit_in "$W/home" bin/local.sh $'#!/usr/bin/env bash\necho local\n'
commit_in "$W/seed" bin/up.sh $'#!/usr/bin/env bash\necho up\n' main
FORK_BEFORE=$(sha fork.git main)
OUT=$(run_sync FM_UPSTREAM_SYNC_DRY=1)
assert_contains "$OUT" "would push main to fork" "dry run reports the publish"
assert_contains "$OUT" "would push sync/upstream-$STAMP" "dry run reports the pull request"
assert_equals "$FORK_BEFORE" "$(sha fork.git main)" "dry run does not push main"
assert_equals "" "$(G -C "$W/fork.git" branch --list 'sync/*')" "dry run does not push the sync branch"
assert_equals "" "$(cat "$GH_LOG")" "dry run opens no pull request"
assert_absent "$W/home/state/.upstream-sync.seen" "dry run records nothing as handled"
assert_equals 1 "$(G -C "$W/home" worktree list | wc -l)" "dry run cleans its worktree"
pass "sync: FM_UPSTREAM_SYNC_DRY=1 changes nothing on the remotes"

# 7. refused push and failed fetch ------------------------------------------------
new_world refused
commit_in "$W/home" bin/local.sh $'#!/usr/bin/env bash\necho local\n'
printf '#!/bin/sh\nexit 1\n' > "$W/fork.git/hooks/pre-receive"
chmod +x "$W/fork.git/hooks/pre-receive"
commit_in "$W/seed" bin/up.sh $'#!/usr/bin/env bash\necho up\n' main
OUT=$(run_sync); CODE=$?
expect_code 0 "$CODE" "a refused push exits 0"
assert_contains "$OUT" "push-refused" "the refusal is reported"
assert_equals "" "$(cat "$GH_LOG")" "the run stops before taking in upstream"
G -C "$W/home" remote set-url upstream "$W/does-not-exist.git"
OUT=$(run_sync); CODE=$?
expect_code 0 "$CODE" "a failed fetch exits 0"
assert_contains "$OUT" "fetch-failed" "the failed fetch is reported"
pass "sync: a refused push or failed fetch is reported and stops the run"

printf '# all fm-upstream-sync tests passed\n'
