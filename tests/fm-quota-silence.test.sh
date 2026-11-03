#!/usr/bin/env bash
# tests/fm-quota-silence.test.sh - behavior tests for bin/fm-quota-silence-lib.sh:
# while the configured account's usage limit is exhausted the watcher holds its
# wake until the reset, and everything else (no config, a healthy quota, a reset
# already past, an away record, an unreadable quota-axi) wakes at once. The
# tests run the real library and the real wake() over a fake quota-axi.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-silence)

# fake_axi <dir> <percent-remaining> <resets-in-seconds> [<schema-6-account-key>]
# Writes <dir>/quota-axi printing one claude row; each run is counted in <dir>/calls.
fake_axi() {
  local dir=$1 pct=$2 resets_in=$3 key=${4:-} reset runway=through_reset schema=5 keyfield=''
  reset=$(date -u -d "@$(( $(date +%s) + resets_in ))" +%Y-%m-%dT%H:%M:%S.000000+00:00)
  [ "$pct" -ne 0 ] || runway=exhausted_now
  [ -z "$key" ] || { schema=6; keyfield="\"accountKey\":\"$key\","; }
  cat > "$dir/quota-axi" <<SH
#!/usr/bin/env bash
echo run >> '$dir/calls'
cat <<'JSON'
{"schemaVersion":$schema,"providers":[{"provider":"claude",$keyfield"windows":[{"id":"five_hour","resetsAt":"$reset","percentRemaining":$pct}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":$pct,"limitingWindowIds":["five_hour"],"runway":{"status":"$runway"}}]}}]}
JSON
SH
  chmod +x "$dir/quota-axi"
  : > "$dir/calls"
}

# run_wake <dir> -> prints "<elapsed-seconds> <wake output>" for one real wake()
run_wake() {
  local dir=$1 start out
  start=$(date +%s)
  out=$(
    export STATE="$dir/state" CONFIG="$dir/config" FM_QUOTA_SILENCE_AXI="$dir/quota-axi" FM_QUOTA_SILENCE_SLICE=1
    # shellcheck source=bin/fm-push-transition-lib.sh
    . "$ROOT/bin/fm-push-transition-lib.sh"
    # shellcheck source=bin/fm-quota-silence-lib.sh
    . "$ROOT/bin/fm-quota-silence-lib.sh"
    wake "signal: x.status"
  )
  printf '%s %s\n' $(( $(date +%s) - start )) "$out"
}

new_case() { # <name> -> case dir with state/ and config/
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config"
  printf '%s\n' "$dir"
}

test_exhausted_limit_holds_the_wake_until_the_reset() {
  local dir out elapsed
  dir=$(new_case hold)
  printf 'claude\n' > "$dir/config/quota-silence"
  fake_axi "$dir" 0 4
  out=$(run_wake "$dir")
  elapsed=${out%% *}
  [ "$elapsed" -ge 3 ] || fail "wake was not held until the reset (elapsed ${elapsed}s): $out"
  [ "$elapsed" -le 12 ] || fail "wake was held far past the reset (elapsed ${elapsed}s): $out"
  [ "${out#* }" = "signal: x.status" ] || fail "the held wake lost its reason: $out"
  grep -q '^until=0' "$dir/state/.quota-silence" || fail "the hold record was not cleared after the reset"
  pass "an exhausted limit holds the wake until the reset, then delivers it unchanged"
}

test_cached_hold_does_not_reread_quota() {
  local dir out
  dir=$(new_case cached)
  printf 'claude\n' > "$dir/config/quota-silence"
  fake_axi "$dir" 0 3
  run_wake "$dir" >/dev/null
  [ "$(wc -l < "$dir/calls")" -eq 1 ] || fail "the hold re-read quota-axi inside one hold: $(cat "$dir/calls")"
  # Right after a hold ends the verdict is not re-read before the recheck gap.
  out=$(run_wake "$dir")
  [ "${out%% *}" -le 1 ] || fail "a wake right after the reset was held again: $out"
  [ "$(wc -l < "$dir/calls")" -eq 1 ] || fail "quota-axi was read again inside the recheck gap"
  pass "one hold reads quota-axi once and does not re-hold inside the recheck gap"
}

test_nothing_holds_without_an_exhausted_configured_account() {
  local dir out
  dir=$(new_case free)
  fake_axi "$dir" 0 60
  out=$(run_wake "$dir")
  [ "${out%% *}" -le 1 ] || fail "an unconfigured home held its wake: $out"
  [ ! -s "$dir/calls" ] || fail "an unconfigured home read quota-axi"

  printf 'claude\n' > "$dir/config/quota-silence"
  fake_axi "$dir" 40 60
  out=$(run_wake "$dir")
  [ "${out%% *}" -le 1 ] || fail "a healthy quota held the wake: $out"

  rm -f "$dir/state/.quota-silence"
  fake_axi "$dir" 0 -120
  out=$(run_wake "$dir")
  [ "${out%% *}" -le 1 ] || fail "a reset time already past held the wake: $out"

  rm -f "$dir/state/.quota-silence"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/quota-axi"
  out=$(run_wake "$dir")
  [ "${out%% *}" -le 1 ] || fail "an unreadable quota-axi held the wake: $out"

  rm -f "$dir/state/.quota-silence"
  fake_axi "$dir" 0 60
  : > "$dir/state/.afk"
  out=$(run_wake "$dir")
  [ "${out%% *}" -le 1 ] || fail "an away record did not step the hold aside: $out"
  pass "no config, a healthy quota, a past reset, a dead quota-axi, and an away record all wake at once"
}

test_account_key_scopes_the_hold() {
  local dir out
  dir=$(new_case key)
  printf 'claude/other\n' > "$dir/config/quota-silence"
  fake_axi "$dir" 0 60 mine
  out=$(run_wake "$dir")
  [ "${out%% *}" -le 1 ] || fail "another account's exhaustion held this wake: $out"
  pass "a configured account key ignores other accounts' exhaustion"
}

test_status_helper_reports_exhausted_clear_and_unknown() {
  local dir out rc
  dir=$(new_case status)
  run_status() { FM_HOME="$dir" FM_QUOTA_SILENCE_AXI="$dir/quota-axi" bash "$ROOT/bin/fm-quota-silence.sh" status; }
  fake_axi "$dir" 0 600
  rc=0; out=$(run_status) || rc=$?
  [ "$rc" -eq 0 ] && [[ "$out" == "exhausted "* ]] || fail "an exhausted account was not reported (rc $rc): $out"
  fake_axi "$dir" 50 600
  rc=0; out=$(run_status) || rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = clear ] || fail "a healthy account was not reported clear (rc $rc): $out"
  fake_axi "$dir" 0 -60
  rc=0; out=$(run_status) || rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = clear ] || fail "a past reset was not reported clear (rc $rc): $out"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/quota-axi"
  rc=0; out=$(run_status) || rc=$?
  [ "$rc" -eq 2 ] && [ "$out" = unknown ] || fail "an unreadable quota-axi was not reported unknown (rc $rc): $out"
  pass "the status helper tells exhausted, clear, and unknown apart"
}

test_exhausted_limit_holds_the_wake_until_the_reset
test_status_helper_reports_exhausted_clear_and_unknown
test_cached_hold_does_not_reread_quota
test_nothing_holds_without_an_exhausted_configured_account
test_account_key_scopes_the_hold
