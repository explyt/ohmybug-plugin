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
# Which event fired. The explicit field when the client sends it; the absence of
# a response as the fallback, since only PostToolUse carries one. Deriving it
# here rather than from an argument means the wiring in hooks.json is the same
# line for both events and cannot be half-installed. Key PRESENCE, not
# truthiness: an errored call may carry an empty response, and reading that as
# "no response" would file a finished hunt as a mere attempt.
event = d.get("hook_event_name")
if event in ("PreToolUse", "PostToolUse"):
    pre = "1" if event == "PreToolUse" else "0"
else:
    pre = "0" if "tool_response" in d else "1"
resp = d.get("tool_response")
blob = json.dumps(resp)
# WHICH STATUS, not "does this text contain the word". The response shape differs
# between clients and MCP versions (raw object, {content:[{text:"…json…"}]}, …),
# so look for the status field in both shapes — but never in the prose. A review
# whose findings merely quote the characters status: failed used to delete the
# pending record and lose a hunt the user had paid for, and hunting this very
# repository produces exactly that prose.
def status_of(r):
    if isinstance(r, dict):
        s = r.get("status")
        if isinstance(s, str):
            return s
        parts = r.get("content")
        if isinstance(parts, list):
            for part in parts:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    try:
                        inner = json.loads(part["text"])
                    except Exception:
                        continue
                    if isinstance(inner, dict) and isinstance(inner.get("status"), str):
                        return inner["status"]
    return ""

status = status_of(resp)
done = "1" if status == "done" else "0"
failed = "1" if status == "failed" else "0"
review = inp.get("review_id") if isinstance(inp := d.get("tool_input") or {}, dict) else ""
if not isinstance(review, str) or not review:
    # Same escaping rules as the `done` match above: \s, not \\s — the latter
    # is a literal backslash in a raw string and never matches, which recorded
    # NOTHING for every flow whose review_id lives only in the response
    # (worktree and no-payload submits, plugin#2).
    m = re.search(r"\\\\?\"review_id\\\\?\":\s*\\\\?\"([^\\\\\"]+)", blob)
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
# A newline in any field would shift every field after it, and `review_id` is
# model-authored: one newline there made a PostToolUse read as a PreToolUse, so
# the finished review never promoted. The path sanitiser downstream runs after
# the split and cannot help.
def one_line(v):
    return (v if isinstance(v, str) else "").replace("\n", " ").replace("\r", " ")

print(tool, done, one_line(d.get("cwd")), sent, one_line(ref), one_line(review),
      pre, failed, sep="\n")
' 2>/dev/null) || exit 0

TOOL=$(printf '%s' "$FIELDS" | sed -n 1p)
DONE=$(printf '%s' "$FIELDS" | sed -n 2p)
CWD=$(printf '%s' "$FIELDS" | sed -n 3p)
SENT=$(printf '%s' "$FIELDS" | sed -n 4p)
REF=$(printf '%s' "$FIELDS" | sed -n 5p)
REVIEW=$(printf '%s' "$FIELDS" | sed -n 6p)
PRE=$(printf '%s' "$FIELDS" | sed -n 7p)
FAILED=$(printf '%s' "$FIELDS" | sed -n 8p)

[ -n "${TOOL:-}" ] || exit 0
[ -n "${CWD:-}" ] && [ -d "$CWD" ] && cd "$CWD" 2>/dev/null

. "$(dirname "$0")/diff-id.sh" 2>/dev/null || exit 0
MARKER=$(ohmybug_marker_path) || exit 0
REPO_HUNTS=$(ohmybug_hunt_dir) || exit 0
PENDING_DIR="$REPO_HUNTS.pending"
# The review id is the one model-authored string that becomes a path here, and
# `..` in it would walk out of ~/.ohmybug/ and overwrite a file elsewhere. Real
# ids are alphanumeric; anything else is not an id we need to preserve.
REVIEW=$(printf '%s' "$REVIEW" | tr -c 'A-Za-z0-9_.-' '_' | sed 's/^[.-]*//')
PENDING="$PENDING_DIR/${REVIEW:-unknown}"

# PreToolUse: the model OFFERED this diff for hunting.
# Recorded before anyone gets to allow or refuse the call, because the refusal is
# exactly the case that matters: in auto mode the permission classifier turns
# these tools down by design, and until now that left the merge gate blocking
# forever with no move the agent could make — its own advice, an env prefix on
# the merge, is a control-disabling prefix that the classifier also refuses.
# Block "never tried"; warn on "tried, and the environment said no".
#
# What counts as an offer is deliberately narrow, because this record authorises
# a merge and the party it constrains writes it:
#   - only submit_review. A get_findings poll offers nothing — it names a review
#     id and no diff — so honouring it would mean one throwaway call with an
#     invented id disarms the gate. The tool is checked HERE and not only in the
#     matcher, so widening hooks.json cannot widen the authorisation by accident.
#   - only ids the call itself carries: the bytes in `diff`, or `meta.ref` when
#     it names the commit this tree is actually on. Hashing the working tree
#     instead would mean any call, carrying anything, blesses whatever happens to
#     be checked out — including fixes written after the offer.
if [ "${PRE:-0}" = "1" ]; then
  [ "$TOOL" = submit_review ] || exit 0
  [ -n "$SENT" ] && ohmybug_record_attempt "$SENT"
  # Resolve the ref rather than string-comparing it: `meta.ref` is documented as
  # the head, and a branch name or a short sha that points AT this commit is the
  # same offer. Matching only the full sha meant the no-payload flow — the one
  # the skill calls preferred — recorded nothing, so a refused hunt there left
  # the merge blocked with no way out, which is the trap this whole change
  # exists to remove.
  if [ -n "$REF" ]; then
    RESOLVED=$(git rev-parse --verify --quiet "$REF^{commit}" 2>/dev/null)
    # Record under the RESOLVED sha, which is the key the gate looks up. A
    # branch name filed under its own name is a record nothing ever reads.
    [ -n "$RESOLVED" ] && [ "$RESOLVED" = "$(git rev-parse HEAD 2>/dev/null)" ] &&
      ohmybug_record_attempt "ref:$RESOLVED"
  fi
  exit 0
fi

case "$TOOL" in
  submit_review)
    # This event only exists because the call was ALLOWED to run. So whatever the
    # server answered, the attempt record has done its job and must go: left
    # standing it says "the environment refused the hunt" about a call the
    # environment permitted, and the next merge is waved through on that claim.
    [ -n "$SENT" ] && ohmybug_clear_attempt "$SENT"
    [ -n "$REF" ] && ohmybug_clear_attempt "ref:$REF"
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
    #
    # DONE is decided first. A review that ends `failed` is over and its pending
    # record must not sit there saying "a hunt is RUNNING" forever — but asking
    # that question first threw finished reviews away.
    if [ "$TOOL" != 'confirm_findings' ] && [ "${DONE:-0}" != '1' ]; then
      [ "${FAILED:-0}" = '1' ] && rm -f "$PENDING"
      exit 0
    fi
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
