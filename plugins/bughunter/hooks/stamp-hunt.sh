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
import json, re, sys
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
# One field per line: a cwd may contain spaces, and a newline in a path is not
# something this hook needs to survive.
print(tool, done, d.get("cwd") or "", sep="\n")
' 2>/dev/null) || exit 0

TOOL=$(printf '%s' "$FIELDS" | sed -n 1p)
DONE=$(printf '%s' "$FIELDS" | sed -n 2p)
CWD=$(printf '%s' "$FIELDS" | sed -n 3p)

[ -n "${TOOL:-}" ] || exit 0
[ -n "${CWD:-}" ] && [ -d "$CWD" ] && cd "$CWD" 2>/dev/null

. "$(dirname "$0")/diff-id.sh" 2>/dev/null || exit 0
MARKER=$(ohmybug_marker_path) || exit 0
PENDING="$MARKER.pending"

case "$TOOL" in
  submit_review)
    ID=$(ohmybug_diff_id) || exit 0
    [ -n "$ID" ] || exit 0
    mkdir -p "$(dirname "$PENDING")" && printf '%s\n' "$ID" > "$PENDING"
    ;;
  get_findings|confirm_findings)
    # confirm_findings only exists after a done review, so it needs no status
    # check; get_findings is polled while the review is still running.
    [ "$TOOL" = 'confirm_findings' ] || [ "${DONE:-0}" = '1' ] || exit 0
    if [ -s "$PENDING" ]; then
      mkdir -p "$(dirname "$MARKER")" && cp "$PENDING" "$MARKER" && rm -f "$PENDING"
    else
      # No pending: the review was submitted from another session or another
      # directory. The working diff is the best available claim, and the gate
      # re-blocks the moment it changes.
      ID=$(ohmybug_diff_id) || exit 0
      [ -n "$ID" ] || exit 0
      mkdir -p "$(dirname "$MARKER")" && printf '%s\n' "$ID" > "$MARKER"
    fi
    ;;
esac
exit 0
