#!/bin/bash
# The ONE definition of "which diff is this". Both the merge gate and the
# skill's stamp step source it, so the two can never drift apart — a stamp
# that hashes something slightly different from what the gate hashes blocks a
# merge that was, in fact, hunted (owner report, 2026-08-11: the skill's
# snippet used a $BASE set in an earlier shell, so in a fresh Bash call it
# hashed `git diff ""` — an error, empty output, a marker matching nothing).
#
# Prints the diff id, or nothing at all if it cannot be computed. A caller
# that gets an empty string must NOT write a marker: a marker holding the
# hash of an empty string is worse than no marker, because it silently
# matches every future failure of the same kind.
ohmybug_diff_id() {
  local branch base
  branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')
  [ -z "$branch" ] && branch=main
  base=$(git merge-base HEAD "origin/$branch" 2>/dev/null) || return 1
  [ -n "$base" ] || return 1
  git diff "$base" 2>/dev/null | shasum -a 256 | cut -d' ' -f1
}

ohmybug_marker_path() {
  local gitdir
  gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
  printf '%s/.ohmybug/markers/%s' "$HOME" \
    "$(printf '%s' "$gitdir" | shasum -a 256 | cut -c1-16)"
}

# `diff-id.sh stamp` — record that the current diff was hunted.
if [ "${1:-}" = "stamp" ]; then
  id=$(ohmybug_diff_id) || { echo "ohmybug: not a git repo with an origin base — nothing stamped" >&2; exit 1; }
  [ -n "$id" ] || { echo "ohmybug: could not compute the diff id — nothing stamped" >&2; exit 1; }
  m=$(ohmybug_marker_path) || exit 1
  mkdir -p "$(dirname "$m")" && printf '%s\n' "$id" > "$m"
  echo "ohmybug: hunted diff recorded ($id)"
fi
