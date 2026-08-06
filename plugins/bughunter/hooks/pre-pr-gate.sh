#!/bin/bash
# OhMyBug pre-PR gate: block `gh pr create` / `glab mr create` until the
# current diff has been reviewed (marker written by the bughunter skill).
# Escape hatch: SKIP_BUGHUNT=1 in the command, or delete .git/ohmybug.

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)

case "$CMD" in
  *"gh pr create"*|*"glab mr create"*) ;;
  *) exit 0 ;;
esac

case "$CMD" in *SKIP_BUGHUNT=1*) exit 0 ;; esac

GITDIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
MARKER="$GITDIR/ohmybug/last-review"

DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH=main
BASE=$(git merge-base HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null) || exit 0
CURRENT=$(git diff "$BASE" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$CURRENT" ]; then
  exit 0
fi

echo "OhMyBug: this diff has not been reviewed. Run the bughunter skill (/bughunter:review) first — it reviews the diff, you confirm findings, then PR creation is unblocked. To skip once, prefix the command with SKIP_BUGHUNT=1 (ask the user first)." >&2
exit 2
