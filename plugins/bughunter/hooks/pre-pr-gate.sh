#!/bin/bash
# OhMyBug pre-MERGE gate: block `gh pr merge` / `glab mr merge` until the
# CURRENT diff has been hunted (marker written by the bughunter skill).
# The hunt is deliberately the LAST gate before merge — it runs on the code
# that survived human/agent review rounds and CI, so its findings are the
# ones every other net missed. A diff changed since the last hunt (review
# fixes!) re-triggers the block via the sha marker.
# Escape hatch: SKIP_BUGHUNT=1 in the command, or delete .git/ohmybug.

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)

case "$CMD" in
  *"gh pr merge"*|*"glab mr merge"*) ;;
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

echo "OhMyBug: the current diff has not been hunted (or changed since the last hunt). Run the bughunter skill (/bughunter:review) — it hunts the FINAL post-review diff, you confirm findings, then merge is unblocked. To skip once, prefix the command with SKIP_BUGHUNT=1 (ask the user first)." >&2
exit 2
