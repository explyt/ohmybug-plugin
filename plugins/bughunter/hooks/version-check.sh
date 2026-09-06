#!/bin/bash
# Best-effort update notice. It never blocks a review or treats the network as
# trusted input: a failed fetch, bad JSON, or malformed version stays silent.
set -euo pipefail

ROOT=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
MANIFEST=${OMB_VERSION_MANIFEST:-$ROOT/.codex-plugin/plugin.json}
STATE=${OMB_VERSION_STATE_DIR:-${OMB_STATE_DIR:-$HOME/.ohmybug}}
URL=${OMB_VERSION_URL:-https://raw.githubusercontent.com/explyt/ohmybug-plugin/main/plugins/bughunter/.codex-plugin/plugin.json}
CLIENT=${OMB_VERSION_CLIENT:-}

installed=$(python3 - "$MANIFEST" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1])).get('version', '')
except Exception:
    value = ''
print(value)
PY
) || exit 0
[ -n "$installed" ] || exit 0

latest=$(curl -fsSL --max-time 2 "$URL" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version", ""))' 2>/dev/null) || exit 0
[ -n "$latest" ] || exit 0

is_newer=$(python3 - "$installed" "$latest" <<'PY'
import re, sys

def ver(s):
    m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)', s)
    return tuple(map(int, m.groups())) if m else None
old, new = ver(sys.argv[1]), ver(sys.argv[2])
print('1' if old and new and new > old else '0')
PY
) || exit 0
[ "$is_newer" = 1 ] || exit 0

if [ -z "$CLIENT" ]; then
  [ -n "${PLUGIN_DATA:-}" ] && CLIENT=codex || CLIENT=claude
fi

mkdir -p "$STATE" 2>/dev/null || exit 0
MARK="$STATE/version-notice-v1-$CLIENT"
KEY="$CLIENT:$installed->$latest"
[ "$(cat "$MARK" 2>/dev/null || true)" != "$KEY" ] || exit 0
printf '%s' "$KEY" > "$MARK" 2>/dev/null || exit 0
if [ "$CLIENT" = codex ]; then
  NOTE="OhMyBug: bughunter $latest is available (you have $installed). Update Codex with: codex plugin marketplace upgrade ohmybug && codex plugin add bughunter@ohmybug. Then start a new Codex thread."
else
  NOTE="OhMyBug: bughunter $latest is available (you have $installed). Update Claude Code with: /plugin update bughunter. Then restart the session."
fi
python3 - "$NOTE" <<'PY'
import json, sys
note = sys.argv[1]
print(json.dumps({
    'systemMessage': note,
    'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': note},
}))
PY
