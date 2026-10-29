#!/usr/bin/env bash
# tests/fm-decision-autoclose.test.sh - ghost OPEN DECISIONS close by fact.
# bin/fm-decision-autoclose.sh closes a decision whose task is gone (no
# state/<task>.meta, data/<task>/ left behind) or whose pending-reply
# destination is retired, and never one whose task is still live. These tests
# run the real script and the real drain over crafted homes.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
AUTOCLOSE="$ROOT/bin/fm-decision-autoclose.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-autoclose-tests)

make_home() {  # <name> -> prints a scratch FM_HOME
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/data" "$dir/config"
  printf '%s\n' "$dir"
}

run_autoclose() {  # <home> [args...]
  local dir=$1
  shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" "$AUTOCLOSE" "$@"
}

test_gone_task_decision_is_closed() {
  local dir out
  dir=$(make_home gone)
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/state/gone1.status"
  mkdir -p "$dir/data/gone1"
  out=$(run_autoclose "$dir") || fail "autoclose failed"
  case "$out" in *"closed: gone1 [key=api-shape]"*) ;; *) fail "no close reported: $out" ;; esac
  grep -E '^resolved \[key=api-shape\] \[at=[0-9]+\]: auto-closed by fact: task gone1 is gone' "$dir/state/gone1.status" >/dev/null \
    || fail "exact resolved line missing: $(cat "$dir/state/gone1.status")"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" "$DRAIN") || fail "drain failed"
  case "$out" in *"OPEN DECISIONS"*) fail "closed decision still listed: $out" ;; esac
  pass "a decision of a torn-down task is closed with an exact resolved line"
}

test_live_task_decision_is_never_closed() {
  local dir out
  dir=$(make_home live)
  printf 'needs-decision [key=k]: still asking\n' > "$dir/state/live1.status"
  mkdir -p "$dir/data/live1"
  : > "$dir/state/live1.meta"
  out=$(run_autoclose "$dir") || fail "autoclose failed"
  [ -z "$out" ] || fail "a live task's decision was touched: $out"
  [ "$(wc -l < "$dir/state/live1.status")" -eq 1 ] || fail "status log changed for a live task"
  pass "a decision whose task still has its meta is left open"
}

test_task_without_data_dir_is_not_proof() {
  local dir out
  dir=$(make_home nodata)
  printf 'blocked: waiting\n' > "$dir/state/ghostly.status"
  out=$(run_autoclose "$dir") || fail "autoclose failed"
  [ -z "$out" ] || fail "closed with no proof the task existed: $out"
  pass "a bare status log with no task data is not closed"
}

test_dry_run_changes_nothing_and_default_key_closes() {
  local dir out
  dir=$(make_home dry)
  printf 'blocked: waiting for a host\n' > "$dir/state/dry1.status"
  mkdir -p "$dir/data/dry1"
  out=$(run_autoclose "$dir" --dry-run) || fail "dry run failed"
  case "$out" in "would-close: dry1 auto-closed"*) ;; *) fail "dry run output wrong: $out" ;; esac
  [ "$(wc -l < "$dir/state/dry1.status")" -eq 1 ] || fail "dry run wrote to the status log"
  run_autoclose "$dir" >/dev/null || fail "autoclose failed"
  grep -E '^resolved \[at=[0-9]+\]: auto-closed' "$dir/state/dry1.status" >/dev/null || fail "default-key close missing"
  [ -z "$(run_autoclose "$dir")" ] || fail "second run was not idempotent"
  pass "dry run is read-only; a keyless decision closes with a keyless resolved line"
}

test_pending_reply_to_retired_destination_closes() {
  local dir out rec corr=aaaaaaaaaaaaaaaa
  dir=$(make_home pending)
  mkdir -p "$dir/state/pending-replies" "$dir/data/retired-mate"
  rec="$dir/state/pending-replies/$corr"
  {
    printf 'schema=fm-pending-reply.v1\ncorr_id=%s\ntask_id=retired-mate\n' "$corr"
    printf 'parent_home=%s\nparent_status=%s\n' "$dir" "$dir/state/retired-mate.status"
    printf 'request_summary=resume the proof\nphase=escalated\nescalated_epoch=1500\nrecovery_delivery_outcome=failed\n'
  } > "$rec"
  printf 'blocked [key=pending-reply-%s] [at=1500]: pending-reply-recovery-delivery-failed: task=retired-mate pending-reply-id=%s request=resume the proof\n' "$corr" "$corr" > "$dir/state/retired-mate.status"
  run_autoclose "$dir" --dry-run | grep -F "would-close: retired-mate [key=pending-reply-$corr]" >/dev/null \
    || fail "dry run did not name the ghost pending reply"
  out=$(run_autoclose "$dir") || fail "autoclose failed"
  case "$out" in *"closed: retired-mate [key=pending-reply-$corr]"*) ;; *) fail "pending reply not closed: $out" ;; esac
  grep -F 'resolved_via=ghost-close' "$rec" >/dev/null || fail "record not resolved via ghost-close"
  pass "a pending reply whose destination has no meta closes through the guarded ghost close"
}

test_pending_reply_without_task_data_stays_open() {
  local dir out corr=cccccccccccccccc
  dir=$(make_home pending-nodata)
  mkdir -p "$dir/state/pending-replies"
  {
    printf 'schema=fm-pending-reply.v1\ncorr_id=%s\ntask_id=never-spawned\n' "$corr"
    printf 'parent_home=%s\nparent_status=%s\n' "$dir" "$dir/state/never-spawned.status"
    printf 'request_summary=resume the proof\nphase=escalated\nescalated_epoch=1500\nrecovery_delivery_outcome=failed\n'
  } > "$dir/state/pending-replies/$corr"
  printf 'blocked [key=pending-reply-%s] [at=1500]: pending-reply-recovery-delivery-failed: task=never-spawned pending-reply-id=%s request=resume the proof\n' "$corr" "$corr" > "$dir/state/never-spawned.status"
  out=$(run_autoclose "$dir") || fail "autoclose failed"
  [ -z "$out" ] || fail "closed a pending reply with no proof the task existed: $out"
  pass "a pending reply with no task data is not closed"
}

test_pending_reply_to_live_destination_stays_open() {
  local dir out corr=bbbbbbbbbbbbbbbb
  dir=$(make_home pending-live)
  mkdir -p "$dir/state/pending-replies" "$dir/data/live-mate"
  {
    printf 'schema=fm-pending-reply.v1\ncorr_id=%s\ntask_id=live-mate\n' "$corr"
    printf 'parent_home=%s\nparent_status=%s\n' "$dir" "$dir/state/live-mate.status"
    printf 'request_summary=resume the proof\nphase=escalated\nescalated_epoch=1500\nrecovery_delivery_outcome=failed\n'
  } > "$dir/state/pending-replies/$corr"
  : > "$dir/state/live-mate.meta"
  printf 'blocked [key=pending-reply-%s] [at=1500]: pending-reply-recovery-delivery-failed: task=live-mate pending-reply-id=%s request=resume the proof\n' "$corr" "$corr" > "$dir/state/live-mate.status"
  out=$(run_autoclose "$dir") || fail "autoclose failed"
  [ -z "$out" ] || fail "a live destination's decision was closed: $out"
  pass "a pending reply to a live destination stays open"
}

test_gone_task_decision_is_closed
test_live_task_decision_is_never_closed
test_task_without_data_dir_is_not_proof
test_dry_run_changes_nothing_and_default_key_closes
test_pending_reply_to_retired_destination_closes
test_pending_reply_to_live_destination_stays_open
test_pending_reply_without_task_data_stays_open
