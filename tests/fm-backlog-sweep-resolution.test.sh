#!/usr/bin/env bash
# tests/fm-backlog-sweep-resolution.test.sh - the cheap path resolution that
# bin/fm-backlog-transition-lib.sh offers a sweep over many task records
# (fm_backlog_sweep_begin/end) and its use by bin/fm-bootstrap.sh's
# backlog reconciliation.
#
# The defect this pins: the reconcile sweep ran a perl realpath for every
# authorized directory and every record on every check, about nine per task,
# which kept session start busy for a minute on a 33-task home. Pinned here:
#   - inside the sweep the answers are the ones the ordinary checks give,
#     including a record swapped for a symlink, and a state directory swapped
#     for a link, after an earlier check passed (the re-check bin/fm-bootstrap.sh
#     makes after taking a task lock depends on this)
#   - a session start's perl realpath count no longer grows with the number of
#     task records, and it still moves a queued row for an owned record In flight
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-backlog-sweep-resolution-tests)
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"

# Count every `perl -MCwd=realpath` run, then run the real perl.
make_counting_perl() {  # <fakebin> <count-file>
  local real_perl
  real_perl=$(PATH="$BASE_PATH" command -v perl) || fail "perl not found"
  cat > "$1/perl" <<SH
#!/usr/bin/env bash
case "\${1:-}" in -MCwd=realpath) echo x >> "$2" ;; esac
exec "$real_perl" "\$@"
SH
  chmod +x "$1/perl"
}

count_of() {  # <count-file>
  if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}

# --- library: same answers, fewer resolutions -------------------------------

# Run a checks script inside one bash with the library sourced, printing
# "<label> <status> <error>" per check and the realpath count at the end.
run_checks() {  # <case-dir> <use-sweep: 0|1> -> prints results
  local case_dir=$1 use_sweep=$2 fakebin count
  fakebin=$(fm_fakebin "$case_dir")
  count="$case_dir/perl.count"
  rm -f "$count"
  make_counting_perl "$fakebin" "$count"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" bash -c '
    . "$1/bin/fm-backlog-transition-lib.sh"
    state=$2/home/state
    check() {
      FM_BACKLOG_TRANSITION_ERROR=
      if fm_backlog_record_present "$1" "task record" "$state"; then
        printf "%s ok\n" "$(basename "$1")"
      else
        printf "%s refused %s\n" "$(basename "$1")" "$FM_BACKLOG_TRANSITION_ERROR"
      fi
    }
    [ "$3" = 0 ] || fm_backlog_sweep_begin
    for i in 1 2 3 4 5 6; do check "$state/t$i.meta"; done
    check "$state/t1.meta"
    # A record swapped for a link after it passed once, inside the same sweep.
    rm -f "$state/t2.meta" && ln -s "$state/t3.meta" "$state/t2.meta"
    check "$state/t2.meta"
    # A record that is a link leaving the authorized directory.
    check "$state/escape.meta"
    check "$state/missing.meta"
    [ "$3" = 0 ] || fm_backlog_sweep_end
  ' _ "$ROOT" "$case_dir" "$use_sweep"
  printf 'perl_realpath_runs %s\n' "$(count_of "$count")"
}

make_lib_case() {  # <name>
  local case_dir=$TMP_ROOT/$1 i
  mkdir -p "$case_dir/home/state" "$case_dir/outside"
  for i in 1 2 3 4 5 6; do printf 'kind=ship\n' > "$case_dir/home/state/t$i.meta"; done
  printf 'kind=ship\n' > "$case_dir/outside/real.meta"
  ln -s "$case_dir/outside/real.meta" "$case_dir/home/state/escape.meta"
  printf '%s\n' "$case_dir"
}

test_sweep_gives_the_same_answers_with_far_fewer_perl_runs() {
  local plain swept plain_runs sweep_runs
  plain=$(run_checks "$(make_lib_case lib-plain)" 0)
  swept=$(run_checks "$(make_lib_case lib-sweep)" 1)
  assert_equals "$(printf '%s\n' "$plain" | grep -v '^perl_realpath_runs' | sed "s|$TMP_ROOT/lib-[a-z]*|CASE|g")" \
    "$(printf '%s\n' "$swept" | grep -v '^perl_realpath_runs' | sed "s|$TMP_ROOT/lib-[a-z]*|CASE|g")" \
    "the sweep must not change any check's answer"
  assert_contains "$plain" "t2.meta refused" "a record swapped for a link is refused outside the sweep"
  assert_contains "$swept" "t2.meta refused task record resolves through a different final path" \
    "a record swapped for a link is still refused inside the sweep"
  assert_contains "$swept" "escape.meta refused" "a link leaving the authorized directory is refused inside the sweep"
  assert_contains "$swept" "missing.meta refused task record is not a regular file" \
    "an absent record is refused inside the sweep"
  plain_runs=$(printf '%s\n' "$plain" | sed -n 's/^perl_realpath_runs //p')
  sweep_runs=$(printf '%s\n' "$swept" | sed -n 's/^perl_realpath_runs //p')
  [ "$plain_runs" -ge 20 ] || fail "the ordinary checks should resolve per check, got $plain_runs"
  [ "$sweep_runs" -le 8 ] || fail "the sweep still resolved $sweep_runs times for 10 checks (baseline $plain_runs)"
  pass "fm_backlog_sweep_begin: same answers, $sweep_runs resolutions instead of $plain_runs"
}

