#!/bin/bash
# Say the one thing a new install cannot discover by itself: in auto mode the
# permission classifier reviews every call these tools make, because sending
# code to a cloud service is exactly what it is built to watch. Measured on
# Claude Code 2.1.293: it let a hunt start (a payload submit and a repo+ref one
# alike), let small file answers through, and refused a large one outright
# ("too long for the classifier") — so without the rule the reviewers can lose
# the files they asked for mid-run, and the refusal is silent from the user's
# side. The rule that fixes it is not guessable.
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

# Codex loads these hooks too (manifest `hooks` lists hooks.json), and every
# sentence below is about Claude Code: its auto-mode classifier, its
# /permissions rule, its settings files, its tool namespace. Codex approves MCP
# tools in its own config and names them mcp__ohmybug__*, so the note would be
# wrong there — and, marked once per machine, would also silence the right one
# for a Claude Code session beside it. Codex is the client that sets PLUGIN_DATA
# (Claude Code sets only the CLAUDE_-prefixed names); nothing is written, so the
# other client still gets its turn.
[ -n "${PLUGIN_DATA:-}" ] && exit 0

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
OhMyBug: the hunt runs in our cloud, so its tools send code off this machine.
In auto mode the permission classifier reviews each of those calls: it may
refuse the files the reviewers ask for mid-run (a large file is refused
outright), and the hunt then goes on without them. One rule lets the OhMyBug
tools through, and only you can add it — /permissions -> Add rule ->
mcp__plugin_bughunter_ohmybug__* . Nothing will add it for you. With it, the
files go through the plugin, read from disk; no shell command uploads them.
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
