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
def body_of(r):
    # Four envelopes for one response, and the client picks: the object itself,
    # a {content:[…]} wrapper, the bare content list, or one text part. Clean
    # hunts may have no later confirm call, so `done` must be readable in all.
    # Returns (body, errored): the JSON object the server sent, or {} when none can be
    # read, and whether the envelope itself said the call failed.
    if isinstance(r, str):
        try:
            r = json.loads(r)
        except Exception:
            return {}, False
    if isinstance(r, list):
        r = {"content": r}
    if isinstance(r, dict):
        errored = r.get("isError") is True
        if isinstance(r.get("status"), str):
            return r, errored
        parts = [r] if isinstance(r.get("text"), str) else r.get("content")
        if isinstance(parts, list):
            for part in parts:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    try:
                        inner = json.loads(part["text"])
                    except Exception:
                        continue
                    if isinstance(inner, dict):
                        return inner, errored
        return {}, errored
    return {}, False

body, errored = body_of(resp)
status = body.get("status") if isinstance(body.get("status"), str) else ""
done = "1" if status == "done" else "0"
failed = "1" if status == "failed" else "0"
# Is this a REVIEW OF RECORD — the gate decision the server puts beside `status`
# — or a run that ended `done` without reviewing what it was sent? `status: done`
# is true of a cut-short, blind and protocol-holed row alike, and a marker
# written on `done` alone opened the merge gate for every one of them. The
# field the server sends decides; when an older server omits it, the pair it was
# derived from decides (absent = legacy, never = refused, or a plugin rolled
# out ahead of the server blocks every honest hunt). An errored call decides
# nothing: it is not a response about the review at all.
ofr = body.get("review_of_record")
if ofr is None:
    refused = (bool(body.get("cut_short")) or body.get("protocol") == "incomplete"
               or body.get("pipeline_completed") is False)
else:
    refused = ofr is not True
record = "0" if refused else "1"
# The error envelope of the server carries `error` and no `status`; that of the client
# carries `isError`. Either way nothing here describes a finished review — not
# a promotion, and not a verdict on the review either: "not done yet" is an
# error the agent will hear again from the next poll.
errored = "1" if (errored or ("error" in body and not status)) else "0"
# Whether any response was read at all. confirm_findings has no status to wait
# for, so it is the one call where "nothing readable" must be told apart from
# "readable, and of record": an unreadable answer promotes nothing, and the
# pending record stays for a later get_findings to promote.
readable = "1" if body else "0"
inp = d.get("tool_input") or {}
inp = inp if isinstance(inp, dict) else {}
# WHICH review a record is filed under. For a poll or a confirm the id is the
# argument the agent passed, and the server answers about that id. For
# submit_review the id is MINTED BY THE SERVER and lives only in the answer:
# the call has no review_id parameter, and the server drops unknown keys — so
# an id typed into the input would be accepted by the server, ignored by it,
# and used HERE to file the current diff under an older, finished review that
# the next poll then promotes. The pending record binds a diff to a review;
# the party constrained by that binding does not get to pick the review.
review = "" if tool == "submit_review" else inp.get("review_id")
# upload:true means the payload bytes leave the machine OUT OF BAND — this hook
# never sees them, so they can prove nothing about any tree.
upload = "1" if inp.get("upload") is True else "0"
if not isinstance(review, str) or not review:
    review = body.get("review_id") if isinstance(body.get("review_id"), str) else ""
if not review:
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

# WHO is recording this. The hook is handed the session id on stdin, so the
# party that writes the pending record knows, at the time of writing, who it is
# — and nothing else in the system does: the API key authenticates a machine, not
# a session, and /mcp on the server is stateless, so "whose run is this" is not
# answerable there at any price. Appended after the original nine, so a reader
# that splits by position keeps reading the same lines it always did.
print(tool, done, one_line(d.get("cwd")), sent, one_line(ref), one_line(review),
      pre, failed, upload, one_line(d.get("session_id")), record, readable,
      errored, one_line(body.get("gate_note")), sep="\n")
