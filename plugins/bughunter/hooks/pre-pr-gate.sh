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

DECIDE=$(printf '%s' "$INPUT" | python3 -c '
import json, re, shlex, sys

MERGERS = (("gh", "pr", "merge"), ("glab", "mr", "merge"))
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
# Anything that can end one command and start another. Keywords matter: after
# `then` or `do` comes a fresh command, and treating them as separators is what
# stops `if x; then gh pr merge; fi` from hiding.
SEPS = {";", "&&", "||", "|", "&", "(", ")", "{", "}", "\n", "then", "do",
        "else", "elif", "fi", "done", "in", "!"}

# A heredoc body is DATA. shlex has no idea it is reading one, and the per-line
# retry below reads raw lines, so without this a document that quotes the merge
# command — a runbook, a lessons comment, this project talking about itself —
# reads as a merge and the writing of it gets blocked. Blank the bodies out and
# keep everything else, so a merge that follows a heredoc is still seen.
QUOTE_CHARS = "\"" + chr(39)
# `<<` only where a redirection can start, and never `<<<`: a here-string is not
# a heredoc, and matching inside one made `grep -rn "<<<<<<< HEAD"` capture HEAD
# as a terminator and blank every line after it — including a real merge.
HEREDOC_START = re.compile(r"(?<![<\w])<<-?(?!<)\s*[" + QUOTE_CHARS + r"]?(\w+)")

def blank_heredocs(cmd):
    lines = cmd.split("\n")
    i = 0
    while i < len(lines):
        for m in HEREDOC_START.finditer(lines[i]):
            term = m.group(1)
            j = i + 1
            while j < len(lines) and lines[j].strip() != term:
                j += 1
            if j >= len(lines):
                # No terminator anywhere, so this was never a heredoc opener —
                # a quoted `<<WORD` inside an argument, most likely. Blanking
                # the rest of the command on that guess erased real merges.
                continue
            for k in range(i + 1, j + 1):
                lines[k] = ""
            i = j
        i += 1
    return "\n".join(lines)

def join_quoted_newlines(cmd):
    """Newlines inside quotes are data. A multi-line commit message must not
    turn the line after it into a fresh command position."""
    out = []
    quote = ""
    for ch in cmd:
        if quote:
            if ch == quote:
                quote = ""
            elif ch == "\n":
                ch = " "
        elif ch in QUOTE_CHARS:
            quote = ch
        out.append(ch)
    return "".join(out)

def code_only(cmd):
    """The command with its DATA blanked out: heredoc bodies become empty lines
    and quoted spans become spaces. What survives is the text a shell would
    execute — the only place a command, or an opt-out, can really begin.

    Heredocs go FIRST. Doing quotes first destroyed the very recognition this
    depends on: one apostrophe in a body swallowed the terminator line, so
    blank_heredocs found no terminator and blanked nothing, and the body then
    reached the opt-out regex — which is the whole attack this function exists
    to stop. A quoted terminator (`<<EOF` written as <<{q}EOF{q}) broke the
    opener match the same way."""
    out = []
    quote = ""
    for ch in blank_heredocs(cmd):
        if quote:
            if ch == quote:
                quote = ""
            elif ch != "\n":
                ch = " "
        elif ch in QUOTE_CHARS:
            quote = ch
        out.append(ch)
    return "".join(out)

def segments(cmd, depth=0, quiet=False):
    """Yield token lists, one per command position, recursing into `sh -c`."""
    if depth > 3:
        return
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    try:
        tokens = list(lex)
    except ValueError:
        # Unbalanced quotes: we cannot tokenize, so we cannot rule a merge out.
        # Only the top-level parse gets to say that; a per-line retry that fails
        # is just a line we could not read, not a verdict about the command.
        if not quiet:
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
    # A newline ends a command as surely as `;` does, but shlex eats it as
    # whitespace, so `npm test<newline>gh pr merge 5` arrives here as ONE
    # segment whose head is ("npm", "test", "gh") and walks straight through.
    # Listing "\n" in SEPS never helped: the token never reaches that test.
    # So re-read the lines — but only where a line break really is a command
    # break. Newlines inside quotes are folded away and heredoc bodies blanked
    # first; a global "does any token span lines" veto used to do this job, and
    # one multi-line commit message then disabled the whole re-read.
    if "\n" in cmd:
        for line in blank_heredocs(join_quoted_newlines(cmd)).split("\n"):
            if line.strip():
                yield from segments(line, depth + 1, quiet=True)
    # A shell invoked with -c carries a whole command line in one argument.
    for seg in list(segments_inner(tokens)):
        yield from segments(seg, depth + 1, quiet)

def segments_inner(tokens):
    for i, t in enumerate(tokens):
        if t.split("/")[-1] in SHELLS:
            for j in range(i + 1, len(tokens)):
                if tokens[j] == "-c" and j + 1 < len(tokens):
                    yield tokens[j + 1]
                    break

# Words that take a command as their argument and change nothing about it. Left
# in place they hide the merge behind a head test that only reads three words:
# `env gh pr merge` and `sudo gh pr merge` walked straight through.
WRAPPERS = {"env", "command", "sudo", "nohup", "time", "exec", "builtin"}

def strip_env(seg):
    """Drop leading VAR=value words and command wrappers; report an opt-out.

    ONE walk, taking whichever comes next. Two passes in a fixed order — first
    assignments, then wrappers — meant `env FOO=bar gh pr merge` ended the walk
    at FOO=bar and the head read as ("FOO=bar", "gh", "pr"), which matches no
    merger, so the merge ran with the gate silent."""
    skip = False
    i = 0
    while i < len(seg):
        word = seg[i]
        if "=" in word:
            name = word.split("=", 1)[0]
            if not name or not (name[0].isalpha() or name[0] == "_"):
                break
            if not all(c.isalnum() or c == "_" for c in name):
                break
            if name == "SKIP_BUGHUNT" and word.split("=", 1)[1] == "1":
                skip = True
            i += 1
            continue
        if word.split("/")[-1] in WRAPPERS:
            i += 1
            continue
        break
    return seg[i:], skip

try:
    data = json.load(sys.stdin)
except Exception:
    # Not even JSON: print nothing, which the shell reads as "the parser did not
    # answer" and treats like a missing python3 — stand down and say so.
    sys.exit(0)
cmd = (data.get("tool_input") or {}).get("command") or ""
# Two facts about the COMMAND, for the branch where tokenizing failed. Read from
# the command and nowhere else: the payload also carries `description`, which the
# model writes itself, and a `cwd` the model chose — an opt-out honoured from
# either of those is an opt-out the agent grants itself, which is exactly what
# the escape hatch must not be.
# Quotes come off first, because shlex would have joined them: `gh pr me"rge"`
# tokenizes to a merge and must not read as "no merge here" just because the
# bytes are split.
# Quotes and backslashes come off, because shlex would have joined them:
# `gh pr me"rge"` tokenizes to a merge and must not read as "nothing to see".
# Heredoc bodies come out first, though: a document that quotes the command is
# the false block this whole change exists to remove, and on this path the
# regex is the only decider.
bare = "".join(c for c in blank_heredocs(cmd) if c not in QUOTE_CHARS + "\\")
looks_merge = "1" if re.search(r"\b(?:pr|mr)[ \t]+merge\b", bare) else "0"
# Position matters: `SKIP_BUGHUNT=1` counts as an opt-out where a command starts
# — the start of the line, or after a separator a person actually types. NOT
# after a bare newline: heredoc bodies are newline-separated, so that would let
# a document the model is writing opt the model out.
# ...and read from the code, never from the data: a `;` inside a heredoc body
# used to count as a command boundary, so a document the model was writing could
# hand the model the operator hatch.
opts_out = "1" if re.search(r"(?:\A|[;&|]\s*)SKIP_BUGHUNT=1[ \t]", code_only(cmd)) else "0"
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
# One field per line, same convention as the recorder. Not \x01-separated: the
# bash that ships with macOS is 3.2 and does not split IFS on that byte, so the
# whole answer arrived as field one and every verdict read as "not a merge" —
# a gate that silently allows everything, on the majority platform.
# The cwd is the one free-text field here, and a newline in it would shift the
# verdict into a field nobody reads — the gate then stands down in silence. The
# recorder learned this in the same change; this protocol is the same shape.
cwd_line = (data.get("cwd") or "").replace("\n", " ").replace("\r", " ")
print(cwd_line, verdict, looks_merge, opts_out, sep="\n")
' 2>/dev/null)

if [ -z "$DECIDE" ]; then
  # No python3, or it failed, or the payload was not JSON. Without python3 the
  # RECORDER cannot write a hunt either (stamp-hunt.sh is the same interpreter),
  # so on such a machine a block can never be lifted by hunting — it is a dead
  # end by construction, and a dead end is what teaches people to disarm the
  # gate. Stand down, loudly, and name the fix. The word test only decides
  # whether to say anything: evading it costs nothing but the message.
  case "$INPUT" in
    *"pr merge"*|*"mr merge"*)
      MSG="OhMyBug: python3 is unavailable here, so the gate cannot read this command — and the hunt recorder cannot run either, which means no hunt could ever lift a block. Allowing the merge unchecked. Install python3 to arm the gate again."
      echo "$MSG" >&2
      echo "$MSG" ;;
  esac
  exit 0
