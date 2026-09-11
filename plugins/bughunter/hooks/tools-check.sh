#!/bin/bash
# Ask the model to check, at the very start of every session, that this
# plugin's MCP tools are actually present — and to say so at once if they are
# not.
#
# Why a hook has to say this: a session whose MCP handshake failed (a refused
# or timed-out connection at startup) has no tools and no way to get them —
# the client does not retry the handshake, and in-app sessions cannot
# reconnect a server. Left alone, the model discovers that at the merge gate,
# hours later, when it tries to hand in a hunt it can no longer run; every
# minute of work before that is work it cannot deliver. Told at the start, the
# remedy is a restart that costs a minute.
#
# additionalContext only, every session, no state: this is an instruction to
# the assistant, not news for the user's screen — the user hears about it from
# the assistant exactly when it matters (the tools are missing), not on every
# start. Codex is routed by codex-router.js, which carries the same sentence in
# its own words (its tool names differ), so nothing is said here under Codex.
set -euo pipefail

[ -n "${PLUGIN_DATA:-}" ] && exit 0

NOTE='First thing this session, before any work on a task: confirm the OhMyBug MCP tools (mcp__plugin_bughunter_ohmybug__*) are present. If they are not, tell the user now and ask them to restart the session (claude -c) — do not start the task and do not leave the discovery to the merge gate hours later: a session that began without them never gets them.'

python3 - "$NOTE" <<'PY'
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.argv[1]}}))
PY
