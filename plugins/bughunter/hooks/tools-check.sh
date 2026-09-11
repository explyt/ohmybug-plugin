#!/bin/bash
# Ask the model to check, at the start of a session, that this plugin's MCP
# tools are actually present — and to say so at once if they are not.
#
# Why a hook has to say this: a session whose MCP handshake failed (a refused
# or timed-out connection at startup) has no tools and no way to get them —
# the client does not retry the handshake, and in-app sessions cannot
# reconnect a server. Left alone, the model discovers that at the merge gate,
# hours later, when it tries to hand in a hunt it can no longer run; every
# minute of work before that is work it cannot deliver. Told at the start, the
# remedy is a restart that costs a minute.
#
# additionalContext only, on a NEW process (hooks.json matcher `startup|resume`
# — a resumed session handshakes again; a cleared or compacted one does not), no state:
# this is an instruction to the assistant, not news for the user's screen — the
# user hears about it from the assistant exactly when it matters (the tools are
# missing), not on every start. Once, and the user decides: the tools can be
# absent for reasons a restart cannot change (the server disabled, no sign-in
# yet, offline), and a plugin that refuses the user's own work over that is the
# trap the merge gate promises not to be. Codex is routed by codex-router.js,
# which carries the same sentence in its own words (its tool names differ), so
# nothing is said here under Codex. And nothing is said when python3 is not
# there to say it: a hook that cannot speak stands down, it does not fail the
# session start with a stack of stderr.
set -euo pipefail

[ -n "${PLUGIN_DATA:-}" ] && exit 0

NOTE='First thing this session: confirm the OhMyBug MCP tools (mcp__plugin_bughunter_ohmybug__*) are present. If they are not, tell the user once, now — a session that began without them will not get them, and a restart (claude -c) usually does — then let the user decide and go on with what they asked; do not leave the discovery to the merge gate hours later.'

python3 - "$NOTE" <<'PY' || exit 0
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.argv[1]}}))
PY
