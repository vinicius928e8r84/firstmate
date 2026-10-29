#!/usr/bin/env bash
# fm-spawn-verify-lib.sh - the post-launch proof bin/fm-spawn.sh runs before it
# reports a spawn: the worker process is alive, it is processing the brief, and
# the model name it shows is the one that was requested.
#
# Why: fm-spawn seeds a busy record of its own (source fm-spawn), so a task
# reads busy even when the agent never ingested the brief - an unknown model
# name made the worker exit at startup and only a human looking at the pane
# noticed. Sourced by bin/fm-spawn.sh after bin/fm-backend.sh and
# bin/fm-busy-lib.sh; no side effects on source.
#
# fm_spawn_verify_launch <backend> <target> <id> <state-dir> <model> [expected-label]
#   returns 0 as soon as all three proofs hold; returns 1 with the plain
#   diagnostic in FM_SPAWN_VERIFY_REASON when the worker exited, printed a
#   model-not-found error, or the bounded wait ran out. It only reads: it never
#   closes the endpoint or touches the worktree.
# Knobs: FM_SPAWN_VERIFY=0 turns the gate off, FM_SPAWN_VERIFY_SECS (default 90)
# bounds the wait, FM_SPAWN_VERIFY_INTERVAL (default 2) is the poll gap.
#
# Process liveness is the backend's own agent-state read (tmux, herdr, rex); a
# backend that cannot classify it (unverified/unknown) is not held against the
# worker. "Processing" is either a busy record written by the worker's own
# source (anything but fm-spawn) or the pane footer showing spent tokens/cost
# or a running turn. The model proof is the requested id, minus any provider
# prefix, appearing in the pane (compared case- and punctuation-blind, and with
# a trailing date stamp or the leading "claude-" dropped, so "claude-opus-4-8"
# matches a header reading "Opus 4.8").

# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after a failed proof
FM_SPAWN_VERIFY_REASON=

fm_spawn_verify_norm() {  # stdin -> lowercase alphanumerics only
  tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

fm_spawn_verify_model_shown() {  # <model> <pane>
  local bare norm pane_norm cand
  bare=${1##*/}
  norm=$(printf '%s' "$bare" | fm_spawn_verify_norm)
  [ -n "$norm" ] || return 0
  pane_norm=$(printf '%s' "$2" | fm_spawn_verify_norm)
  for cand in "$norm" \
    "$(printf '%s' "$bare" | sed -E 's/-?[0-9]{8}$//' | fm_spawn_verify_norm)" \
    "$(printf '%s' "$bare" | sed -E 's/^claude-//; s/-?[0-9]{8}$//' | fm_spawn_verify_norm)"; do
    [ -n "$cand" ] || continue
    case "$pane_norm" in *"$cand"*) return 0 ;; esac
  done
  return 1
}

fm_spawn_verify_processing() {  # <state-dir> <id> <pane>
  local rec src
  if rec=$(fm_busy_record_read "$1" "$2" 2>/dev/null); then
    src=${rec#* }
    src=${src%% *}
    [ "$src" = fm-spawn ] || return 0
  fi
  # shellcheck disable=SC2016 # the pattern is a regex, not an expansion
  printf '%s\n' "$3" | tail -12 | grep -Eq '↑[1-9]|↓[1-9]|\$0\.0[1-9]|\$[1-9]|Working|Thinking'
}

fm_spawn_verify_launch() {  # <backend> <target> <id> <state-dir> <model> [expected-label]
  local backend=$1 target=$2 id=$3 state=$4 model=$5 label=${6:-}
  local max=${FM_SPAWN_VERIFY_SECS:-90} gap=${FM_SPAWN_VERIFY_INTERVAL:-2}
  local start now pane agent dead=0 processing=0 shown=1
  FM_SPAWN_VERIFY_REASON=
  [ "${FM_SPAWN_VERIFY:-1}" != 0 ] || return 0
  case "$model" in '' | default) ;; *) shown=0 ;; esac
  start=$(date +%s)
  while :; do
    pane=$(fm_backend_capture "$backend" "$target" 120 "$label" 2>/dev/null || true)
    agent=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)
    case "$agent" in dead | missing) dead=$((dead + 1)) ;; *) dead=0 ;; esac
    now=$(date +%s)
    if [ "$processing" = 0 ] && fm_spawn_verify_processing "$state" "$id" "$pane"; then
      processing=1
    fi
    if [ "$processing" = 0 ] &&
      printf '%s\n' "$pane" | grep -Eq 'not found.*--list-models|Model ".*" not found|[Mm]odel not found|[Uu]nknown model'; then
      FM_SPAWN_VERIFY_REASON="the worker reported that model '$model' was not found, so it never started the brief"
      return 1
    fi
    if [ "$dead" -ge 3 ] && [ $((now - start)) -ge 5 ]; then
      FM_SPAWN_VERIFY_REASON="the worker process is not running (it exited right after launch)"
      return 1
    fi
    if [ "$shown" = 0 ] && fm_spawn_verify_model_shown "$model" "$pane"; then
      shown=1
    fi
    if [ "$processing" = 1 ] && [ "$shown" = 1 ]; then
      return 0
    fi
    if [ $((now - start)) -ge "$max" ]; then
      if [ "$processing" = 0 ]; then
        FM_SPAWN_VERIFY_REASON="the worker showed no sign of processing the brief within ${max}s"
      else
        FM_SPAWN_VERIFY_REASON="the worker is running but never showed the requested model '$model' within ${max}s (wrong model, or a name the worker does not report)"
      fi
      return 1
    fi
    sleep "$gap"
  done
}
