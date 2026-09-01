#!/bin/bash
# A hunt that was paid for and never read must not be how a turn ends.
#
# Why this exists (owner report, 2026-08-21): after two submit_review calls the
# agent polled once, saw `running`, ended its turn and waited to be prodded.
# Both reviews had been `done` for forty minutes when the user asked. The skill
# already says to arm a background monitor and not to end the turn silently —
# so the instruction was there and it was not followed. A control that depends
# on someone remembering is the same class of defect as the hunt marker the
# skill used to write by hand (see stamp-hunt.sh): the fix is to make the event
# do the work, not to say it louder.
#
# NO NETWORK on purpose. The nudge does not need the review's status: the agent
# has one call that answers with the truth AND promotes the pending record when
# the review is done. Asking the server here would add a host to hardcode, a
# timeout to get wrong, and a way for the end of every turn to hang on a curl.
set -u

INPUT=$(cat 2>/dev/null) || exit 0

# Two fields, one line each. No python3 (or unreadable input) means this hook
# cannot know anything, and a hook that cannot know anything must stand down:
# it fires at the end of EVERY turn, so a false block is far more expensive
# than a missed reminder.
FIELDS=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
# The harness own anti-loop signal: true means the previous stop was already
# blocked — by us or by anybody. Nudging there turns a reminder into a session
# that cannot end.
print("1" if d.get("stop_hook_active") else "0")
print((d.get("cwd") or "").replace("\n", " ").replace("\r", " "))
# WHO is being nudged. Measured cost of not knowing (owner report, one shift):
# ten foreign runs woke non-owners, one of them seven times, and a session in
# the middle of that was preparing to merge on "I am waiting for a clean hunt"
# that was never its hunt. Four nudges out of five about somebody else is how a
# session learns to skip the fifth (#444).
print((d.get("session_id") or "").replace("\n", " ").replace("\r", " "))
' 2>/dev/null) || exit 0

ACTIVE=$(printf '%s' "$FIELDS" | sed -n 1p)
CWD=$(printf '%s' "$FIELDS" | sed -n 2p)
SESSION=$(printf '%s' "$FIELDS" | sed -n 3p | tr -c 'A-Za-z0-9_.-' '_')

[ "${ACTIVE:-1}" = '0' ] || exit 0
# Source BEFORE the cd, because `$0` is only absolute by convention (hooks.json
# passes ${CLAUDE_PLUGIN_ROOT}): invoked by a relative path, the sourcing would
# fail after the cd and the hook would stand down silently on every turn.
. "$(dirname "$0")/diff-id.sh" 2>/dev/null || exit 0

[ -n "${CWD:-}" ] && [ -d "$CWD" ] && cd "$CWD" 2>/dev/null
DIR=$(ohmybug_hunt_dir) || exit 0

# The same TTL the gate reads pending records with — the variable diff-id.sh set
# when it was sourced, not a second default here. A fallback that can never fire
# reads as the live number and two reviewers in a row aimed a mutation at it. And
# the reason is the gate's: a
# review that ended `failed`, or a session that walked away, leaves a record
# behind, and a permanent record would nag forever with no way to satisfy it.
# Five ids is a reminder; a hundred would be a wall of text nobody reads. What
# is NOT optional is the count: truncating in silence, with the anti-loop guard
# then skipping the next scan, hid the sixth paid hunt in the only message that
# would have named it — and a session that ends on that turn never reads it
# (found in review of this hook). ONE constant for both halves: written twice,
# the cap and the threshold drift, and a message naming one id while claiming
# one more is hidden is worse than the truncation it replaced.
CAP=5
# `.tmp` is stamp-hunt.sh's write-ahead file, and its redirect stays open across
# several git subprocesses — a hook killed in there leaves the scratch name
# behind. Echoing it would name a review id no `get_findings` can resolve, so
# the record could never be cleared and the nag would repeat every turn until
# the TTL expired: a nag nobody can satisfy is how a control gets disarmed.
# Safe to skip by name because a real id cannot end this way: the server mints
# `rev_` + 12 uuid chars (8 hex, a dash, 3 hex) and the submit path names the
# record from that response, never from anything the model typed. Two reviewers
# read the filter as hiding legitimate hunts, so the invariant lives here now:
# if ids ever gain a dot, this line is the one to revisit.
PEND=$(cd "$DIR.pending" 2>/dev/null &&
  find . -maxdepth 1 -type f ! -name '*.tmp' \
    -mmin "-$OHMYBUG_PENDING_TTL_MIN" 2>/dev/null |
  sed 's|^\./||' | sort)
