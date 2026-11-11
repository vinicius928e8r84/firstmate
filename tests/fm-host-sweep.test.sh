#!/usr/bin/env bash
# Behavior tests for bin/fm-host-sweep.sh with fake hosts (a stand-in ssh runs each worker locally in its own fake world).
#
# World alpha is a full machine (kind vps): a home with live, ended, idle and secondmate tasks, stub lane/control scripts,
# a real git project with merged, squash-merged, unlanded, live and checked-out branches, a stub treehouse pool, /tmp dirs of
# ended and live tasks, dead pod logs, real orphan processes, and clones outside projects/. World beta is a Mac (kind mac).
# Pins:
#   1. --dry-run lists everything it would remove with bytes and removes nothing, writes no audit log;
#   2. --apply removes ONLY what the proofs allow and appends every removal to the audit log;
#   3. live tasks, secondmates, unlanded branches, dirty/unpushed/.env clones, protected names and young dirs are never touched;
#   4. the Mac sweep touches only /tmp task dirs and its testdirs; a host with no target is `unknown`, a dead one `unreachable`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-host-sweep.sh"
T=$(fm_test_tmproot fm-host-sweep)
FAKEBIN=$(fm_fakebin "$T")
A=$T/alpha; B=$T/beta; MAIN=$T/main
mkdir -p "$A"/root/bin "$A"/home/state "$A"/home/data "$A"/home/projects "$A"/tmp "$A"/hr "$A"/wt "$A"/pool \
  "$B"/tmp "$B"/tests "$MAIN"/config "$T"/home
alive() { kill -0 "$(cat "$1")" 2>/dev/null; }
has_branch() { git -C "$P" rev-parse --verify -q "$1" >/dev/null; }
old() { touch -d '10 days ago' "$@"; }
oldtree() { find "$1" -exec touch -d '10 days ago' {} +; }