' 2>/dev/null) || exit 0

TOOL=$(printf '%s' "$FIELDS" | sed -n 1p)
DONE=$(printf '%s' "$FIELDS" | sed -n 2p)
CWD=$(printf '%s' "$FIELDS" | sed -n 3p)
SENT=$(printf '%s' "$FIELDS" | sed -n 4p)
REF=$(printf '%s' "$FIELDS" | sed -n 5p)
REVIEW=$(printf '%s' "$FIELDS" | sed -n 6p)
PRE=$(printf '%s' "$FIELDS" | sed -n 7p)
FAILED=$(printf '%s' "$FIELDS" | sed -n 8p)
UPLOAD=$(printf '%s' "$FIELDS" | sed -n 9p)
# Sanitised the same way the review id is, and for the same reason: it becomes a
# line in a file other hooks match with `grep -x`, so anything but the shape of
# an id is not an id we need to keep.
# `tr -d '\n'` first: the sanitiser rewrites every byte outside the id
# alphabet, and the newline sed leaves on a line that is no longer the last one
# is such a byte — without this, every session id gained a trailing `_` and no
# nudge ever matched its own hunt again.
SESSION=$(printf '%s' "$FIELDS" | sed -n 10p | tr -d '\n' | tr -c 'A-Za-z0-9_.-' '_')
RECORD=$(printf '%s' "$FIELDS" | sed -n 11p)
READABLE=$(printf '%s' "$FIELDS" | sed -n 12p)
ERRORED=$(printf '%s' "$FIELDS" | sed -n 13p)
GATE_NOTE=$(printf '%s' "$FIELDS" | sed -n 14p)

[ -n "${TOOL:-}" ] || exit 0
[ -n "${CWD:-}" ] && [ -d "$CWD" ] && cd "$CWD" 2>/dev/null

