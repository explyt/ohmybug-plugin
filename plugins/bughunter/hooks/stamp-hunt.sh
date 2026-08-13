#!/bin/bash
# Record the hunt the moment it actually happens — as a side effect of the
# TOOL CALL, not as a step the agent has to remember.
#
# Why this exists (owner report, 2026-08-11): the marker used to be written by
# the skill, so a hunt driven by calling the MCP tools directly — which is a
# perfectly normal way to use them — left no trace, and the pre-merge gate
# blocked a diff that HAD been hunted. That put the agent in front of a choice
# between forging the marker by hand and passing SKIP_BUGHUNT=1, and it
# correctly refused to forge. Both branches are wrong; the bookkeeping was.
# A control whose evidence depends on someone remembering to file it will
# eventually accuse honest work, and every false accusation trains the next
# person to disarm it.
#
# Two moments, because they are not the same diff:
#   submit_review  -> remember WHAT was sent (the pending id)
#   review is done -> promote it to the marker the gate reads
# Stamping "the current diff" at done-time would authorise fixes written while
# the review was still running — code the hunt never saw.
#
# ponytail: one pending slot per git-dir, not per review id. Submit A, submit B,
# then A finishes -> B's (newer, unfinished) diff gets promoted. Rare, and it
# fails toward blocking rather than allowing, because the gate still compares
# against the working tree. Key the pending file by review id if fan-out on one
# worktree ever becomes normal.
set -u

INPUT=$(cat 2>/dev/null) || exit 0

FIELDS=$(printf '%s' "$INPUT" | python3 -c '
import hashlib, json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool = (d.get("tool_name") or "").split("__")[-1]
# The response shape differs between clients and MCP versions (raw object,
# {content:[{text:"…json…"}]}, …), so ask the flattened text rather than
# guessing a path into it. Escaped quotes survive that flattening, hence \\\\?.
blob = json.dumps(d.get("tool_response"))
done = "1" if re.search(r"\\\\?\"status\\\\?\":\s*\\\\?\"done", blob) else "0"
review = inp.get("review_id") if isinstance(inp := d.get("tool_input") or {}, dict) else ""
if not isinstance(review, str) or not review:
    m = re.search(r"\\\\?\"review_id\\\\?\":\\s*\\\\?\"([^\\\\?\"]+)", blob)
    review = m.group(1) if m else ""

# The identity of a hunt, taken from the hunt itself.
#
# Deriving it from `git diff` in the hook cwd is what broke: the work can live
# in a worktree while this hook stands in the main checkout, where there are no
# local changes at all — so the id came out empty and the hunt was recorded
# NOWHERE, silently, and the gate then blocked a diff that had been reviewed.
# These bytes are the ones the server saw, whatever directory anyone is in.
diff = inp.get("diff")
sent = hashlib.sha256(diff.encode()).hexdigest() if isinstance(diff, str) and diff else ""

# The no-payload path sends no diff at all — the server fetches it from GitHub
# for repo@ref — so there the commit IS the identity.
meta = inp.get("meta") or {}
ref = meta.get("ref") if isinstance(meta, dict) else None
ref = ref if isinstance(ref, str) and ref else ""

# One field per line: a cwd may contain spaces, and a newline in a path is not
# something this hook needs to survive.
print(tool, done, d.get("cwd") or "", sent, ref, review, sep="\n")
' 2>/dev/null) || exit 0

TOOL=$(printf '%s' "$FIELDS" | sed -n 1p)
DONE=$(printf '%s' "$FIELDS" | sed -n 2p)
CWD=$(printf '%s' "$FIELDS" | sed -n 3p)
SENT=$(printf '%s' "$FIELDS" | sed -n 4p)
REF=$(printf '%s' "$FIELDS" | sed -n 5p)
REVIEW=$(printf '%s' "$FIELDS" | sed -n 6p)

[ -n "${TOOL:-}" ] || exit 0
[ -n "${CWD:-}" ] && [ -d "$CWD" ] && cd "$CWD" 2>/dev/null

. "$(dirname "$0")/diff-id.sh" 2>/dev/null || exit 0
MARKER=$(ohmybug_marker_path) || exit 0
REPO_HUNTS=$(ohmybug_hunt_dir) || exit 0
PENDING_DIR="$REPO_HUNTS.pending"
PENDING="$PENDING_DIR/${REVIEW:-unknown}"

case "$TOOL" in
  submit_review)
    # Every id this submit could legitimately be known by, newline-separated.
    # The sent bytes first, because that one is true from any directory; the
    # working diff second, for a client that reformatted what it sent; the ref
    # last, for the no-payload path where there are no bytes to hash.
    [ -n "$REVIEW" ] || exit 0
    mkdir -p "$PENDING_DIR" 2>/dev/null || exit 0
    {
      [ -n "$SENT" ] && printf '%s\n' "$SENT"
      ID=$(ohmybug_diff_id 2>/dev/null) && [ -n "$ID" ] && printf '%s\n' "$ID"
      [ -n "$REF" ] && printf 'ref:%s\n' "$REF"
      true
    } > "$PENDING.tmp" 2>/dev/null || exit 0
    if [ -s "$PENDING.tmp" ]; then
      mv "$PENDING.tmp" "$PENDING"
    else
      rm -f "$PENDING.tmp"
      # Nothing identifiable was sent. Say so: this used to exit silently, and a
      # silent non-recording is indistinguishable from a hunt that never ran —
      # which is how the gate came to accuse work that had been reviewed.
      echo "ohmybug: submit carried no diff and no meta.ref, so this hunt cannot be recorded; the merge gate will not see it" >&2
    fi
    ;;
  get_findings|confirm_findings)
    # confirm_findings only exists after a done review, so it needs no status
    # check; get_findings is polled while the review is still running.
    [ "$TOOL" = 'confirm_findings' ] || [ "${DONE:-0}" = '1' ] || exit 0
    if [ -s "$PENDING" ]; then
      # Promote what was SENT, not what the tree looks like now: fixes written
      # while the review ran were never hunted.
      while IFS= read -r line; do
        [ -n "$line" ] && ohmybug_record_hunt "$line"
      done < "$PENDING"
      # The single-slot marker stays written for one more release: a gate from an
      # older install still reads only that file.
      mkdir -p "$(dirname "$MARKER")" && head -n 1 "$PENDING" > "$MARKER"
      rm -f "$PENDING"
    else
      # No pending: another session owns the submit. Never hash this cwd: in a
      # worktree flow it may be a different checkout and would bless the wrong
      # diff. The owning session will promote the recorded payload.
      exit 0
    fi
    ;;
esac
exit 0
