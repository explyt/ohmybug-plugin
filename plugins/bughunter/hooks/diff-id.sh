#!/bin/bash
# The ONE definition of "which diff is this". Both the merge gate and the
# skill's stamp step source it, so the two can never drift apart — a stamp
# that hashes something slightly different from what the gate hashes blocks a
# merge that was, in fact, hunted (owner report, 2026-08-11: the skill's
# snippet used a $BASE set in an earlier shell, so in a fresh Bash call it
# hashed `git diff ""` — an error, empty output, a marker matching nothing).
#
# Three outcomes, deliberately distinguishable, because callers must treat them
# differently and a two-way split hid a real hole:
#   exit 0 + a hash  -> this is the diff
#   exit 0 + nothing -> no local changes; nothing this gate can speak to
#   exit 1           -> cannot tell (no origin base, not a repo)
# The empty case needs its own answer: sha256 of empty input is the perfectly
# valid-looking constant e3b0c442…, so "did we get a hash back" cannot detect
# it, and a stamp taken on a clean tree would sit there authorising whatever
# came next.
ohmybug_base() {
  local branch base b
  branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')
  if [ -n "$branch" ]; then
    base=$(git merge-base HEAD "origin/$branch" 2>/dev/null) && [ -n "$base" ] && { printf '%s' "$base"; return 0; }
  fi
  # origin/HEAD is unset after `git init` + `remote add` + `fetch` — the shape
  # actions/checkout produces, so this is the CI default, not an exotic case.
  # Try the two names that cover almost everything before giving up.
  for b in main master; do
    base=$(git merge-base HEAD "origin/$b" 2>/dev/null) && [ -n "$base" ] && { printf '%s' "$base"; return 0; }
  done
  return 1
}

ohmybug_diff_id() {
  local base diff
  base=$(ohmybug_base) || return 1
  diff=$(git diff "$base" 2>/dev/null) || return 1
  [ -n "$diff" ] || return 0
  printf '%s' "$diff" | shasum -a 256 | cut -d' ' -f1
}

ohmybug_marker_path() {
  local gitdir
  gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
  printf '%s/.ohmybug/markers/%s' "$HOME" \
    "$(printf '%s' "$gitdir" | shasum -a 256 | cut -c1-16)"
}

# `diff-id.sh stamp` — record that the current diff was hunted.
if [ "${1:-}" = "stamp" ]; then
  if ! id=$(ohmybug_diff_id); then
    echo "ohmybug: cannot determine this diff (no origin base?) — nothing stamped" >&2
    exit 1
  fi
  if [ -z "$id" ]; then
    echo "ohmybug: no local changes against the base — nothing to stamp" >&2
    exit 1
  fi
  m=$(ohmybug_marker_path) || exit 1
  mkdir -p "$(dirname "$m")" && printf '%s\n' "$id" > "$m"
  echo "ohmybug: hunted diff recorded ($id)"
fi