[ -n "$PEND" ] || exit 0

# MINE, or nobody's. stamp-hunt.sh writes a `session:<id>` line into the record
# it creates, so the record knows who made it — and that is the only place in
# the system that can know: the API key authenticates a machine, and /mcp on the
# server is stateless, so no column there could answer it (#444).
#
# THREE states, not two, and the third is why this is not a filter on equality.
# A record with NO session line is a record from a client that did not send one,
# or from before this field existed — unknown, not foreign — and dropping it
# would trade a nudge that woke the wrong session for a nudge that never comes,
# which is the worse of the two: the failure we measured was noise, and the
# failure we would build is silence about a hunt somebody paid for. The
# stability of the session id across compaction and `--resume` is not documented
# anywhere we could find, so a record whose session merely DIFFERS is treated as
# somebody else's only for the purpose of what to say about it — never as
# grounds to say nothing at all.
MINE='' FOREIGN=0
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  OWNER=$(sed -n 's/^session://p' "$DIR.pending/$rec" 2>/dev/null | head -n 1)
  if [ -z "$OWNER" ] || [ -z "$SESSION" ] || [ "$OWNER" = "$SESSION" ]; then
    MINE="$MINE$rec
"
  else
    FOREIGN=$((FOREIGN + 1))
  fi
done <<EOF
$PEND
EOF
# Somebody else's runs get a COUNT and no instruction: naming ids the session
# cannot promote is what taught agents to ignore this line, and there is nothing
# for it to do about them — the owning session's own get_findings promotes them.
if [ -z "$(printf '%s' "$MINE" | tr -d '[:space:]')" ]; then
  [ "$FOREIGN" -gt 0 ] &&
    echo "ohmybug: $FOREIGN unread hunt(s) in $DIR.pending belong to other sessions on this machine, not to you — nothing for you to do, and do not report them as yours." >&2
  exit 0
fi

MINE=$(printf '%s' "$MINE" | grep -v '^$')
TOTAL=$(printf '%s\n' "$MINE" | grep -c .)
IDS=$(printf '%s\n' "$MINE" | head -n "$CAP" | tr '\n' ' ')
IDS=${IDS% }
[ "$TOTAL" -gt "$CAP" ] && IDS="$IDS (and $((TOTAL - CAP)) more in $DIR.pending)"

# Say only what the payload lets us say. With a session id these ARE this
# session's submits; without one, ownership is unknown and claiming it would be
# the same fabricated-observation defect we keep finding in our own fields.
WHOSE="hunt(s) YOU submitted that nobody has read"
# Both spellings end in "read:", because the id list is what the suite asserts on
# verbatim and a headline change must not silently move that anchor.
[ -n "$SESSION" ] || WHOSE="unread hunt(s) here — this client sends no session id, so which of these are yours is unknown; nobody has read"
# Zero is not "no number": `${FOREIGN:+…}` fires on the STRING "0", so the count
# has to be tested as a number or the nudge announces "Also 0 unread hunt(s)".
ALSO=''
[ "$FOREIGN" -gt 0 ] && ALSO="Also $FOREIGN unread hunt(s) here belong to other sessions — not yours, nothing to do."

echo "ohmybug: $WHOSE: $IDS — do not end the turn waiting" \
     "to be prodded. Call get_findings on each now, unless you already know one is still" \
     "running: for those, arm a background poll on the status_url (Bash run_in_background," \
     "per the bughunter skill) so completion wakes you, rather than polling in a loop." \
     "$ALSO" \
     "This fires once per stop, and again after you do work — the counter is honest, the" \
     "old wording ('this fires once') was not." >&2
exit 2
