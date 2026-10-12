#!/bin/sh
# PreToolUse(Bash): refuse a background loop that polls a hunt's status URL
# and prints nothing until the hunt ends.
#
# Claude Code wakes a session on a background command only when it EXITS. A
# hand-written `while :; do sleep 225; curl …/status; done` under
# run_in_background therefore wakes the session once, at the end of the hunt,
# and the prompt cache (5-minute TTL) goes cold for the whole wait. The skill's
# watch loop exits at every heartbeat line and is re-armed; a one-shot
# `sleep N && curl …` exits by itself. Both pass. Only a background command that
# loops over the status URL and is not the skill's loop is refused.
#
# ONE reason to exit 2. Everything else — no python3, unparseable input, a
# foreground command, any other URL — is allowed: this hook must never be the
# thing that stops an agent from working.

INPUT=$(cat)
command -v python3 >/dev/null 2>&1 || exit 0
HIT=$(printf '%s' "$INPUT" | python3 -I -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
i = d.get("tool_input") or {}
c = i.get("command") or ""
if not isinstance(c, str) or i.get("run_in_background") is not True:
    sys.exit(0)
# The status URL, however the id is spelled in it: literally, or as $R.
if not re.search(r"/r/[^\s\"'"'"']*/status", c) or "rev_" not in c:
    sys.exit(0)
if not re.search(r"\b(while|until|for)\b", c):
    sys.exit(0)
# The skill loop: it hands each run over in the .loop file and leaves `rearm`.
if "rearm" in c and ".loop" in c:
    sys.exit(0)
print("loop")
' 2>/dev/null) || exit 0
[ "$HIT" = loop ] || exit 0
echo "ohmybug: refused — this background command polls a hunt's status in a loop that prints nothing until the hunt ends. Claude Code wakes you only when a background command exits, so it would wake you once, at the end, and the prompt cache goes cold for the whole wait. Run the bughunter skill's watch loop instead (copy it from the skill; it exits at every heartbeat line, re-arm the same command each time), or a one-shot 'sleep <heartbeat_s> && curl -fsS <status_url>' re-armed on each wake." >&2
exit 2