# ---- stub firstmate scripts of the alpha root
cat > "$A/root/bin/fm-close-finished-lanes.sh" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" --apply "* ]]; then echo "closed: l1 (archive: x)"; else echo "would close: l1"; fi
echo "kept: l2 PR not merged (open)"
echo "kept: l3 not finished (state: working)"
SH
cat > "$A/root/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in l2|l1) echo "state: done · source: status-log · x" ;; *) echo "state: working · source: pane · x" ;; esac
SH
cat > "$A/root/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
echo "$1 $2" >> "${CONTROL_LOG:?}"
SH
chmod +x "$A"/root/bin/*.sh
export CONTROL_LOG="$T/control.log"; : > "$CONTROL_LOG"

# ---- alpha tasks
H=$A/home
mkdir -p "$A/wt/l1" "$A/wt/l2" "$A/wt/l3" "$A/tmp/fm-l3" "$A/tmp/fm-old1" "$A/tmp/fm-old1-fresh" "$A/tmp/fm-old1-Anki" "$A/tmp/fm-notatask" \
  "$H/data/old1" "$H/data/pod-logs-1" "$H/data/pod-logs-2"
echo x > "$A/wt/l1/f"; echo x > "$A/tmp/fm-old1/log"; echo x > "$A/tmp/fm-old1-Anki/log"; echo x > "$A/tmp/fm-l3/log"
echo x > "$A/tmp/fm-notatask/log"; echo x > "$A/tmp/fm-old1-fresh/log"; echo x > "$H/data/pod-logs-1/a.log"; echo x > "$H/data/pod-logs-2/a.log"
: > "$H/data/old1/launch-brief.md"
mk_task() {  # id kind status [branch]
  printf 'worktree=%s\nkind=%s\ntasktmp=%s\nbranch=%s\nproject=%s\n' "$A/wt/$1" "$2" "$A/tmp/fm-$1" "${4:-}" "$H/projects/proj" > "$H/state/$1.meta"
  echo "$3 [at=1]: x" > "$H/state/$1.status"
}
mk_task l1 ship "done"; mk_task l2 ship "done"; mk_task l3 ship working fm/l3
printf 'kind=secondmate\nhome=%s\nremote_host=elsewhere\n' "$T/smhome" > "$H/state/sm.meta"; echo "working [at=1]: x" > "$H/state/sm.status"
old "$H/state/l2.status"
old "$A/tmp/fm-old1" "$A/tmp/fm-old1/log" "$A/tmp/fm-old1-Anki" "$A/tmp/fm-old1-Anki/log" "$A/tmp/fm-l3" "$A/tmp/fm-l3/log" \
    "$A/tmp/fm-notatask" "$A/tmp/fm-notatask/log"
oldtree "$H/data/pod-logs-1"      # pod-logs-2 stays fresh

# ---- alpha project with branches
P=$H/projects/proj
git init -q -b main "$P"; git -C "$P" config user.email t@t; git -C "$P" config user.name t
echo base > "$P/base"; git -C "$P" add .; git -C "$P" commit -qm base
git -C "$P" branch fm/merged
git -C "$P" checkout -qb fm/squashed; echo same > "$P/x"; git -C "$P" add .; git -C "$P" commit -qm "add x"
git -C "$P" checkout -qb fm/unlanded main; echo u > "$P/u"; git -C "$P" add .; git -C "$P" commit -qm "unlanded"
git -C "$P" checkout -q main; echo same > "$P/x"; git -C "$P" add .; git -C "$P" commit -qm "add x (squash)"
git -C "$P" branch fm/l3; git -C "$P" branch fm/checked
git -C "$P" worktree add -q "$T/checked-wt" fm/checked

# ---- stub treehouse pool: five free slots (git clones of the project), one dirty
for i in 1 2 3 4 5; do git clone -q "$P" "$A/pool/$i" 2>/dev/null; done
echo dirty > "$A/pool/5/dirtyfile"
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
case "$1" in
  status) for i in 1 2 3 4 5; do printf '%s     available    %s\n' "$i" "$POOL/$i"; done ;;
  destroy) echo "destroy $2 $3" >> "${POOL_LOG:?}"; [ "${3:-}" = --yes ] && rm -rf "$2" ;;
esac
SH
chmod +x "$FAKEBIN/treehouse"; export POOL="$A/pool" POOL_LOG="$T/pool.log"; : > "$POOL_LOG"

# ---- clones outside projects/
HR=$A/hr
mkdir -p "$T/bare"
mkclone() {  # name
  git init -q --bare "$T/bare/$1.git"; git clone -q "$T/bare/$1.git" "$HR/$1" 2>/dev/null
  git -C "$HR/$1" config user.email t@t; git -C "$HR/$1" config user.name t
  echo c > "$HR/$1/f"; printf 'node_modules/\n.env\n' > "$HR/$1/.gitignore"; git -C "$HR/$1" add .
  GIT_COMMITTER_DATE='2026-01-01T00:00:00' GIT_AUTHOR_DATE='2026-01-01T00:00:00' git -C "$HR/$1" commit -qm c
  git -C "$HR/$1" push -q origin HEAD 2>/dev/null
}
for c in oldclone dirtyclone unpushed envclone youngclone; do mkclone $c; done
mkdir -p "$HR/oldclone/node_modules"; echo y > "$HR/oldclone/node_modules/m"
echo wip > "$HR/dirtyclone/new"
echo y > "$HR/unpushed/g"; git -C "$HR/unpushed" add .; GIT_COMMITTER_DATE='2026-01-01T00:00:00' git -C "$HR/unpushed" commit -qm local
echo SECRET > "$HR/envclone/.env"
for c in oldclone dirtyclone unpushed envclone; do oldtree "$HR/$c"; done

# ---- orphan processes (real): one in an ended task's worktree, one in a live task's, one protected by name
cp "$(command -v sleep)" "$A/wt/l1/node"; cp "$(command -v sleep)" "$A/wt/l3/node"
# The parent is a bash named `systemd`, which is how a parent-less process looks under a user manager (a bare reparent
# would land on the test runner's own subreaper instead of init).
cp "$(command -v bash)" "$T/systemd"
spawn_orphan() {  # dir pidfile
  # shellcheck disable=SC2016  # the single-quoted script expands in the stand-in parent
  ( cd "$1" && setsid "$T/systemd" -c './node 600 >/dev/null 2>&1 & echo $! > "$1"; wait' _ "$2" >/dev/null 2>&1 < /dev/null & )
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$2" ] && break; sleep 0.2; done
}
spawn_orphan "$A/wt/l1" "$T/p-ended"; spawn_orphan "$A/wt/l3" "$T/p-live"
mkdir -p "$A/wt/l1/Anki-profile"; cp "$(command -v sleep)" "$A/wt/l1/Anki-profile/node"
spawn_orphan "$A/wt/l1/Anki-profile" "$T/p-anki"
cleanup() { for f in "$T"/p-*; do [ -s "$f" ] && kill "$(cat "$f")" 2>/dev/null; done; pkill -f "$T/systemd" 2>/dev/null; pkill -f "$T/holder" 2>/dev/null; git -C "$P" worktree remove --force "$T/checked-wt" 2>/dev/null; true; }
trap cleanup EXIT
sleep 0.5
PPID_ENDED=$(ps -o ppid= -p "$(cat "$T/p-ended")" | tr -d ' ')
[ "$(ps -o comm= -p "$PPID_ENDED" 2>/dev/null | tr -d ' ')" = systemd ] || fail "the stand-in parent is not named systemd"
HAVE_ORPHANS=1

# ---- beta (Mac)
mkdir -p "$B/tmp/fm-macold" "$B/tmp/fm-macfresh" "$B/tests/olddir" "$B/tests/newdir" "$B/home-keep"
echo x > "$B/tmp/fm-macold/f"; echo x > "$B/tmp/fm-macfresh/f"; echo x > "$B/tests/olddir/f"; echo x > "$B/tests/newdir/f"; echo x > "$B/home-keep/f"
old "$B/tmp/fm-macold" "$B/tmp/fm-macold/f" "$B/tests/olddir" "$B/tests/olddir/f"

# ---- stand-in ssh: per-target world and env, 255 for the dead host
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
target=$1; shift
case "$target" in
  alpha-host) export FM_SWEEP_TMP="$WORLD_A/tmp" FM_SWEEP_HOME_ROOT="$WORLD_A/hr" ;;
  beta-host)  export FM_SWEEP_TMP="$WORLD_B/tmp" FM_SWEEP_HOME_ROOT="$WORLD_B/home-keep" ;;
  *) exit 255 ;;
esac
exec bash -c "$*"
SH
chmod +x "$FAKEBIN/ssh"
# stand-ins for the socket table and the Chrome debugging endpoint: no clients unless $FAKE_SS_CLIENTS names a file
cat > "$FAKEBIN/ss" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_SS_CLIENTS:-}" ] || [ ! -f "$FAKE_SS_CLIENTS" ] || cat "$FAKE_SS_CLIENTS"
exit 0
SH
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"/json/list"*) cat "${CDP_LIST:?}" ;;
  *"-X PUT"*) echo "$*" >> "${CDP_LOG:?}" ;;
esac
SH
chmod +x "$FAKEBIN/ss" "$FAKEBIN/curl"
CDP_LIST=$T/cdp-list.json; CDP_LOG=$T/cdp.log; : > "$CDP_LOG"; : > "$CDP_LIST"; export CDP_LIST CDP_LOG
# stand-ins for the socket table and the Chrome debugging endpoint: no clients unless $FAKE_SS_CLIENTS is a file
cat > "$FAKEBIN/ss" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_SS_CLIENTS:-}" ] || [ ! -f "$FAKE_SS_CLIENTS" ] || cat "$FAKE_SS_CLIENTS"
exit 0
SH
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"/json/list"*) cat "${CDP_LIST:?}" ;;
  *"-X PUT"*) echo "$*" >> "${CDP_LOG:?}" ;;
esac
SH
chmod +x "$FAKEBIN/ss" "$FAKEBIN/curl"
CDP_LIST=$T/cdp-list.json; CDP_LOG=$T/cdp.log; : > "$CDP_LOG"; export CDP_LIST CDP_LOG
{
  printf '# name kind target root homes testdirs\n'
  printf 'alpha vps alpha-host %s %s\n' "$A/root" "$H"
  printf 'beta mac beta-host - - %s\n' "$B/tests"
  printf 'gamma pc alpha-host %s %s\n' "$A/root" "$H"
  printf 'ghost vps down-host /x /y\n'
  printf 'nomac mac none - -\n'
} > "$MAIN/config/host-sweep.hosts"

run() {  # args...
  env HOME="$T/home" PATH="$FAKEBIN:$PATH" CDP_LIST="$CDP_LIST" CDP_LOG="$CDP_LOG" FAKE_SS_CLIENTS="${FAKE_SS_CLIENTS:-}" WORLD_A="$A" WORLD_B="$B" CONTROL_LOG="$CONTROL_LOG" POOL="$POOL" POOL_LOG="$POOL_LOG" \
    FM_HOME="$MAIN" FM_SWEEP_HOSTS="$MAIN/config/host-sweep.hosts" FM_SWEEP_SSH_TIMEOUT=5 \
    FM_SWEEP_LOAD="${LOAD:-0}" FM_SWEEP_CORES="${CORES:-64}" FM_SWEEP_PROC_SCOPE="$T/" FM_SWEEP_NOTIFY_CMD="$NOTIFY_STUB" \
    bash "$TOOL" --proc-min-age 0 --test-min-age 0 --pool-keep 1 --clone-days 5 ${VERBOSE:+--verbose} "$@" 2>"$T/err"
}
LOG=$MAIN/data/sweep/removed.tsv
NOTIFY_STUB=$T/notify-stub; NOTIFY_LOG=$T/notify.log; : > "$NOTIFY_LOG"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$NOTIFY_LOG" > "$NOTIFY_STUB"; chmod +x "$NOTIFY_STUB"

# ======== 1. dry run
OUT=$(run --dry-run); CODE=$?
expect_code 0 "$CODE" "dry-run succeeds"
assert_contains "$OUT" "alpha" "alpha is reported"
assert_contains "$OUT" "ghost      unreachable" "a dead host is reported unreachable"
assert_contains "$OUT" "nomac      unknown" "a host with no target is reported unknown"
assert_contains "$OUT" "would lanes $H:l1" "the finished lane would close"
assert_contains "$OUT" "would lanes $H:l2" "the finished but kept lane would have its agent exited"
assert_contains "$OUT" "would branches $P:fm/merged" "a merged branch would go"
assert_contains "$OUT" "would branches $P:fm/squashed" "a squash-merged branch would go (merge-tree proof)"
assert_contains "$OUT" "would tmp $A/tmp/fm-old1 " "an ended task's tmp would go"
assert_contains "$OUT" "would clones $HR/oldclone" "an old clean pushed clone would go"
assert_contains "$OUT" "would pool $A/pool/1" "a free clean pool worktree would go"
assert_contains "$OUT" "would tmp $B/tests/olddir" "the Mac test folder entry would go"
if [ "$HAVE_ORPHANS" = 1 ]; then assert_contains "$OUT" "would procs pid $(cat "$T/p-ended")" "the orphan in an ended worktree would be ended"; fi
assert_absent "$LOG" "a dry run writes no audit log"
assert_present "$A/tmp/fm-old1" "dry run kept the tmp dir"
has_branch fm/merged || fail "dry run deleted a branch"
assert_present "$HR/oldclone" "dry run kept the clone"
assert_equals "" "$(cat "$CONTROL_LOG")" "dry run exited no agent"
assert_equals "" "$(cat "$POOL_LOG")" "dry run destroyed no worktree"
alive "$T/p-ended" || fail "dry run killed a process"
pass "host-sweep: dry run lists what would go and changes nothing"

# ======== 2. apply
OUT=$(run --apply); CODE=$?
expect_code 0 "$CODE" "apply succeeds"
assert_absent "$A/tmp/fm-old1" "ended task tmp removed"
assert_absent "$H/data/pod-logs-1" "dead pod log dir removed"
assert_absent "$HR/oldclone" "clean pushed old clone removed"
assert_absent "$B/tests/olddir" "old Mac test entry removed"
assert_absent "$B/tmp/fm-macold" "old Mac tmp dir removed"
has_branch fm/merged && fail "merged branch kept"
has_branch fm/squashed && fail "squash-merged branch kept"
assert_contains "$(cat "$CONTROL_LOG")" "l2 exit" "the finished idle lane's agent was exited"
assert_contains "$(cat "$POOL_LOG")" "destroy $A/pool/1 --yes" "the free pool worktree went through treehouse destroy without include flags"
if [ "$HAVE_ORPHANS" = 1 ]; then
  alive "$T/p-ended" && fail "the orphan in an ended worktree survived"
fi
assert_present "$A/tmp/fm-l3" "live task tmp kept"
assert_present "$A/tmp/fm-old1-fresh" "fresh tmp kept"
assert_present "$A/tmp/fm-old1-Anki" "protected name kept"
assert_present "$A/tmp/fm-notatask" "a dir that is no task's tmp kept"
assert_present "$H/data/pod-logs-2" "fresh pod log kept"
assert_present "$HR/dirtyclone" "dirty clone kept"
assert_present "$HR/unpushed" "clone with unpushed commits kept"
assert_present "$HR/envclone/.env" "clone with an ignored .env kept"
assert_present "$HR/youngclone" "recently used clone kept"
assert_present "$B/tmp/fm-macfresh" "fresh Mac tmp kept"
assert_present "$B/tests/newdir" "new Mac test entry kept"
assert_present "$B/home-keep/f" "the Mac sweep never leaves /tmp and the test folders"
for b in fm/unlanded fm/l3 fm/checked main; do
  has_branch "$b" || fail "branch $b was deleted"
done
assert_present "$A/pool/5/dirtyfile" "dirty pool worktree kept"
assert_not_contains "$(cat "$CONTROL_LOG")" "l3 " "a live task's agent is never exited"
assert_not_contains "$(cat "$CONTROL_LOG")" "sm " "a secondmate is never touched"
alive "$T/p-live" || fail "a live task's process was killed"
alive "$T/p-anki" || fail "a protected process was killed"
assert_present "$LOG" "apply writes the audit log"
assert_contains "$(cat "$LOG")" "$A/tmp/fm-old1" "the log names the removed tmp dir"
assert_contains "$(cat "$LOG")" "merge-base" "the log carries the proof"
assert_equals 1 "$(grep -c "$HR/oldclone" "$LOG")" "each removal is logged once"
assert_not_contains "$(cat "$LOG")" "dirtyclone" "kept things are not logged as removed"
pass "host-sweep: apply removes only what the proofs allow, and logs every removal"

# ======== 3. a second apply finds nothing new to remove
# (the stub lane script reports the same lane every time, so lanes are left out of the comparison)
LINES=$(grep -vc "	lanes	" "$LOG")
run --apply >/dev/null
assert_equals "$LINES" "$(grep -vc "	lanes	" "$LOG")" "a second apply removes nothing more"
pass "host-sweep: apply is idempotent"

# ======== 4. --host selects one machine; bad usage
OUT=$(run --dry-run --host beta)
assert_not_contains "$OUT" "alpha " "--host limits the sweep"
run --idle-hours x >/dev/null; expect_code 64 "$?" "a non-number is a usage error"
run --bogus >/dev/null; expect_code 64 "$?" "an unknown flag is a usage error"
pass "host-sweep: usage"

# ======== 5. the cleanup expansion: orphan test runs, preview servers, unlanded work listed, rules armed or not
# A vitest run whose parent is gone, outside any task: ended only by an armed apply. A preview server inside an ended task's worktree.
mkdir -p "$A/vt" "$A/wt/l1/srv"; cp "$(command -v bash)" "$A/vt/node"; cp "$(command -v bash)" "$A/wt/l1/srv/node"
# (the stand-ins block on a fifo read inside bash itself: `-c "sleep"` would exec into sleep and lose the node name)
mkfifo "$A/vt/fifo" "$A/wt/l1/srv/fifo"
# shellcheck disable=SC2016  # the single-quoted script expands in the stand-in parent
( cd "$A/vt" && setsid "$T/systemd" -c './node -c "read -r _ < fifo" vitest & echo $! > "$1"; wait' _ "$T/p-vitest" >/dev/null 2>&1 < /dev/null & )
cp "$(command -v bash)" "$T/holder"   # a live parent: the older orphan rule must not be the one judging the preview
# shellcheck disable=SC2016  # the single-quoted script expands in the stand-in parent
( cd "$A/wt/l1/srv" && setsid "$T/holder" -c './node -c "read -r _ < fifo" servir.mjs 4999 & echo $! > "$1"; wait' _ "$T/p-preview" >/dev/null 2>&1 < /dev/null & )
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/p-vitest" ] && [ -s "$T/p-preview" ] && break; sleep 0.2; done
sleep 0.5
OUT=$(run --dry-run)
assert_contains "$OUT" "would tests pid $(cat "$T/p-vitest")" "an orphan test run would be ended"
assert_contains "$OUT" "would previews pid $(cat "$T/p-preview")" "a preview server of an ended task would be ended"
assert_contains "$OUT" "branch:$P:fm/unlanded" "unlanded work is only listed"
assert_not_contains "$OUT" "would branches $P:fm/unlanded" "unlanded work is never offered for removal"
assert_contains "$OUT" "waiting for the owner's OK" "the report counts what waits for the owner"
assert_contains "$OUT" "new rules not armed" "the report says the new rules are a simulation"
alive "$T/p-vitest" || fail "a dry run ended the orphan test run"
# apply without arming: still a simulation for the new rules
OUT=$(run --apply)
alive "$T/p-vitest" || fail "apply without --armed ended an orphan test run"
alive "$T/p-preview" || fail "apply without --armed ended a preview server"
assert_contains "$OUT" "rules not armed: simulation" "an unarmed apply says so on the item"
# armed apply
OUT=$(run --apply --armed)
sleep 1
alive "$T/p-vitest" && fail "armed apply left the orphan test run"
alive "$T/p-preview" && fail "armed apply left the preview server of an ended task"
alive "$T/p-live" || fail "armed apply ended a live task's process"
alive "$T/p-anki" || fail "armed apply ended a protected process"
has_branch fm/unlanded || fail "unlanded work was removed"
assert_contains "$(cat "$LOG")" "orphan test run" "the armed removal is logged with its proof"
# the config file arms it too, and deleting it disarms again
touch "$MAIN/config/host-sweep.rules-armed"
OUT=$(run --dry-run); assert_not_contains "$OUT" "new rules not armed" "config/host-sweep.rules-armed arms the rules"
rm -f "$MAIN/config/host-sweep.rules-armed"
OUT=$(run --dry-run); assert_contains "$OUT" "new rules not armed" "removing the file disarms them"
pass "host-sweep: the added rules simulate until armed, then end only pid-proved leftovers"

# ======== 6. passes and the load gate
# (the earlier apply removed the old leftovers: put one back)
mkdir -p "$A/tmp/fm-old1"; echo x > "$A/tmp/fm-old1/log"; old "$A/tmp/fm-old1" "$A/tmp/fm-old1/log"
OUT=$(run --dry-run --pass light)
assert_not_contains "$OUT" "would tmp $A/tmp/fm-old1" "the light pass does no disk sweep"
assert_contains "$OUT" "would lanes $H:l1" "the light pass sweeps agents"
OUT=$(run --dry-run --pass disk)
assert_contains "$OUT" "would tmp $A/tmp/fm-old1 " "the disk pass sweeps /tmp"
assert_not_contains "$OUT" "would lanes" "the disk pass leaves agents alone"
run --pass bogus >/dev/null; expect_code 64 "$?" "an unknown pass is a usage error"
OUT=$(LOAD=99 CORES=2 run --dry-run)
assert_not_contains "$OUT" "would tmp $A/tmp/fm-old1" "above the core count no disk sweep runs"
assert_not_contains "$OUT" "would lanes $H:l1" "above the core count no lane is closed (teardown frees disk, not memory)"
assert_contains "$OUT" "would lanes $H:l2" "above the core count an idle finished agent is still exited"
pass "host-sweep: light and disk passes, and the load gate"

# ======== 7. leftovers in state/, and tabs of the shared Chrome
ST=$H/state; hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
KEY_GONE="v3.$(printf '%s' 'vps:gone' | sha256sum | cut -d' ' -f1)"; KEY_LIVE="v3.$(printf '%s' 'vps:w9' | sha256sum | cut -d' ' -f1)"
echo 'window=vps:w9' >> "$H/state/l3.meta"
echo h > "$ST/.hash-vps_w3_p2"; echo h > "$ST/.stale-$KEY_GONE"; echo h > "$ST/.hash-$KEY_LIVE"; echo h > "$ST/.count-vps_w4_p2"
SEEN_OLD="$ST/.seen-procevent-$(hex 'procevent:lavish-0000:1')"; SEEN_QUEUED="$ST/.seen-procevent-$(hex 'procevent:lavish-1111:1')"
echo x > "$SEEN_OLD"; echo x > "$SEEN_QUEUED"; echo '{"k":"procevent:lavish-1111:1"}' > "$ST/.wake-queue"
echo x > "$ST/.claude-autoarm-epoch.tmp.123"; echo x > "$ST/fresh.tmp.9"
old "$ST/.hash-vps_w3_p2" "$SEEN_OLD" "$SEEN_QUEUED" "$ST/.claude-autoarm-epoch.tmp.123"
touch -d '5 days ago' "$ST/.stale-$KEY_GONE" "$ST/.hash-$KEY_LIVE"
touch -d '30 days ago' "$SEEN_OLD" "$SEEN_QUEUED"
run --apply --pass light >/dev/null
assert_present "$ST/.hash-vps_w3_p2" "an unarmed apply keeps the state/ leftovers"
OUT=$(run --apply --armed --pass light)
assert_absent "$ST/.hash-vps_w3_p2" "a watcher marker of the retired key scheme goes"
assert_absent "$ST/.stale-$KEY_GONE" "a v3 marker of a window no task names goes"
assert_absent "$SEEN_OLD" "a dedup record whose key left the queue goes"
assert_absent "$ST/.claude-autoarm-epoch.tmp.123" "an old temporary file goes"
assert_present "$ST/.hash-$KEY_LIVE" "the marker of a window a task record names stays"
assert_present "$ST/.count-vps_w4_p2" "a fresh marker stays"
assert_present "$SEEN_QUEUED" "a dedup record whose key is still queued stays"
assert_present "$ST/fresh.tmp.9" "a fresh temporary file stays"
assert_present "$ST/l3.meta" "task records are never touched"

# shared Chrome: a tab goes only after being seen on every pass for the window, with no client, never the last or an owner's page
printf '[{"id":"AAA","type":"page","url":"https://a.example/","title":"a"},{"id":"BBB","type":"page","url":"https://b.example/","title":"Opera GX"},{"id":"CCC","type":"page","url":"https://c.example/","title":"c"}]' > "$CDP_LIST"
export FM_SWEEP_CHROME_PORT=9222
run --apply --armed --pass light >/dev/null
assert_equals "" "$(cat "$CDP_LOG")" "a tab first seen is not closed"
assert_present "$ST/.sweep-chrome-tab-9222-AAA" "its first sighting is recorded"
echo $(( $(date +%s) - 13 * 3600 )) > "$ST/.sweep-chrome-tab-9222-AAA"; echo $(( $(date +%s) - 13 * 3600 )) > "$ST/.sweep-chrome-tab-9222-BBB"
printf 'ESTAB 0 0 127.0.0.1:9222 127.0.0.1:55555\n' > "$T/ss-clients"
OUT=$(FAKE_SS_CLIENTS="$T/ss-clients" run --apply --armed --pass light)
assert_equals "" "$(cat "$CDP_LOG")" "a connected client keeps every tab"
OUT=$(run --dry-run --pass light)
assert_contains "$OUT" "would chrome tab AAA" "an old tab with no client would close"
assert_not_contains "$OUT" "tab BBB" "an owner's page is not offered for closing"
assert_equals "" "$(cat "$CDP_LOG")" "a simulation closes nothing"
run --apply --pass light >/dev/null
assert_equals "" "$(cat "$CDP_LOG")" "an unarmed apply closes no tab"
run --apply --armed --pass light >/dev/null
assert_equals 1 "$(grep -c . "$CDP_LOG")" "the armed apply closes exactly one tab"
assert_contains "$(cat "$CDP_LOG")" "/json/close/AAA" "and it is the old idle one"
pass "host-sweep: state/ leftovers and idle Chrome tabs, with their guards"

# ======== 8. --notify: one line, only when something happened or waits
: > "$NOTIFY_LOG"
run --apply --armed --notify --host beta >/dev/null
assert_equals "" "$(cat "$NOTIFY_LOG")" "an empty round notifies nobody"
run --apply --pass disk --notify --host alpha >/dev/null
assert_equals 1 "$(grep -c . "$NOTIFY_LOG")" "a round with items waiting writes exactly one line"
assert_contains "$(cat "$NOTIFY_LOG")" "esperando seu OK" "the line says what waits for the owner"
assert_contains "$(cat "$NOTIFY_LOG")" "limpei" "and what was cleaned"
: > "$NOTIFY_LOG"
run --apply --pass disk --notify --host alpha >/dev/null
assert_equals "" "$(cat "$NOTIFY_LOG")" "an unchanged waiting list is not repeated within a day"
pass "host-sweep: notifies once, only when something changed or waits"

# ======== 9. the PC touches agent processes and terminals only
mkdir -p "$A/tmp/fm-old1" "$HR/oldclone"; echo x > "$A/tmp/fm-old1/log"; echo c > "$HR/oldclone/f"; echo h > "$ST/.hash-vps_w7_p2"
old "$A/tmp/fm-old1" "$A/tmp/fm-old1/log" "$ST/.hash-vps_w7_p2"
OUT=$(run --apply --armed --host gamma)
assert_present "$A/tmp/fm-old1" "the PC sweep leaves /tmp alone"
assert_present "$ST/.hash-vps_w7_p2" "the PC sweep leaves state/ alone"
assert_present "$HR/oldclone" "the PC sweep leaves clones alone"
assert_not_contains "$OUT" "removed tmp" "nothing from the disk sweeps is removed on the PC"
assert_not_contains "$OUT" "removed state" "no state/ file is removed on the PC"
OUT=$(run --apply --armed --host alpha --pass disk)
assert_absent "$A/tmp/fm-old1" "the same sweep on a vps does remove it"
pass "host-sweep: the PC sweeps agent processes and terminals only"

printf '# all fm-host-sweep tests passed\n'
