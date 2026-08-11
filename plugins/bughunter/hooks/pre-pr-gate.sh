#!/bin/bash
# OhMyBug pre-MERGE gate: block `gh pr merge` / `glab mr merge` until the
# CURRENT diff has been hunted (marker written by the bughunter skill).
# The hunt is deliberately the LAST gate before merge — it runs on the code
# that survived human/agent review rounds and CI, so its findings are the
# ones every other net missed. A diff changed since the last hunt (review
# fixes!) re-triggers the block via the sha marker.
# Marker lives under ~/.ohmybug/ (keyed by git-dir path) — NOT inside .git/,
# because agent permission classifiers rightly block writes into .git/.
# Escape hatch: SKIP_BUGHUNT=1 in front of the merge itself.
#
# Deciding "is this a merge" is done by TOKENIZING the command, in python3,
# not by string surgery in shell. The shell version of this decision shipped
# four defects in twenty lines — an infinite loop on any bare `NAME=value`
# segment (which hung every Bash call, since this hook runs on all of them), a
# false block on any command that merely quoted the words, `SKIP_BUGHUNT=1` on
# an unrelated earlier segment disarming the gate, and `bash -c "gh pr merge"`
# walking straight through. shlex already knows what a quote is; we do not need
# to learn it again here.

INPUT=$(cat)

DECIDE=$(printf '%s' "$INPUT" | python3 -c '
import json, shlex, sys

MERGERS = (("gh", "pr", "merge"), ("glab", "mr", "merge"))
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
# Anything that can end one command and start another. Keywords matter: after
# `then` or `do` comes a fresh command, and treating them as separators is what
# stops `if x; then gh pr merge; fi` from hiding.
SEPS = {";", "&&", "||", "|", "&", "(", ")", "{", "}", "\n", "then", "do",
        "else", "elif", "fi", "done", "in", "!"}

def segments(cmd, depth=0):
    """Yield token lists, one per command position, recursing into `sh -c`."""
    if depth > 3:
        return
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    try:
        tokens = list(lex)
    except ValueError:
        # Unbalanced quotes: we cannot tokenize, so we cannot rule a merge out.
        yield ["\x00unparsed"]
        return
    cur = []
    for t in tokens:
        if t in SEPS:
            if cur:
                yield cur
            cur = []
        else:
            cur.append(t)
    if cur:
        yield cur
    # A shell invoked with -c carries a whole command line in one argument.
    for seg in list(segments_inner(tokens)):
        yield from segments(seg, depth + 1)

def segments_inner(tokens):
    for i, t in enumerate(tokens):
        if t.split("/")[-1] in SHELLS:
            for j in range(i + 1, len(tokens)):
                if tokens[j] == "-c" and j + 1 < len(tokens):
                    yield tokens[j + 1]
                    break

def strip_env(seg):
    """Drop leading VAR=value words; report whether one of them opts out."""
    skip = False
    i = 0
    while i < len(seg) and "=" in seg[i]:
        name = seg[i].split("=", 1)[0]
        if not name or not (name[0].isalpha() or name[0] == "_"):
            break
        if not all(c.isalnum() or c == "_" for c in name):
            break
        if name == "SKIP_BUGHUNT" and seg[i].split("=", 1)[1] == "1":
            skip = True
        i += 1
    return seg[i:], skip

try:
    data = json.load(sys.stdin)
except Exception:
    print("unparsed")
    sys.exit(0)
cmd = (data.get("tool_input") or {}).get("command") or ""
print(data.get("cwd") or "", end="\x01")
verdict = "none"
for seg in segments(cmd):
    if seg and seg[0] == "\x00unparsed":
        verdict = "unparsed"
        continue
    words, skip = strip_env(seg)
    head = tuple(words[:3])
    if any(head[: len(m)] == m for m in MERGERS):
        # The opt-out counts only on the merge itself. Anywhere else it is just
        # a variable someone happened to set.
        verdict = "skip" if skip else "merge"
        if verdict == "merge":
            break
print(verdict)
' 2>/dev/null)

if [ -z "$DECIDE" ]; then
  # No python3 (or it failed): we cannot read the command, so we cannot tell a
  # merge from an `ls`. Blocking everything would wedge the session; allowing
  # everything would silently disarm the gate. So degrade to the paranoid
  # substring test — loud on anything merge-shaped, out of the way otherwise.
  case "$INPUT" in
    *merge*)
      echo "OhMyBug: cannot inspect this command (python3 unavailable), and it mentions a merge. Install python3, or prefix the command with SKIP_BUGHUNT=1 after checking the diff was hunted." >&2
      exit 2 ;;
    *) exit 0 ;;
  esac
fi

SESSION_CWD=${DECIDE%%$'\x01'*}
VERDICT=${DECIDE##*$'\x01'}
VERDICT=${VERDICT%%$'\n'*}

case "$VERDICT" in
  merge) ;;
  unparsed)
    echo "OhMyBug: could not parse this command well enough to tell whether it merges (unbalanced quotes?). If it does merge, hunt the diff first; to proceed, prefix with SKIP_BUGHUNT=1." >&2
    exit 2 ;;
  *) exit 0 ;;
esac

# Worktree support: the hook process runs in the project root, but the merge
# command runs in the session's cwd (often a git worktree with its own git-dir
# and its own diff). Judge the repo the COMMAND sees, not the hook's cwd.
[ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ] && cd "$SESSION_CWD" 2>/dev/null

GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
LEGACY_MARKER="$GITDIR/ohmybug/last-review"

# Shared with the skill's stamp step: one definition, so a hunted diff can
# never fail to match its own marker.
. "$(dirname "$0")/diff-id.sh"
MARKER=$(ohmybug_marker_path) || exit 0
# Cannot tell what this diff is => cannot claim it went unhunted. A gate that
# fails closed on its own inability to measure just teaches people to pass
# SKIP_BUGHUNT=1 by reflex, which costs more than the case it guards. Say so on
# stderr, though: a control that quietly stands down is worse than none.
if ! CURRENT=$(ohmybug_diff_id); then
  echo "OhMyBug: no origin base here, so the gate cannot judge this diff — allowing the merge unchecked." >&2
  exit 0
fi
# No local changes: this gate speaks about the working diff, and there isn't
# one. (Merging an unrelated PR from a clean tree is outside what it can see.)
[ -n "$CURRENT" ] || exit 0

for M in "$MARKER" "$LEGACY_MARKER"; do
  if [ -f "$M" ] && [ "$(cat "$M")" = "$CURRENT" ]; then
    exit 0
  fi
done

echo "OhMyBug: the current diff has not been hunted, or has CHANGED since the hunt (fixes count — re-hunt them). Run /bughunter:review, or call submit_review then get_findings directly; either way the hunt records itself when it finishes, no manual step. If a hunt did just finish on this exact diff and this still blocks, the recording hook is not installed (old plugin version) — say so rather than stamping by hand. To skip once, prefix the command with SKIP_BUGHUNT=1 (ask the user first)." >&2
exit 2
