#!/bin/bash
# Say the one thing a new install cannot discover by itself: in auto mode the
# permission classifier refuses these tools, because sending a diff to a cloud
# service is exactly what it is built to stop. The refusal is correct. It is
# also silent from the user's side — the session simply stalls with "denied by
# the classifier", and the rule that fixes it is not guessable.
#
# Claude Code gives a plugin NO way to ship a permission rule or to ask for one
# at install time, and that is deliberate: a plugin that widens its own
# permissions is the shape of the attack the classifier exists to catch. So this
# prints the rule and stops. Adding it is the user's click, in their own
# settings, and nothing here writes to those files.
#
# Printed ONCE per machine, and only while no rule mentions our tools — a plugin
# that reminds you of something you already did is a plugin you turn off.
set -euo pipefail

STATE=${OMB_STATE_DIR:-$HOME/.ohmybug}
MARK=$STATE/permission-notice-v1

[ -f "$MARK" ] && exit 0

# Any mention at all counts as "the user has decided": allow, ask and deny are
# all decisions, and re-suggesting a rule against a deliberate deny would be
# nagging someone to undo their own choice.
mentions_us() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    grep -q 'bughunter_ohmybug' "$f" 2>/dev/null && return 0
  done
  return 1
}

if mentions_us "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" \
               "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json" \
               "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.local.json"; then
  mkdir -p "$STATE" && : > "$MARK"
  exit 0
fi

mkdir -p "$STATE" && : > "$MARK"

read -r -d '' NOTE <<'EOF' || true
OhMyBug: the hunt runs in our cloud, so its tools send a diff off this machine.
In auto mode the permission classifier refuses that by default and the session
stalls. If you want the hunt to run without being asked each time, add one rule
yourself — /permissions -> Add rule -> mcp__plugin_bughunter_ohmybug__*
(or just mcp__plugin_bughunter_ohmybug__submit_review). Nothing will add it for
you. Cheaper alternative, no rule needed: on a GitHub repo with the head pushed,
the hunt sends NO payload at all — the server fetches the diff itself.
EOF

# systemMessage is what the USER reads; additionalContext is what the assistant
# reads, so it can answer "why was that denied" without re-deriving it.
python3 - "$NOTE" <<'PY'
import json, sys
note = sys.argv[1]
print(json.dumps({
    "systemMessage": note,
    "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": note},
}))
PY
