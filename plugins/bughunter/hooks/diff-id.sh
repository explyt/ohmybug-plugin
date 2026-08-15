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

# Everything below is keyed on the REPOSITORY, not the working tree.
#
# `--absolute-git-dir` answers `<main>/.git/worktrees/<name>` inside a worktree,
# so a hunt recorded from the main checkout was invisible to a gate running in a
# worktree and the reverse — two files, same repository, and a merge blocked on
# work that had been hunted (owner report, 2026-08-12, third occurrence of this
# class). `--git-common-dir` answers the same path from both.
ohmybug_repo_key() {
  local d
  d=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || d=$(git rev-parse --absolute-git-dir 2>/dev/null) \
    || return 1
  printf '%s' "$d" | shasum -a 256 | cut -c1-16
}

ohmybug_hunt_dir() {
  local k
  k=$(ohmybug_repo_key) || return 1
  # `hunts/`, not `markers/`: in the main checkout the old key and the new one
  # are the same string, and the old scheme left a FILE exactly where this needs
  # a directory.
  printf '%s/.ohmybug/hunts/%s' "$HOME" "$k"
}

# A hunt is one empty file named after what was hunted. A set, not a slot: two
# worktrees of one repository can be mid-review at the same time without
# overwriting each other's evidence, and the lookup is a file test.
ohmybug_record_hunt() {
  local dir
  [ -n "${1:-}" ] || return 1
  dir=$(ohmybug_hunt_dir) || return 1
  mkdir -p "$dir" && : > "$dir/$1"
}

ohmybug_hunted() {
  local dir
  [ -n "${1:-}" ] || return 1
  dir=$(ohmybug_hunt_dir) || return 1
  [ -f "$dir/$1" ]
}

# An ATTEMPT is "the model asked for a hunt on this id", recorded before the
# environment gets to say yes or no. It lives in the same set under a prefixed
# key: one place to look, and a prefixed name can never satisfy a lookup for a
# finished hunt. The gate needs the distinction because "never tried" and "tried
# and was refused" are different facts and only the first deserves a block.
ohmybug_record_attempt() { ohmybug_record_hunt "attempt:${1:-}"; }
ohmybug_attempted() { ohmybug_hunted "attempt:${1:-}"; }

# sha256 of stdin. The identity of a hunt is the BYTES WE SENT, which is the one
# description of "which diff" that does not depend on which directory a hook
# happened to be standing in.
ohmybug_id_of_stdin() {
  shasum -a 256 | cut -d' ' -f1
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
  ohmybug_record_hunt "$id"
  echo "ohmybug: hunted diff recorded ($id)"
fi
