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
#
# ONE reason to exit 2: "this is a merge AND the diff has not been hunted."
# Every other outcome — cannot parse, no python3, no origin base, no recorder —
# exits 0 and says why. That invariant is not style. It held in three branches
# out of four, and the fourth (cannot parse) blocked 20 commands in one
# operator's transcripts, none of them a merge: heredoc bodies with an
# apostrophe in them, `git commit -F -`, `python3 - <<PY`, a ticket comment.
# Each one taught the agent to reach for SKIP_BUGHUNT=1 on the NEXT command,
# which is how a gate ends up guarding nothing.

INPUT=$(cat)

# Cheapest test first: `gh pr merge` and `glab mr merge` both contain the word,
# so a payload without it cannot be a merge. This also keeps the parser — and
# python3 start-up — away from the ~99% of Bash calls that were never this
# hook's business.
case "$INPUT" in
  *merge*) ;;
  *) exit 0 ;;
esac

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
  # everything would silently disarm the gate. So degrade to the substring test
  # — but on the two-word shapes, not on the bare word: `*merge*` also matches
  # `git merge-base`, `--no-merges` and any branch or path with "merge" in it.
  case "$INPUT" in
    *SKIP_BUGHUNT=1*) exit 0 ;;
    *"pr merge"*|*"mr merge"*)
      echo "OhMyBug: cannot inspect this command (python3 unavailable), and it looks like a merge. Ask the operator to install python3, or to run the merge themselves with SKIP_BUGHUNT=1 in front of it after checking the diff was hunted." >&2
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
    # Unbalanced quotes are a fact about quoting, not about merging — and shlex
    # has no idea what a heredoc is, so every `cat <<'EOF'` whose body contains
    # an apostrophe arrives here. Degrade to the same substring test as the
    # no-python3 branch and let the hunt check below decide; do not accuse.
    # The opt-out is read loosely here (anywhere in the payload, not on the
    # merge segment) precisely because we could not find the segments: the
    # alternative is a command with no way out at all.
    case "$INPUT" in
      *SKIP_BUGHUNT=1*) exit 0 ;;
      *"pr merge"*|*"mr merge"*) ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac

# Worktree support: the hook process runs in the project root, but the merge
# command runs in the session's cwd (often a git worktree with its own git-dir
# and its own diff). Judge the repo the COMMAND sees, not the hook's cwd.
[ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ] && cd "$SESSION_CWD" 2>/dev/null

GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
LEGACY_MARKER="$GITDIR/ohmybug/last-review"

# Is the thing that RECORDS hunts even installed? Markers are written by a
# PostToolUse hook (stamp-hunt.sh) that arrived in 0.12.0. Before it, only the
# skill wrote them, so a hunt driven straight through the MCP tools left no
# trace and this gate blocked work that had been hunted four times over (owner
# report, 2026-08-11 — twice, on two different machines).
#
# With no recorder there is no evidence either way, and "I cannot tell" must not
# be reported as "you did not hunt": a control that accuses honest work teaches
# people to pass SKIP_BUGHUNT by reflex, and then it guards nothing. Same choice
# as the missing-origin-base case below — stand down, say so loudly, name the
# fix. Both streams, because a PreToolUse hook that exits 0 has no guaranteed
# channel to the model.
if [ ! -f "$(dirname "$0")/stamp-hunt.sh" ]; then
  MSG="OhMyBug: this plugin predates the hunt recorder (0.12.0), so the merge gate has no way to know whether the diff was hunted — allowing the merge unchecked. Update the plugin (/plugin update bughunter) and restart the session to arm it again. Do NOT hand-write a marker and do not add SKIP_BUGHUNT anywhere."
  echo "$MSG" >&2
  echo "$MSG"
  exit 0
fi

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

# The hunt set, keyed on the repository rather than the working tree, so a hunt
# recorded from the main checkout is visible to a merge run in a worktree and the
# reverse. That mismatch blocked reviewed work three times.
if ohmybug_hunted "$CURRENT"; then
  exit 0
fi

# The no-payload path sends repo@ref and no bytes, so the commit is the identity
# — but only while nothing is uncommitted, because an edit after the hunt is a
# diff nobody reviewed.
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
if [ -n "$HEAD_SHA" ] && [ -z "$(git status --porcelain 2>/dev/null)" ] && ohmybug_hunted "ref:$HEAD_SHA"; then
  exit 0
fi

for M in "$MARKER" "$LEGACY_MARKER"; do
  if [ -f "$M" ] && [ "$(cat "$M")" = "$CURRENT" ]; then
    exit 0
  fi
done

# Asked for, and never finished. In auto mode the permission classifier refuses
# these tools by design — correctly, they send a diff off the machine — and an
# agent that has been refused has no move left: the escape hatch this hook used
# to recommend is an env prefix disabling a safety control, which the classifier
# refuses too. That is a dead end, and a dead end gets the plugin uninstalled.
# So: block "never tried", warn on "tried and the environment said no".
if ohmybug_attempted "$CURRENT" ||
   { [ -n "$HEAD_SHA" ] && ohmybug_attempted "ref:$HEAD_SHA"; }; then
  MSG="OhMyBug: a hunt was requested for this diff but never finished — the call was refused or it failed, so the gate has no findings to stand on. Allowing the merge. To arm the gate for next time, add one permission rule yourself: /permissions -> mcp__plugin_bughunter_ohmybug__*"
  echo "$MSG" >&2
  echo "$MSG"
  exit 0
fi

# Name the id and where we looked. Without this a false block is
# indistinguishable from a real one, and the only way to tell them apart was to
# read the hook — which is how an operator ends up reaching for SKIP_BUGHUNT to
# find out.
#
# One action per addressee, because the previous text told the AGENT to prefix
# the command with SKIP_BUGHUNT=1 — something only a human can do. The agent
# tried anyway, and then carried the prefix onto unrelated commands, which is
# how a bug hunter came to interfere with posting a ticket comment.
echo "OhMyBug: the current diff has not been hunted, or has CHANGED since the hunt (fixes count — re-hunt them)." >&2
echo "OhMyBug (agent): run /bughunter:review, or call submit_review then get_findings directly; the hunt records itself when it finishes, there is no manual step. If those calls are refused by this environment, say so and stop — do not retry them, do not add an env prefix, and never carry a prefix onto another command." >&2
echo "OhMyBug (operator): to merge without a hunt, run the merge yourself with SKIP_BUGHUNT=1 in front of it." >&2
echo "OhMyBug: diff id $CURRENT, HEAD ${HEAD_SHA:-unknown}, looked in $(ohmybug_hunt_dir 2>/dev/null || echo '(no repo key)')." >&2
exit 2