fi

SESSION_CWD=$(printf '%s' "$DECIDE" | sed -n 1p)
VERDICT=$(printf '%s' "$DECIDE" | sed -n 2p)
LOOKS_MERGE=$(printf '%s' "$DECIDE" | sed -n 3p)
OPTS_OUT=$(printf '%s' "$DECIDE" | sed -n 4p)

case "$VERDICT" in
  merge) ;;
  unparsed)
    # Unbalanced quotes are a fact about quoting, not about merging — and shlex
    # has no idea what a heredoc is, so every `cat <<'EOF'` whose body contains
    # an apostrophe arrives here. Fall back to the two flags the parser derived
    # from the COMMAND (never from the payload around it) and let the hunt check
    # below decide; do not accuse.
    [ "$LOOKS_MERGE" = 1 ] || exit 0
    [ "$OPTS_OUT" = 1 ] && exit 0
    ;;
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
# No local changes: landing somebody else's PR from a clean `main` is the most
# natural way to merge, and the code being merged never exists in this tree.
# Allowing is right; saying nothing is not — silence out of a PreToolUse hook is
# byte-identical to "hunted, allowed". Both streams, same as every sibling
# stand-down above: an exit-0 PreToolUse has no guaranteed channel to the model.
if [ -z "$CURRENT" ]; then
  MSG="OhMyBug: this checkout has no changes against its base, so the gate cannot tell whether the code being merged was hunted — allowing the merge unchecked. To hunt somebody else's PR, check it out (gh pr checkout <N>) and run /bughunter:review there."
  echo "$MSG" >&2
  echo "$MSG"
  exit 0
