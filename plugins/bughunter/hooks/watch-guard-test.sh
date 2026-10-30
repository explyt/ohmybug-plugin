#!/bin/bash
# Run me after touching watch-guard.sh or the skill's watch loop:
# `hooks/watch-guard-test.sh`
set -u
G=$(cd "$(dirname "$0")" && pwd)
fails=0
hook() { # command, run_in_background (true|false) -> "<exit>"
  python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1],'run_in_background':sys.argv[2]=='true'}}))" "$1" "$2" \
    | sh "$G/watch-guard.sh" 2>"$ERR" >/dev/null
  echo $?
}
check() { # name, got, want
  [ "$2" = "$3" ] && echo "ok   $1" || { echo "FAIL $1: got $2, want $3"; fails=$((fails + 1)); }
}
ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT

# The shape that went cold in the field: an id in a variable, a loop that only
# prints at the end. Refused, and the refusal names the way out.
HAND='R=rev_example; echo "running 225" > ~/.ohmybug/watch/$R; while :; do sleep 225; s=$(curl -fsS https://mcp.ohmybug.ai/r/$R/status); case "$s" in *done*) echo done; exit 0;; esac; done'
check "hand-written background loop is refused" "$(hook "$HAND" true)" 2
grep -q "skill's watch loop" "$ERR" && grep -q "re-arm" "$ERR" && echo "ok   refusal names the skill loop and the re-arm" \
  || { echo "FAIL refusal text: $(cat "$ERR")"; fails=$((fails + 1)); }
check "literal id, until-loop, refused" "$(hook 'until curl -sf https://mcp.ohmybug.ai/r/rev_abc/status | grep -q done; do sleep 45; done' true)" 2

# The skill's own loop, read from the skill with its placeholders filled in as
# an agent would: the allowance must follow the loop the skill ships, not a
# copy of it here.
SKILL_LOOP=$(python3 - "$G/../skills/bughunter/SKILL.md" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
code = s.split("start this compact, unbounded loop immediately with the", 1)[1].split("```", 2)[1].split("\n", 1)[1]
for a, b in (("<status_url>", "https://mcp.ohmybug.ai/r/rev_abc/status"), ("<review_id>", "rev_abc"), ("<watch_poll_s>", "5"), ("<heartbeat_s>", "225")):
    code = code.replace(a, b)
print(code)
PY
)
[ -n "$SKILL_LOOP" ] || { echo "FAIL could not read the skill loop"; fails=$((fails + 1)); }
check "the skill's loop passes" "$(hook "$SKILL_LOOP" true)" 0

# A one-shot exits by itself and wakes the session on time: the server's own
# advice for Claude Code.
check "one-shot sleep && curl passes" "$(hook 'sleep 225 && curl -fsS https://mcp.ohmybug.ai/r/rev_abc/status' true)" 0
# Not in the background: the turn waits on it, nothing goes cold unseen.
check "foreground loop passes" "$(hook "$HAND" false)" 0
# Not our status URL.
check "a loop over another URL passes" "$(hook 'while :; do curl -fsS https://example.com/health; sleep 30; done' true)" 0
# Garbage in is never a refusal.
check "unparseable input passes" "$(printf 'not json' | sh "$G/watch-guard.sh" 2>/dev/null; echo $?)" 0

[ "$fails" -eq 0 ] && echo "watch-guard: ok" || { echo "watch-guard: $fails failing"; exit 1; }