test_sweep_sees_a_state_directory_swapped_after_an_earlier_check() {
  local case_dir fakebin out
  case_dir=$(make_lib_case lib-swap)
  fakebin=$(fm_fakebin "$case_dir")
  make_counting_perl "$fakebin" "$case_dir/perl.count"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" bash -c '
    . "$1/bin/fm-backlog-transition-lib.sh"
    state=$2/home/state
    fm_backlog_sweep_begin
    fm_backlog_record_present "$state/t1.meta" "task record" "$state" && echo "first check ok"
    mv "$state" "$state.moved" && ln -s "$2/outside" "$state"
    cp "$2/outside/real.meta" "$2/outside/t1.meta"
    if fm_backlog_record_present "$state/t1.meta" "task record" "$state"; then
      echo "accepted the swapped directory"
    else
      echo "refused: $FM_BACKLOG_TRANSITION_ERROR"
    fi
    fm_backlog_sweep_end
  ' _ "$ROOT" "$case_dir" > "$case_dir/out" 2>&1
  out=$(cat "$case_dir/out")
  assert_contains "$out" "first check ok" "the record passes before the swap"
  assert_not_contains "$out" "accepted the swapped directory" "a state directory swapped for a link must be refused inside the sweep"
  assert_contains "$out" "refused: task record authorized directory resolves outside this home" \
    "the swapped directory is named as leaving this home"
  pass "fm_backlog_sweep_begin: a directory swapped after an earlier check is refused"
}

# --- bootstrap: the sweep's resolutions do not grow with the records --------

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped the session-start cases (tasks-axi is not installed)\n'
  fm_test_run test_sweep_gives_the_same_answers_with_far_fewer_perl_runs \
    test_sweep_sees_a_state_directory_swapped_after_an_earlier_check
  exit 0
}

# A home with <count> task records, all but the last queued rows In flight, the
# last left Queued so the sweep has one row to move.
make_sweep_home() {  # <name> <count> -> prints the case dir
  local case_dir=$TMP_ROOT/$1 home i id fakebin
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$home/.tasks.toml"
  for i in $(seq 1 "$2"); do
    id=sweep-$i
    tasks-axi add "$id" "item $i" --kind ship --file "$home/data/backlog.md" >/dev/null
    [ "$i" = "$2" ] || tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
    printf 'kind=ship\nspawn_gen=g%s\n' "$i" > "$home/state/$id.meta"
  done
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes
  make_counting_perl "$fakebin" "$case_dir/perl.count"
  printf '%s\n' "$case_dir"
}

run_sweep() {  # <case-dir> -> prints bootstrap output
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" FM_BOOTSTRAP_NETWORK=skip \
    PATH="$case_dir/fakebin:$PATH" "$BOOTSTRAP" 2>&1
}

test_session_start_resolutions_do_not_grow_with_records() {
  local small large out small_runs large_runs last
  small=$(make_sweep_home sweep-small 4)
  large=$(make_sweep_home sweep-large 16)
  run_sweep "$small" > "$small/out" || true
  out=$(run_sweep "$large") || true
  small_runs=$(count_of "$small/perl.count")
  large_runs=$(count_of "$large/perl.count")
  [ "$large_runs" -le $((small_runs + 3)) ] \
    || fail "perl realpath runs grew with the records: $small_runs for 4, $large_runs for 16"
  assert_contains "$out" "BOOTSTRAP_INFO: marked sweep-16 in flight to match the worker this home already owns" \
    "the sweep must still move the queued row for the owned record"
  last=$(tasks-axi show sweep-16 --file "$large/home/data/backlog.md" | sed -n 's/^  state: *//p' | head -1)
  assert_equals in_flight "$last" "the queued row ends In flight"
  pass "fm-bootstrap.sh: $small_runs perl realpath runs for 4 records, $large_runs for 16, queued row still healed"
}

fm_test_run \
  test_sweep_gives_the_same_answers_with_far_fewer_perl_runs \
  test_sweep_sees_a_state_directory_swapped_after_an_earlier_check \
  test_session_start_resolutions_do_not_grow_with_records
