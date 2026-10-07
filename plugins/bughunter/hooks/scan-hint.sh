#!/bin/bash
# Say once, on the first session after install, that there is something to try
# before any pull request exists: a review of whatever code is at hand, and on a
# GitHub repository a one-off scan of what it changed recently. A new user who has no PR open has, until now, had nothing
# to run and nothing to see — and most of them never came back.
#
# It SUGGESTS and never starts anything: a scan hunts the user's code, so it
# begins on the user's word. Printed once per machine; the assistant hears the
# same sentence, so "what can this plugin do?" gets both as an answer.
set -euo pipefail

STATE=${OMB_STATE_DIR:-$HOME/.ohmybug}
MARK=$STATE/scan-hint-v1

# Codex: the skill carries the scan; `/bughunter:scan` is a Claude Code command.
[ -n "${PLUGIN_DATA:-}" ] && exit 0
[ -f "$MARK" ] && exit 0
mkdir -p "$STATE" && : > "$MARK"

NOTE='OhMyBug: no pull request needed to try it — /bughunter:review hunts whatever you have: a branch, uncommitted changes, recent commits, or a folder with no git at all. On a GitHub repository, /bughunter:scan hunts everything it changed in the last 30 days (a deep hunt of about an hour). Nothing starts until you run one.'
python3 - "$NOTE" <<'PY'
import json, sys
note = sys.argv[1]
print(json.dumps({
    "systemMessage": note,
    "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": note},
}))
PY
