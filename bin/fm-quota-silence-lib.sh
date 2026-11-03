# shellcheck shell=bash
# Quota silence: while the usage limit of the supervising session's account is
# exhausted, the watcher holds its wake until the reset instead of handing the
# model one refused turn per cycle (about 2,300 refusals a day in the audit of
# 2026-11-03, each one landing in the context the first call after the gap then
# had to rewrite). Usage: . bin/fm-quota-silence-lib.sh
#
# Opt-in per home. config/quota-silence names the account whose limit the
# supervising session runs under, first non-comment line:
#   <provider>             every quota-axi row of that provider must be exhausted
#   <provider>/<accountKey>  that one account row (quota-axi schema 6)
# An absent or empty file, an away record (the daemon owns triage then), a
# missing or unreadable quota-axi, or a row that is not exhausted all mean no
# silence, so the worst a wrong answer does is the ordinary wake behavior.
# Exhausted is the all_models scope reading runway exhausted_now or zero
# percent remaining, and the hold lasts until the earliest reset of the windows
# limiting it. A reset time already past never holds, so a stale snapshot cannot
# keep the watcher quiet after the limit lifted.
#
# The wake rows are already durable when the hold starts (fm_wake_append runs
# before wake()), so nothing is lost: the watcher keeps its beacon fresh, sleeps
# in short slices, and then delivers the one wake it was holding, which the
# drain presents together with every row queued meanwhile.
#
# state/.quota-silence (key=value) caches the verdict so the hot path costs one
# small file read: until=<epoch the hold ends, 0 for none> and checked=<epoch of
# the last quota-axi read>. The silent-watcher cron reads it to skip its
# undelivered-wake alarm while a hold stands.
#
# Env: FM_QUOTA_SILENCE_AXI (quota-axi command, tests), FM_QUOTA_SILENCE_RECHECK
# (seconds between quota-axi reads while not holding, default 300),
# FM_QUOTA_SILENCE_SLICE (seconds per sleep slice, default 30).
# The caller sets STATE and CONFIG and provides triage_log (bin/fm-push-transition-lib.sh).

_FM_QUOTA_SILENCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$_FM_QUOTA_SILENCE_LIB_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_QUOTA_SILENCE_LIB_DIR/fm-timeout-lib.sh"

fm_quota_silence_target() { # prints the configured <provider>[/<accountKey>] or nothing
  local file="$CONFIG/quota-silence" line
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
    return 0
  done < "$file"
}

fm_quota_silence_cached() { # <key> -> the cached value, 0 when absent
  local value
  value=$(sed -n "s/^$1=//p" "$STATE/.quota-silence" 2>/dev/null | tail -1)
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  printf '%s\n' "$value"
}

fm_quota_silence_store() { # <until-epoch> <checked-epoch>
  local tmp="$STATE/.quota-silence.tmp.$$"
  printf 'until=%s\nchecked=%s\n' "$1" "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE/.quota-silence" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# fm_quota_silence_read <target> -> prints the epoch the exhausted account comes
# back, or nothing when quota-axi cannot be read or the account is not exhausted.
fm_quota_silence_read() {
  local target=$1 provider key json rows row_until reset epoch best='' all=1 any=0 ok resets
  local axi=${FM_QUOTA_SILENCE_AXI:-quota-axi}
  provider=${target%%/*}
  key=
  case "$target" in */*) key=${target#*/} ;; esac
  json=$(fm_run_timed 20 "$axi" --json 2>/dev/null </dev/null) || return 0
  printf '%s\n' "$json" | fm_quota_json_valid || return 0
  rows=$(printf '%s\n' "$json" | jq -r --arg p "$provider" --arg k "$key" '
    .providers[]? | select(.provider == $p)
    | select($k == "" or ((.accountKey // "default") == $k))
    | . as $row
    | ([$row.quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models")] | first) as $a
    | ($a != null and (($a.runway.status // "") == "exhausted_now"
        or ($a.status == "known" and $a.effectivePercentRemaining == 0))) as $ex
    | [($ex | if . then "1" else "0" end),
       ([($a.limitingWindowIds // [])[] as $id | $row.windows[]? | select(.id == $id) | .resetsAt // empty] | join(","))]
    | @tsv' 2>/dev/null) || return 0
  [ -n "$rows" ] || return 0
  while IFS=$(printf '\t') read -r ok resets; do
    any=1
    if [ "$ok" != 1 ] || [ -z "$resets" ]; then all=0; continue; fi
    row_until=
    while IFS= read -r reset; do
      [ -n "$reset" ] || continue
      epoch=$(date -d "$reset" +%s 2>/dev/null) || { row_until=; break; }
      if [ -z "$row_until" ] || [ "$epoch" -gt "$row_until" ]; then row_until=$epoch; fi
    done <<EOF
$(printf '%s\n' "$resets" | tr ',' '\n')
EOF
    if [ -z "$row_until" ]; then all=0; continue; fi
    if [ -z "$best" ] || [ "$row_until" -lt "$best" ]; then best=$row_until; fi
  done <<EOF
$rows
EOF
  [ "$any" -eq 1 ] && [ "$all" -eq 1 ] && [ -n "$best" ] || return 0
  printf '%s\n' "$best"
}

# fm_quota_silence_until -> prints the epoch the hold ends when one stands now.
fm_quota_silence_until() {
  local target now until checked recheck found
  target=$(fm_quota_silence_target)
  [ -n "$target" ] || return 0
  [ ! -e "$STATE/.afk" ] || return 0
  now=$(date +%s)
  until=$(fm_quota_silence_cached until)
  if [ "$until" -gt "$now" ]; then
    printf '%s\n' "$until"
    return 0
  fi
  checked=$(fm_quota_silence_cached checked)
  recheck=${FM_QUOTA_SILENCE_RECHECK:-300}
  case "$recheck" in ''|*[!0-9]*|0) recheck=300 ;; esac
  [ $((now - checked)) -ge "$recheck" ] || return 0
  found=$(fm_quota_silence_read "$target")
  case "$found" in ''|*[!0-9]*) found=0 ;; esac
  [ "$found" -gt "$now" ] || found=0
  fm_quota_silence_store "$found" "$now"
  [ "$found" -eq 0 ] || printf '%s\n' "$found"
}

# fm_quota_silence_hold <wake-reason>
# Blocks until the exhausted account's reset, keeping the watcher beacon fresh;
# returns at once when no hold stands. Leaving the hold early (config removed,
# away record created) also returns.
fm_quota_silence_hold() {
  local reason=$1 until now slice logged=0
  slice=${FM_QUOTA_SILENCE_SLICE:-30}
  case "$slice" in ''|*[!0-9]*|0) slice=30 ;; esac
  until=$(fm_quota_silence_until)
  case "$until" in ''|*[!0-9]*) return 0 ;; esac
  while :; do
    now=$(date +%s)
    [ "$until" -gt "$now" ] || break
    if [ "$logged" -eq 0 ]; then
      triage_log "quota-silence: holding wake '$reason' until $(date -u -d "@$until" +%Y-%m-%dT%H:%MZ) (usage limit); rows stay queued"
      logged=1
    fi
    touch "$STATE/.last-watcher-beat" 2>/dev/null || true
    if [ $((until - now)) -lt "$slice" ]; then sleep $((until - now)); else sleep "$slice"; fi
    # A removed config or a new away record ends the hold early.
    [ -n "$(fm_quota_silence_target)" ] && [ ! -e "$STATE/.afk" ] || break
  done
  fm_quota_silence_store 0 "$(date +%s)"
}
