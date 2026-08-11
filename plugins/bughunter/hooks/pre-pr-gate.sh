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

# Match the COMMAND, not the command line. A substring test blocks anything
# that merely mentions the words — a test harness, an echo, a doc snippet —
# and every false block teaches the user to reach for SKIP_BUGHUNT=1, which
# costs more than the case the gate is guarding. (Same failure class as
# matching processes by cmdline; we were bitten by both in one night.)
is_merge=0
skip=0
while IFS= read -r seg; do
  # Drop leading whitespace and env assignments: `FOO=1 gh pr merge` is still
  # a merge, and `SKIP_BUGHUNT=1` in front of one is still an opt-out.
  seg="${seg#"${seg%%[![:space:]]*}"}"
  while :; do
    case "$seg" in
      [A-Za-z_]*=*)
        case "${seg%%=*}" in *[!A-Za-z0-9_]*) break ;; esac
        case "${seg%%=*}" in SKIP_BUGHUNT) case "$seg" in SKIP_BUGHUNT=1*) skip=1 ;; esac ;; esac
        seg="${seg#* }"
        seg="${seg#"${seg%%[![:space:]]*}"}" ;;
      *) break ;;
    esac
  done
  case "$seg" in
    "gh pr merge "*|"gh pr merge"|"glab mr merge "*|"glab mr merge") is_merge=1 ;;
  esac
done <<EOF
$(printf '%s' "$CMD" | tr ';|&' '\n\n\n')
EOF

[ "$is_merge" = 1 ] || exit 0
[ "$skip" = 1 ] && exit 0

GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
LEGACY_MARKER="$GITDIR/ohmybug/last-review"

# Shared with the skill's stamp step: one definition, so a hunted diff can
# never fail to match its own marker.
. "$(dirname "$0")/diff-id.sh"
MARKER=$(ohmybug_marker_path) || exit 0
CURRENT=$(ohmybug_diff_id) || exit 0
# Cannot tell what this diff is => cannot claim it went unhunted. A gate that
# fails closed on its own inability to measure just teaches people to pass
# SKIP_BUGHUNT=1 by reflex, which costs more than the case it guards.
[ -n "$CURRENT" ] || exit 0

for M in "$MARKER" "$LEGACY_MARKER"; do
  if [ -f "$M" ] && [ "$(cat "$M")" = "$CURRENT" ]; then
    exit 0
  fi
done

echo "OhMyBug: the current diff has not been hunted (or changed since the last hunt). Run the bughunter skill (/bughunter:review) — it hunts the FINAL post-review diff, you confirm findings, then merge is unblocked. If the hunt DID just run and came back clean, it only forgot to record itself: run \`$(dirname "$0")/diff-id.sh stamp\` and merge again. To skip once, prefix the command with SKIP_BUGHUNT=1 (ask the user first)." >&2
exit 2
