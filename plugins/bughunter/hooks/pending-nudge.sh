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
' 2>/dev/null) || exit 0

ACTIVE=$(printf '%s' "$FIELDS" | sed -n 1p)
CWD=$(printf '%s' "$FIELDS" | sed -n 2p)

[ "${ACTIVE:-1}" = '0' ] || exit 0
[ -n "${CWD:-}" ] && [ -d "$CWD" ] && cd "$CWD" 2>/dev/null

. "$(dirname "$0")/diff-id.sh" 2>/dev/null || exit 0
DIR=$(ohmybug_hunt_dir) || exit 0

# The same TTL the gate reads pending records with, for the same reason: a
# review that ended `failed`, or a session that walked away, leaves a record
# behind, and a permanent record would nag forever with no way to satisfy it.
# Five ids is a reminder; a hundred would be a wall of text nobody reads.
IDS=$(cd "$DIR.pending" 2>/dev/null &&
  find . -maxdepth 1 -type f -mmin "-${OHMYBUG_PENDING_TTL_MIN:-180}" 2>/dev/null |
  sed 's|^\./||' | sort | head -n 5 | tr '\n' ' ')
IDS=${IDS% }
[ -n "$IDS" ] || exit 0

echo "ohmybug: submitted hunt(s) nobody has read: $IDS — do not end the turn waiting" \
     "to be prodded. Call get_findings on each now. If one is still running, arm a" \
     "background poll on its status_url (Bash run_in_background, per the bughunter" \
     "skill) so its completion wakes you. If another session owns a review, say which" \
     "and stop again — this fires once." >&2
exit 2
