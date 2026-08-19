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

# The raw bytes of "this working tree's diff", shared by every hash below so
# the spellings can never drift apart — two computations of "which diff is
# this" diverging is this file's founding incident. Callers capture via $( ),
# which strips the trailing newline; each consumer reconstructs the spelling
# it needs explicitly.
ohmybug_diff_raw() {
  local base
  base=$(ohmybug_base) || return 1
  git diff "$base" 2>/dev/null
}

ohmybug_diff_id() {
  local diff
  diff=$(ohmybug_diff_raw) || return 1
  [ -n "$diff" ] || return 0
  printf '%s' "$diff" | shasum -a 256 | cut -d' ' -f1
}

# The SIGNIFICANT diff: the same diff with everything that cannot change what
# the software does taken out.
#
# The gate keys on a hash of the whole diff, so editing a README after a hunt
# read as "new, unhunted code" and blocked the merge — a re-hunt costs money and
# a quarter of an hour to review prose the reviewers were never asked about.
# Worse, a docs-only branch had to be hunted before it could land at all.
#
# ponytail: this is a path list, not an understanding of the code. A `.md` file
# IS behaviour in some repositories — a skill, a prompt, a bundle this very
# plugin ships — so OHMYBUG_HUNT_ALL=1 turns the whole idea off and returns the
# strict "every byte counts" gate.
#
# `.claude/` is deliberately NOT on this list, though it is prose-shaped: its
# settings decide whether this gate stands down at all (see
# ohmybug_tools_allowed below) and its hook definitions are commands that run.
# A change to the control itself is the last thing that should skip review.
OHMYBUG_SKIP_GLOBS="
:(top,exclude,glob)**/*.md
:(top,exclude,glob)**/*.mdx
:(top,exclude,glob)**/*.rst
:(top,exclude,glob)**/*.txt
:(top,exclude,glob)**/docs/**
:(top,exclude,glob)**/LICENSE*
:(top,exclude,glob)**/CHANGELOG*
:(top,exclude,glob)**/test/**
:(top,exclude,glob)**/tests/**
:(top,exclude,glob)**/spec/**
:(top,exclude,glob)**/__tests__/**
:(top,exclude,glob)**/*.test.*
:(top,exclude,glob)**/*.spec.*
:(top,exclude,glob)**/*_test.*
:(top,exclude,glob)**/skills/**
"

# exit 0 + a hash -> this is the part of the diff a hunt would speak about
# exit 0 + nothing -> nothing here can change behaviour; there is nothing to hunt
# exit 1          -> cannot tell (same as ohmybug_diff_id)
ohmybug_sig_id() {
  local base diff
  [ "${OHMYBUG_HUNT_ALL:-0}" = "1" ] && { ohmybug_diff_id; return $?; }
  base=$(ohmybug_base) || return 1
  # `:(top)` on every entry, and no `.` beside them: a bare `.` and plain globs
  # resolve against the CURRENT DIRECTORY, so the same tree hashed from the repo
  # root and from a package subdirectory gave two different answers — and the
  # subdirectory one came out EMPTY, which this gate reads as "nothing here can
  # change behaviour, allow the merge". Its sibling ohmybug_diff_id passes no
  # pathspec at all for exactly this reason; three comments in this file already
  # record what cwd-dependent identity costs.
  #
  # Unquoted on purpose: each line of the list is one pathspec argument.
  diff=$(git diff "$base" -- $OHMYBUG_SKIP_GLOBS 2>/dev/null) || return 1
  [ -n "$diff" ] || return 0
  printf '%s' "$diff" | shasum -a 256 | cut -d' ' -f1
}

# Is `$1` the id of a payload that IS this working tree, in either of the two
# spellings a client sends it in? `ohmybug_diff_id` hashes the diff with its
# trailing newline stripped (command substitution eats it), while a client
# piping `git diff` verbatim sends it WITH — the same diff, two hashes. Both
# count; nothing else does. A payload that is a SUBSET of the tree (say, only
# the latest fix), or belongs to another repository entirely, must not
# authorise this tree.
# On success prints the canonical (stripped) id, computed from the very bytes
# the equality just validated — so the recorded id cannot drift from what was
# compared even if the tree changes under a fast external writer.
ohmybug_sent_is_local() {
  local d stripped
  [ -n "${1:-}" ] || return 1
  d=$(ohmybug_diff_raw) || return 1
  [ -n "$d" ] || return 1
  stripped=$(printf '%s' "$d" | shasum -a 256 | cut -d' ' -f1)
  if [ "$1" = "$stripped" ] ||
     [ "$1" = "$(printf '%s\n' "$d" | shasum -a 256 | cut -d' ' -f1)" ]; then
    printf '%s' "$stripped"
    return 0
  fi
  return 1
}

# The ref an AUTHORISING record may be filed under — the ONE rule, shared by
# the offer (PreToolUse) and the promote (PostToolUse) paths. Accepted only
# when both hold: the spelling itself pins the commit — a hex prefix of the
# sha it resolves to (full or short sha) — and that commit is the HEAD of one
# of this repository's worktrees. Prints the resolved sha; rc 1 otherwise.
#
# Both halves close a measured hole. A symbolic spelling (branch, tag, HEAD)
# resolves HERE to whatever this clone happens to hold, while the server
# fetches the SAME NAME from the remote: one unpushed commit apart, and the
# record authorises bytes no reviewer ever saw. And a sha no worktree here
# stands on — an ancestor, another repository's commit — describes a tree
# nothing here is about to merge, so nothing here may merge on its strength.
ohmybug_ref_here() {
  local r
  [ -n "${1:-}" ] || return 1
  r=$(git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null) || return 1
  [ -n "$r" ] || return 1
  case "$r" in "$1"*) ;; *) return 1 ;; esac
  { git worktree list --porcelain 2>/dev/null | grep -qxF "HEAD $r" ||
    [ "$r" = "$(git rev-parse HEAD 2>/dev/null)" ]; } || return 1
  printf '%s' "$r"
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

# An ATTEMPT is "the model offered this diff for hunting", recorded before the
# environment gets to say yes or no. It lives in the same set under a prefixed
# key: one place to look, and a prefixed name can never satisfy a lookup for a
# finished hunt. The gate needs the distinction because "never tried" and "tried
# and was refused" are different facts and only the first deserves a block.
#
# The empty guard is repeated rather than inherited: `attempt:` prepended to
# nothing is a non-empty string, so the guard inside ohmybug_record_hunt can no
# longer fire — and an id-less record would be a file that answers every lookup.
ohmybug_record_attempt() {
  [ -n "${1:-}" ] || return 1
  ohmybug_record_hunt "attempt:$1"
}

# Attempts EXPIRE. A refusal is a statement about the environment right now; a
# permanent one would mean a single refused call authorises every future merge of
# that diff on this machine, and diff ids are content hashes, so a revert that
# recreates old bytes would inherit an authorisation from weeks ago.
OHMYBUG_ATTEMPT_TTL_MIN=${OHMYBUG_ATTEMPT_TTL_MIN:-720}
ohmybug_clear_attempt() {
  local dir
  [ -n "${1:-}" ] || return 1
  dir=$(ohmybug_hunt_dir) || return 1
  rm -f "$dir/attempt:$1"
}

ohmybug_attempted() {
  local dir
  [ -n "${1:-}" ] || return 1
  dir=$(ohmybug_hunt_dir) || return 1
  [ -f "$dir/attempt:$1" ] || return 1
  [ -n "$(find "$dir" -maxdepth 1 -name "attempt:$1" -mmin "-$OHMYBUG_ATTEMPT_TTL_MIN" 2>/dev/null)" ]
}

# Is a hunt for this id still in flight? A submit that WAS allowed leaves a
# pending record naming every id it could be known by; until it is promoted the
# review is running, and "running" must not read as "refused" — merging then is
# merging before the findings arrive.
#
# Pending records expire too, and for a blunter reason than attempts: a review
# that ends `failed`, or a session that walks away mid-review, leaves one behind
# forever, and "a hunt is RUNNING" is then a permanent block on those bytes with
# an instruction — poll until done — that can never be satisfied.
OHMYBUG_PENDING_TTL_MIN=${OHMYBUG_PENDING_TTL_MIN:-180}
ohmybug_pending_has() {
  local dir f
  [ -n "${1:-}" ] || return 1
  dir=$(ohmybug_hunt_dir) || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qxF "$1" "$f" 2>/dev/null && return 0
  done <<EOF
$(find "$dir.pending" -maxdepth 1 -type f -mmin "-$OHMYBUG_PENDING_TTL_MIN" 2>/dev/null)
EOF
  return 1
}

# Is there an ALLOW rule for the hunt tools? This is the one input in the warn
# decision that the model does not write — the user's own settings files.
#
# Only `permissions.allow` counts. A deny rule, or an ask rule, or no rule at
# all, all mean the same thing here: the hunt cannot run unattended, so a gate
# that blocks on the missing hunt is blocking on something nobody in the session
# can produce.
ohmybug_tools_allowed() {
  python3 - "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" \
    "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json" \
    "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.local.json" <<'PY' 2>/dev/null
import json, sys
for path in sys.argv[1:]:
    try:
        data = json.load(open(path))
    except Exception:
        continue
    rules = (data.get("permissions") or {}).get("allow") or []
    if any("bughunter_ohmybug" in str(r) for r in rules):
        sys.exit(0)
sys.exit(1)
PY
}

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
    base=$(ohmybug_base) || exit 1
    echo "ohmybug: no local changes in $(pwd -P) against $base — nothing to stamp" >&2
    exit 1
  fi
  m=$(ohmybug_marker_path) || exit 1
  mkdir -p "$(dirname "$m")" && printf '%s\n' "$id" > "$m"
  ohmybug_record_hunt "$id"
  echo "ohmybug: hunted diff recorded ($id)"
fi
