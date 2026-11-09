#!/usr/bin/env bash
# Away-posture admission of a GitHub head that is behind its base branch.
#
# bin/fm-pr-merge.sh refuses a head that does not contain the base tip, and
# while the away-posture record exists no --allow-behind waiver is available,
# so every PR in a batch would otherwise join the base and re-run CI one at a
# time. This library lets a low-risk PR skip that serial join, decided by code
# and never by a model. fm_behind_gate accepts a behind head only when ALL hold:
#   1. the caller-supplied risk is baixa or media (alta always runs serially);
#   2. no file the PR changes was also changed on the base since the PR's
#      merge-base (both file lists are read live from the forge compare API);
#   3. no file the PR changes matches a shared-registry glob registered for the
#      project in $FM_HOME/config/shared-registries;
#   4. every file list could be read in full.
# Any doubt refuses. Condition (4) of the merge, every required check green at
# the exact head, stays with bin/fm-pr-merge.sh and is not decided here.
#
# config/shared-registries (optional, gitignored): files where entries must be
# unique or whose content is derived (text catalogs, version indexes, binary
# bundles, indexes, lockfiles). One line per project:
#   <owner/repo | repo-name> <glob> [<glob>...]
# Globs are space separated and use shell pattern matching on the repository
# relative path, where `*` also crosses `/`, so `*.lock` matches at any depth.
# Blank lines and # comments are ignored. An absent file or a project with no
# line registers nothing; a file that exists but cannot be read refuses.
#
# fm_behind_notice appends one line per accepted merge to state/behind-merges.pending,
# the record firstmate reads after a batch to check the base branch's CI; the
# merge's ordinary outcome wake is the only trigger, no new wake exists.
#
# Sourced by bin/fm-pr-merge.sh and tests. No side effects on source.

# fm_behind_risk_valid <value> - baixa, media or alta.
fm_behind_risk_valid() {
  case "${1:-}" in baixa | media | alta) return 0 ;; *) return 1 ;; esac
}

# fm_behind_registry_globs <file> <owner/repo> <repo-name> - print the matching
# project's globs, one per line. Returns 1 when the file exists but is unreadable.
fm_behind_registry_globs() {
  local file=$1 slug=$2 name=$3 line fields glob
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    read -ra fields <<<"$line"
    [ "${#fields[@]}" -gt 1 ] || continue
    [ "${fields[0]}" = "$slug" ] || [ "${fields[0]}" = "$name" ] || continue
    for glob in "${fields[@]:1}"; do
      printf '%s\n' "$glob"
    done
  done <"$file"
}

# fm_behind_gate <owner> <repo> <base> <head> <risk> <registry-file>
# Returns 0 and prints one summary line when the behind head may merge; returns 1
# and prints the reason on stdout otherwise.
fm_behind_gate() {
  local owner=$1 repo=$2 base=$3 head=$4 risk=$5 registry=$6
  local merge_base pr_files base_files globs file glob crossed shared

  if ! fm_behind_risk_valid "$risk"; then
    echo "no risk level was given; a behind head is admitted while away only with --risk baixa|media"
    return 1
  fi
  if [ "$risk" = alta ]; then
    echo "the PR is high risk (alta), which always merges serially"
    return 1
  fi

  if ! merge_base=$(gh api "repos/$owner/$repo/compare/$base...$head" \
      --jq '.merge_base_commit.sha' 2>/dev/null) || [ -z "$merge_base" ] \
    || ! printf '%s' "$merge_base" | grep -Eq '^[0-9a-f]{40}([0-9a-f]{24})?$'; then
    echo "the merge-base of $base and $head could not be read"
    return 1
  fi
  if ! pr_files=$(gh api --paginate "repos/$owner/$repo/compare/$merge_base...$head" \
      --jq '.files[]? | .filename, (.previous_filename // empty)' 2>/dev/null) \
    || [ -z "$pr_files" ]; then
    echo "the files changed by the PR could not be read"
    return 1
  fi
  if ! base_files=$(gh api --paginate "repos/$owner/$repo/compare/$merge_base...$base" \
      --jq '.files[]? | .filename, (.previous_filename // empty)' 2>/dev/null); then
    echo "the files changed on $base since the merge-base could not be read"
    return 1
  fi
  # GitHub lists at most 300 files per comparison; a list that long may be
  # truncated, so it cannot prove the absence of a crossing.
  if [ "$(printf '%s\n' "$pr_files" | sort -u | wc -l)" -ge 300 ] \
    || [ "$(printf '%s\n' "$base_files" | sort -u | grep -c .)" -ge 300 ]; then
    echo "a file list reached GitHub's 300-file comparison limit and may be truncated"
    return 1
  fi

  if ! globs=$(fm_behind_registry_globs "$registry" "$owner/$repo" "$repo"); then
    echo "config/shared-registries exists but could not be read"
    return 1
  fi

  crossed=$(comm -12 <(printf '%s\n' "$pr_files" | sort -u) <(printf '%s\n' "$base_files" | sort -u))
  if [ -n "$crossed" ]; then
    echo "the PR changes file(s) $base also changed since the merge-base: $(printf '%s' "$crossed" | head -5 | paste -sd, -)"
    return 1
  fi

  shared=''
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      # shellcheck disable=SC2254 # the registered glob is the pattern
      case "$file" in $glob) shared="${shared:+$shared, }$file"; break ;; esac
    done <<EOF
$globs
EOF
  done <<EOF
$pr_files
EOF
  if [ -n "$shared" ]; then
    echo "the PR touches shared-registry file(s), which always merge serially: $shared"
    return 1
  fi

  printf 'behind head admitted while away: risk %s, no file crossing since merge-base %s, no shared registry touched\n' \
    "$risk" "$merge_base"
}

# fm_behind_notice <state-dir> <task-id> <pr-url> <base> <risk>
fm_behind_notice() {
  local state=$1 id=$2 url=$3 base=$4 risk=$5
  printf '%s task=%s base=%s risk=%s %s\n' "$(date +%s)" "$id" "$base" "$risk" "$url" \
    >>"$state/behind-merges.pending"
}
