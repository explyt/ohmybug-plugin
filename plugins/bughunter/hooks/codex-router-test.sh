#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROUTER="$ROOT/hooks/codex-router.js"
CONFIG="$ROOT/hooks/claude-codex-hooks.json"
MANIFEST="$ROOT/.codex-plugin/plugin.json"
MCP="$ROOT/.codex-mcp.json"
MARKETPLACE="$ROOT/../../.agents/plugins/marketplace.json"

python3 - "$ROUTER" "$CONFIG" "$MANIFEST" "$MCP" "$MARKETPLACE" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

router, config, manifest, mcp, marketplace = sys.argv[1:]

def run(event, payload=None):
    proc = subprocess.run(
        ["node", router, event],
        input=None if payload is None else json.dumps(payload),
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(proc.stdout or "{}")

session = run("session")
assert session["hookSpecificOutput"]["hookEventName"] == "SessionStart"
session_text = session["hookSpecificOutput"]["additionalContext"]
for phrase in ("submit_review", "wait_review", "automation_update", "destination=thread", "four-minute heartbeat", "poll_after_s=30", "timeout_s=225", "every 45s for 225s", "answer needs_files first", "review_report", "get_attestation", "never run fast and deep in parallel"):
    assert phrase in session_text, phrase
assert "local code-review" in session_text
assert "set targetThreadId" not in session_text

skill = open(str(Path(router).parent.parent / "skills/bughunter/SKILL.md"), encoding="utf-8").read()
monitor_section = skill.split("start this compact, unbounded loop immediately with the", 1)[1]
monitor_code = monitor_section.split("```", 2)[1]
assert "while :" in monitor_code
assert monitor_code.count("sleep 45") == 2
assert "seq " not in monitor_code
# The heartbeat (#57): a line at least every 240 s even when nothing changed, and
# never one per 45 s poll – Monitor floods stop the watch.
# The whole assignment: "heartbeat=180" is a prefix of "heartbeat=1800".
assert "\nheartbeat=180 #" in monitor_code
assert "--max-time 15 " in monitor_code
assert "-ge \"$heartbeat\"" in monitor_code
assert "*) printf" not in monitor_code
# The heartbeat is a heartbeat only because the clock resets when it prints:
# drop `last=$now` and the loop prints every poll after the first 180 s, with
# every pin above still green. Both gated branches (running AND poll-failed)
# reset it.
assert monitor_code.count("last=$now") == 2, monitor_code.count("last=$now")
# The failure branch prints on the clock only (a first-failure-immediate rule
# floods under a flapping endpoint), resets the clock INSIDE its gate (moved
# out, every failed poll refreshes `last` and an outage prints once, then
# nothing) and clears `prev` so the first good poll prints the recovery.
assert ('''    if [ $((now - last)) -ge "$heartbeat" ]; then
      printf 'bughunt · %s · poll-failed\\n' "$mode"
      last=$now; prev=
    fi
    sleep 45
    continue
''') in monitor_code, "poll-failed branch lost its shape"
assert "failing" not in monitor_code
# The init line: an empty prev is what makes the first reading print at once.
assert "\nstart=$(date +%s); last=$start; prev= #" in monitor_code
# The watch retires (with a line) at 180 min or after 12 consecutive failed
# polls: a dead URL must not wake the session every heartbeat forever, and a
# cap SHORTER than the 150 min hunt budget would drop a live hunt.
assert ('''  if [ $((now - start)) -ge 10800 ] || [ "$fails" -ge 12 ]; then
    printf 'bughunt · %s · watch-retired\\n' "$mode"; break # past 180 min, or a dead URL
''') in monitor_code, "watch retirement lost its shape"
assert "    fails=$((fails + 1))\n" in monitor_code and "\n  fails=0\n" in monitor_code
# The running gate, verbatim, for the same reason: moving `last=$now` one line
# down (out of the gate) keeps count == 2 and silences the heartbeat for the
# whole hunt; `-lt` or a literal 45 in the gate floods it.
assert ('''  now=$(date +%s)
  if [ "$st" != "$prev" ] || [ $((now - last)) -ge "$heartbeat" ]; then
    printf 'bughunt · %s · running\\n' "$mode"
    last=$now; prev=$st
  fi
  sleep 45
done
''') in monitor_code, "running heartbeat gate lost its shape"
# needs-files must exit the loop, not print every 45 s.
assert ('''    printf 'bughunt · %s · needs-files\\n' "$mode"
    break
''') in monitor_code, "needs-files no longer breaks"
# Every printf inside the loop is either terminal (break follows) or gated.
loop = monitor_code.split("while :; do", 1)[1]
for line in loop.splitlines():
    if "printf 'bughunt" in line and "break" not in line:
        assert line.startswith("      printf") or line.startswith("    printf 'bughunt · %s · running") or line.startswith("    printf 'bughunt · %s · needs-files"), line
assert loop.count("printf 'bughunt · %s · running") == 1
assert loop.count("printf 'bughunt · %s · poll-failed") == 1
# Claude Code's Monitor tool runs the loop in the user's login shell – zsh on
# macOS – where `status` is a read-only alias of `$?`: `status=$(...)` aborts
# the script on its first poll ("read-only variable: status") and the watch
# dies before its first line. Run the loop under zsh with curl/sleep shimmed.
import os, re, shutil, tempfile
assert not re.search(r"(?m)^\s*status=", monitor_code), "status is read-only in zsh"
zsh = shutil.which("zsh")
if zsh:
    with tempfile.TemporaryDirectory() as d:
        open(f"{d}/curl", "w").write('#!/bin/sh\nprintf \'{"status":"done"}\'\n'); os.chmod(f"{d}/curl", 0o755)
        open(f"{d}/sleep", "w").write("#!/bin/sh\nexit 0\n"); os.chmod(f"{d}/sleep", 0o755)
        r = subprocess.run([zsh, "-c", monitor_code.replace("<status_url>", "http://x/")], capture_output=True, text=True, env={**os.environ, "PATH": f"{d}:{os.environ['PATH']}"})
    assert r.returncode == 0 and r.stdout == "bughunt · fast · done\n", (r.returncode, r.stdout, r.stderr)
claude_bullet = skill.split("- **Claude Code:**", 1)[1].split("\n\nIf the runtime cannot create its monitor", 1)[0]
for phrase in ("`Monitor` tool", "240 seconds", "180 s budget", "persistent: true", "up to 150 min", "CronCreate", "every 4 minutes", "`3-59/4 * * * *`", "KEEP this job", "3 consecutive poll failures", "older than\n  150 minutes", "One job per review", "older review id", "one line and nothing else", "TaskStop"):
    assert phrase in claude_bullet, phrase
assert "up to 2 h" not in claude_bullet
codex_bullet = skill.split("- **Codex:**", 1)[1].split("- **Claude Code:**", 1)[0]
for phrase in ("poll_after_s=30", "timeout_s=225", "`get_findings` every 45 seconds", "for at most\n  225 seconds", "needs_files", "15-second gap"):
    assert phrase in codex_bullet, phrase

review = run("prompt", {"prompt": "Please do a deep review of PR 3401 before merge"})
review_text = review["hookSpecificOutput"]["additionalContext"]
assert "Route this request now" in review_text
assert "local review agents" in review_text

assert run("prompt", {"prompt": "Fix the typo in the README"}) == {}
assert run("subagent")["hookSpecificOutput"]["hookEventName"] == "SubagentStart"

hooks = json.load(open(config, encoding="utf-8"))["hooks"]
assert all(event in hooks for event in ("SessionStart", "UserPromptSubmit", "SubagentStart"))
plugin = json.load(open(manifest, encoding="utf-8"))
assert plugin["skills"] == "./skills/"
assert plugin["mcpServers"] == "./.codex-mcp.json"
# Both files, by name: a manifest `hooks` entry REPLACES the default
# hooks/hooks.json, so naming only the router left Codex with no merge gate,
# no hunt recorder and no stop nudge. Order matters to nobody; presence does.
assert sorted(plugin["hooks"]) == sorted(["./hooks/hooks.json", "./hooks/claude-codex-hooks.json"]), plugin["hooks"]
codex_mcp = json.load(open(mcp, encoding="utf-8"))
assert codex_mcp == {"ohmybug": {"type": "http", "url": "https://mcp.ohmybug.ai/mcp"}}
market = json.load(open(marketplace, encoding="utf-8"))
entry = market["plugins"][0]
assert entry["source"]["path"] == "./plugins/bughunter"
assert entry["policy"] == {"installation": "AVAILABLE", "authentication": "ON_INSTALL"}
print("codex-router: ok")
PY
