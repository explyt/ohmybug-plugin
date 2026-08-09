#!/bin/bash
# OhMyBug pre-MERGE gate: block `gh pr merge` / `glab mr merge` until the
# CURRENT diff has been hunted (marker written by the bughunter skill).
# The hunt is deliberately the LAST gate before merge — it runs on the code
# that survived human/agent review rounds and CI, so its findings are the
# ones every other net missed. A diff changed since the last hunt (review
# fixes!) re-triggers the block via the sha marker.
# Marker lives under ~/.ohmybug/ (keyed by git-dir path) — NOT inside .git/,
# because agent permission classifiers rightly block writes into .git/.
# Escape hatch: SKIP_BUGHUNT=1 in the command, or delete the marker file.

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)

# Worktree support: the hook process runs in the project root, but the merge
# command runs in the session's cwd (often a git worktree with its own git-dir
# and its own diff). Judge the repo the COMMAND sees, not the hook's cwd.
SESSION_CWD=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
[ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ] && cd "$SESSION_CWD" 2>/dev/null

case "$CMD" in
  *"gh pr merge"*|*"glab mr merge"*) ;;
  *) exit 0 ;;
esac

case "$CMD" in *SKIP_BUGHUNT=1*) exit 0 ;; esac

GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
MARKER="$HOME/.ohmybug/markers/$(printf '%s' "$GITDIR" | shasum -a 256 | cut -c1-16)"
LEGACY_MARKER="$GITDIR/ohmybug/last-review"

DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH=main
BASE=$(git merge-base HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null) || exit 0
CURRENT=$(git diff "$BASE" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)

for M in "$MARKER" "$LEGACY_MARKER"; do
  if [ -f "$M" ] && [ "$(cat "$M")" = "$CURRENT" ]; then
    exit 0
  fi
done

echo "OhMyBug: the current diff has not been hunted (or changed since the last hunt). Run the bughunter skill (/bughunter:review) — it hunts the FINAL post-review diff, you confirm findings, then merge is unblocked. To skip once, prefix the command with SKIP_BUGHUNT=1 (ask the user first)." >&2
exit 2