fi

# The hunt set, keyed on the repository rather than the working tree, so a hunt
# recorded from the main checkout is visible to a merge run in a worktree and the
# reverse. That mismatch blocked reviewed work three times.
if ohmybug_hunted "$CURRENT"; then
  exit 0
fi

# What a hunt can actually speak about: the diff without docs, tests and skills.
#
# Nothing significant at all means there is nothing to hunt — a docs-only branch
# should land without paying for a review of prose. And a hunted diff whose only
# later changes were prose is still hunted: the gate keys on a hash, so before
# this it demanded a fresh review (money, and a quarter of an hour) because
# someone fixed a typo in a README.
SIG=$(ohmybug_sig_id 2>/dev/null)
if [ -n "$SIG" ] && ohmybug_hunted "sig:$SIG"; then
  echo "OhMyBug: this diff was hunted; everything changed since then is documentation, tests or skills, which a hunt does not speak about. Allowing the merge." >&2
  exit 0
fi
if [ -z "$SIG" ] && [ "${OHMYBUG_HUNT_ALL:-0}" != "1" ]; then
  echo "OhMyBug: nothing in this diff can change behaviour — documentation, tests and skills only — so there is nothing to hunt. Allowing the merge." >&2
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

# A submit that WAS allowed and is still running is not a refusal — it is a
# review whose findings have not arrived. Merging now is merging ahead of them.
if ohmybug_pending_has "$CURRENT" ||
   { [ -n "$HEAD_SHA" ] && ohmybug_pending_has "ref:$HEAD_SHA"; }; then
  echo "OhMyBug: a hunt is RUNNING for this diff and has not returned yet. Poll get_findings until it says done, then merge." >&2
  echo "OhMyBug (operator): if that review died or was abandoned, the record ages out on its own; to merge before then, run the merge yourself with SKIP_BUGHUNT=1 in front of it." >&2
  exit 2