# How a PostToolUse hook talks to the agent, in BOTH clients. The old way was
# exit 2 with the sentence on stderr: in Claude Code that puts stderr in front
# of the model beside a tool result that survives; in Codex the same exit code
# REPLACES the tool result with the stderr — so once these hooks load there,
# every confirm_findings (whose pending record the done-poll already promoted)
# would hand the agent this hook's sentence instead of billed_usd, receipt and
# share, and a submit that could not be recorded would lose its own review_id.
# `hookSpecificOutput.additionalContext` on exit 0 is read by both: extra
# context beside the result, the result untouched. Plain text on stdout at
# exit 0 reaches only the transcript, which is how these diagnostics went a
# year unseen (plugin#2) — so it is JSON, always, or exit 2 never.
say() { # sentence -> the agent, result intact
  python3 -c 'import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": sys.argv[1]}}))' "$1" 2>/dev/null
}

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
  # One rule for which ref may key a record, shared with the promote path
  # below: ohmybug_ref_here — a sha-spelled ref (the spelling that pins the
  # same commit everywhere) naming the HEAD of one of this repository's
  # worktrees. A branch or tag name resolves HERE to whatever this clone
  # happens to hold while the server fetches the same name from the remote;
  # and the offer is filed under the RESOLVED sha, the key the gate looks up.
  if [ -n "$REF" ]; then
    RESOLVED=$(ohmybug_ref_here "$REF") && [ -n "$RESOLVED" ] &&
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
    # The SAME key the PreToolUse branch filed, which is the RESOLVED sha: the
    # raw ref is whatever the model typed, so clearing under it removed nothing
    # and the attempt outlived the call it described — a permitted hunt then
    # read as a refused one and the next merge was waved through on that claim.
    [ -n "$SENT" ] && ohmybug_clear_attempt "$SENT"
    if [ -n "$REF" ]; then
      CLEARED=$(git rev-parse --verify --quiet "$REF^{commit}" 2>/dev/null)
      [ -n "$CLEARED" ] && ohmybug_clear_attempt "ref:$CLEARED"
    fi
    # A submit the SERVER refused (rate_limited, out of credit, bad request)
    # minted no review: there is nothing to file a pending record for, and a
    # record written here would say "a hunt is RUNNING" about a hunt that never
    # started — then hold the Stop nudge and the gate on it. The tool result
    # already tells the agent why; the attempt record above is cleared all the
    # same, because the environment did allow the call.
    [ "${ERRORED:-0}" = '1' ] && exit 0
    # No id the SERVER minted could be read out of the answer: nothing to file
    # the diff under. Silent, this was indistinguishable from a hunt that never
    # ran; said, the agent can poll from this checkout or submit again.
    if [ -z "$REVIEW" ]; then
      say "ohmybug: the submit_review answer carried no review_id this hook could read, so this hunt was not recorded and the merge gate will not see it — if the tool result shows a review id, the review is running but unrecorded here: submit again from this checkout once it ends, or expect the gate to ask for a hunt."
      exit 0
    fi
    # Every id this submit could legitimately be known by, newline-separated.
    # The sent bytes first, because that one is true from any directory; the
    # working-tree ids only when the payload proves to BE this tree; the ref
    # last, for the no-payload path where there are no bytes to hash.
    mkdir -p "$PENDING_DIR" 2>/dev/null || exit 0
    TREEOK=0 REFOK=0
    {
      [ -n "$SENT" ] && printf '%s\n' "$SENT"
      # The working-tree ids describe THIS checkout, not the call — so they may
      # only be filed once the payload is shown to BE this checkout. Unguarded,
      # a submit of one file blessed every other dirty file beside it, and a
      # submit of another repository blessed whatever this cwd happened to hold.
      # The diff id comes from the helper itself — the very bytes the equality
      # validated, not a second `git diff` a fast external writer could race.
      # The emptiness test is kept beside the helper's own: this is the line that
      # authorises a merge, and one guard is one deletion away from none.
      if [ -n "$SENT" ] && ID=$(ohmybug_sent_is_local "$SENT") && [ -n "$ID" ]; then
        TREEOK=1
        printf '%s\n' "$ID"
        # ...and the same diff with docs and skills taken out, so that editing
        # prose after the hunt does not read as unhunted code. Tests are NOT
        # taken out any more: they are the protection the hunt checked.
        SIG=$(ohmybug_sig_id 2>/dev/null) && [ -n "$SIG" ] && printf 'sig:%s\n' "$SIG"
      fi
      # A ref is the CALL's identity only when the call carried no bytes: on
      # the no-payload path the server's review IS of repo@ref. With a payload
      # the server reviewed the payload, whatever meta.ref claims — recording
      # the ref too would let one junk diff plus a HEAD sha bless a clean
      # checkout the reviewers never saw. Which spellings may key the record
      # is ohmybug_ref_here's rule, shared with the PreToolUse branch above.
      if [ -z "$SENT" ] && [ -n "$REF" ]; then
        if R=$(ohmybug_ref_here "$REF") && [ -n "$R" ]; then
          printf 'ref:%s\n' "$R"
          REFOK=1
          # A PURE no-payload submit (no out-of-band upload either) leaves the
          # server exactly one source of bytes: repo@ref, fetched by the server
          # itself. When this cwd stands at that commit with nothing
          # uncommitted, the working diff IS the reviewed diff — so the tree
          # ids are as trustworthy as the ref line, and prose edited after the
          # hunt stays just prose (sig:) instead of demanding a paid re-hunt
          # of a README. An upload breaks that equality (the server reviews
          # the uploaded bytes, which this hook never sees): no tree ids then.
          if [ "${UPLOAD:-0}" != 1 ] && [ "$R" = "$(git rev-parse HEAD 2>/dev/null)" ] &&
             [ -z "$(git status --porcelain 2>/dev/null)" ]; then
            ID=$(ohmybug_diff_id 2>/dev/null) && [ -n "$ID" ] && printf '%s\n' "$ID"
            SIG=$(ohmybug_sig_id 2>/dev/null) && [ -n "$SIG" ] && printf 'sig:%s\n' "$SIG"
            TREEOK=1
          fi
        fi
      fi
      # Who submitted, when the client told us. NOT an id this record can be
      # looked up by — `ohmybug_pending_has` matches whole lines against ids it
      # is asked about, and nobody asks about this one — so it changes no
      # authorisation and cannot bless a merge. It exists so the Stop nudge can
      # tell its own submits from the ones another session on this machine made:
      # four nudges out of five about somebody else's run is how a session learns
      # to skip the fifth.
      #
      # LAST, and excluded from the emptiness test below, because that test is
      # what decides whether a record exists at all: a record carrying only who
      # wrote it names no diff, satisfies no gate lookup, and would turn every
      # unrecordable submit into a permanent nag with nothing to satisfy it.
      [ -n "$SESSION" ] && printf 'session:%s\n' "$SESSION"
      true
    } > "$PENDING.tmp" 2>/dev/null || exit 0
    if [ -s "$PENDING.tmp" ] && grep -qv '^session:' "$PENDING.tmp" 2>/dev/null; then
      mv "$PENDING.tmp" "$PENDING"
      # The dead ends are announced at SUBMIT time, to the agent (`say`) —
      # otherwise they surface at merge time as "never hunted" with nothing
      # naming the cause.
      # A record holding only the sent bytes' hash satisfies no gate lookup:
      if [ "$TREEOK" = 0 ] && [ "$REFOK" = 0 ] && [ -n "$SENT" ]; then
        say "ohmybug: the payload does not match this working tree, so the merge gate will not recognise this tree as hunted — send the full working diff verbatim, or submit with no payload and meta.ref set to the pushed head commit sha"
      fi
      # ...and out-of-band bytes prove nothing about this tree, while with
      # uncommitted work the ref: line is never honoured either:
      if [ -z "$SENT" ] && [ "${UPLOAD:-0}" = 1 ] && [ "$TREEOK" = 0 ] &&
         { [ "$REFOK" = 0 ] || [ -n "$(git status --porcelain 2>/dev/null)" ]; }; then
        say "ohmybug: the uploaded bytes go out of band, so the merge gate cannot verify them against this tree and will still block — to record the hunt, send the full working diff inline, or commit, push, and submit with meta.ref = the pushed head sha"
      fi
    else
      rm -f "$PENDING.tmp"
      # Nothing identifiable was sent. Say so: this used to exit silently, and a
      # silent non-recording is indistinguishable from a hunt that never ran —
      # which is how the gate came to accuse work that had been reviewed.
      say "ohmybug: submit carried no diff, and no meta.ref spelled as a commit sha this repository is checked out on (cwd $PWD), so this hunt cannot be recorded; the merge gate will not see it"
    fi
    ;;
  get_findings|wait_review|confirm_findings)
    # get_findings and wait_review are polled while the review is still running
    # and answer with the same terminal body; confirm_findings only exists after
    # a done review, so it has no status to wait for — but it does have an
    # answer to read, and an error or nothing readable is not the answer.
    #
    # DONE is decided first. A review that ends `failed` is over and its pending
    # record must not sit there saying "a hunt is RUNNING" forever — but asking
    # that question first threw finished reviews away.
    if [ "$TOOL" != 'confirm_findings' ] && [ "${DONE:-0}" != '1' ]; then
      [ "${FAILED:-0}" = '1' ] && rm -f "$PENDING"
      exit 0
    fi
    # An errored call is not a response about the review: "not done yet" on a
    # confirm leaves the pending record exactly where it was.
    [ "${ERRORED:-0}" = '1' ] && exit 0
    if [ "$TOOL" = 'confirm_findings' ] && [ "${READABLE:-0}" != '1' ]; then
      # One-shot call, unreadable answer: promote nothing, lose nothing. The
      # pending record stays, and the next get_findings promotes it if the
      # review is of record.
      [ -s "$PENDING" ] && say "ohmybug: the confirm_findings answer for $REVIEW was not readable JSON, so nothing was promoted into the merge marker; call get_findings once more from this checkout to record the finished hunt."
      exit 0
    fi
    # Already promoted from this checkout — the done-poll took the pending
    # record and left this tombstone. A later poll or the confirm that always
    # follows has nothing to do and nothing to say: without the tombstone every
    # confirm_findings ended in the "no rev-id record" paragraph below, once per
    # hunt, in every session — the sentence that exists for the rare worktree
    # mix-up, taught as noise by the common case.
    [ -e "$PENDING.promoted" ] && exit 0
    # `done` is not the gate decision. A run stopped before it reviewed anything
    # — cut short, blind, its protocol holed — ends `done` like any other, with
    # `review_of_record: false` beside it. The review is over, so the pending
    # record goes (the Stop nudge must not hold the turn for a finished run),
    # but nothing is promoted: the gate stays shut on a diff no review of record
    # has seen, and the sentence the server put beside the decision is the one
    # the agent reads, so the next move is the server's, not a guess.
    if [ "${RECORD:-0}" != '1' ]; then
      if [ -s "$PENDING" ]; then
        rm -f "$PENDING"
        # The same tombstone the promote path leaves: the review is equally
        # over, and the confirm that follows must not read its absence as the
        # worktree mix-up and send the agent to re-poll a refused review.
        : > "$PENDING.promoted" 2>/dev/null
        say "ohmybug: review $REVIEW finished but is NOT a review of record${GATE_NOTE:+ — $GATE_NOTE}. Nothing was promoted into the merge marker and the merge gate stays shut for this diff: it has not been hunted. Submit it again."
      fi
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
      # The tombstone the calls after this one read (above). Empty on purpose:
      # `ohmybug_pending_has` matches whole lines against ids, and a file with
      # no lines can bless nothing. Aged out with the records it sits beside.
      : > "$PENDING.promoted" 2>/dev/null
    else
      # No pending: another session owns the submit. Never hash this cwd: in a
      # worktree flow it may be a different checkout and would bless the wrong
      # diff. The owning session will promote the recorded payload.
      #
      # But SAY it, and name the directory, because the other reading of this
      # branch is the expensive one: the session that did submit is standing in
      # a different checkout, so the promotion silently no-ops and the gate then
      # blocks a diff that was hunted and paid for (owner report, 2026-08-22).
      # The hook cannot tell the two apart — the agent can, and only if it is
      # told (`say`; the call has already run, so nothing is blocked).
      # WHAT WAS NOT FOUND, and no conclusion about the gate. The old sentence
      # ended "the merge gate will not see this hunt", which does not follow from
      # its own premise: the gate has four ways to recognise a hunted diff — the
      # diff id, `sig:<id>` (prose-only changes since the hunt), `ref:<sha>` on a
      # clean tree, and a live pending record — and the absence of a rev-id record
      # in THIS cwd rules out none of them.
      #
      # The cost of that inference was measured on a client wave: three sessions
      # read it as a statement about the gate and reported their hunts uncounted
      # while `ref:<sha>` records for those very hunts sat on disk; one was about
      # to ask the owner for SKIP_BUGHUNT. A true fact with a false conclusion
      # attached pushes an operator to disarm the control, and it is worse than a
      # plain error because there is nothing in the message to disprove.
      say "ohmybug: no rev-id record for $REVIEW in $PWD, so THIS call promoted nothing. That is not a statement about the merge gate: the gate recognises a hunted diff by any of four keys — the diff id, sig:<id> (when everything changed since the hunt is docs/skills), ref:<sha> on a clean tree, or a live pending record — and this says nothing about those. Run the gate to find out. What the rev-id record is FOR: it is the one that promotes a finished review into the marker, so if this session submitted the review, the submit ran from another checkout — re-run get_findings from the worktree the diff lives in. If another session owns it, that one will promote it: ignore this."
    fi
    ;;
esac
exit 0