fi

# Asked for, and never finished. In auto mode the permission classifier refuses
# these tools by design — correctly, they send a diff off the machine — and an
# agent that has been refused has no move left: the escape hatch this hook used
# to recommend is an env prefix disabling a safety control, which the classifier
# refuses too. That is a dead end, and a dead end gets the plugin uninstalled.
# So: block "never tried", warn on "tried and the environment said no".
#
# The commit-keyed attempt carries the same clean-tree condition as the
# commit-keyed HUNT seventeen lines above, and for the same reason: it speaks
# about a commit, so anything uncommitted on top of it was never offered to
# anybody. Without that condition one attempt at a commit would authorise every
# edit ever written on top of it.
ATTEMPT=""
if ohmybug_attempted "$CURRENT"; then
  ATTEMPT=$CURRENT
elif [ -n "$HEAD_SHA" ] && [ -z "$(git status --porcelain 2>/dev/null)" ] &&
     ohmybug_attempted "ref:$HEAD_SHA"; then
  ATTEMPT="ref:$HEAD_SHA"
fi
# ...and only where the hunt could not have run anyway.
#
# The attempt is written by the party this gate constrains: the model decides to
# call, and the call carries the ids. On its own it says "a submit was made",
# never "the environment refused it" — so on its own it is a switch the agent can
# flip. What is NOT written by the model is the user's own permission settings.
# With no allow-rule for these tools the refusal is the environment's default and
# the block is a dead end worth stepping out of; with a rule, the tools work,
# and an unfinished hunt means the hunt is the thing to finish.
#
# ponytail: settings files are read as text, not merged as Claude Code merges
# them. A rule in an unusual location reads as "not permitted" and we warn where
# we could have blocked — the harmless direction. Ask the client for the answer
# if a hook API ever offers one.
if [ -n "$ATTEMPT" ] && ! ohmybug_tools_allowed; then
  MSG="OhMyBug: a submit_review call was made for this diff and no findings came back, and the hunt tools are not permitted in this environment — so the gate has nothing to stand on and is allowing the merge. To arm it, add one permission rule yourself: /permissions -> mcp__plugin_bughunter_ohmybug__*"
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
WHERE=$(ohmybug_hunt_dir 2>/dev/null || echo '(no repo key)')
# `~`, not the absolute path: the home directory usually carries the operator's
# name, and this line goes into a transcript.
WHERE=${WHERE/#$HOME/\~}
echo "OhMyBug: diff id $CURRENT, HEAD ${HEAD_SHA:-unknown}, looked in $WHERE." >&2
exit 2
