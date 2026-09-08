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
# The hold cap is the server's, not ours: a longer timeout_s comes back at the
# same 45 s with timed_out:true, so the heartbeat loops short waits instead —
# and only for a fast hunt, since a deep one outlives any loop (#988).
for phrase in ("submit_review", "wait_review", "automation_update", "destination=thread", "four-minute heartbeat", "timeout_s=45 up to 3 times", "timed_out:true", "deep hunt call wait_review once", "every 45s for 180s", "answer needs_files first", "review_report", "get_attestation", "never run fast and deep in parallel"):
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
# Mandatory, not opportunistic: a skipped run here is the incident again with a
# green build in front of it. CI installs zsh for this step.
zsh = shutil.which("zsh")
assert zsh, "zsh is required: the loop must be executed under the shell Claude Code runs it in"
# monitor_code starts with the fence's info string ("bash"); executed, that
# line is a real bash reading the suite's stdin. Strip it, and give the loop
# no stdin at all. Every exit path is driven: `done`, `failed` (dropping the
# `failed` arm makes a failed review heartbeat `running` for 3 h) and
# `needs-files`.
loop_src = monitor_code.split("\n", 1)[1]
assert not loop_src.startswith("bash"), "fence info string leaked into the executed loop"
for body, want in (('{"status":"done"}', "done"), ('{"status":"failed"}', "failed"), ('{"status":"running","files_requested":true}', "needs-files")):
    with tempfile.TemporaryDirectory() as d:
        open(f"{d}/curl", "w").write("#!/bin/sh\nprintf '%s' '" + body + "'\n"); os.chmod(f"{d}/curl", 0o755)
        open(f"{d}/sleep", "w").write("#!/bin/sh\nexit 0\n"); os.chmod(f"{d}/sleep", 0o755)
        r = subprocess.run([zsh, "-c", loop_src.replace("<status_url>", "http://x/")], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, env={**os.environ, "PATH": f"{d}:{os.environ['PATH']}"})
    assert r.returncode == 0 and r.stdout == f"bughunt · fast · {want}\n", (want, r.returncode, r.stdout, r.stderr)
# The failed-poll path, executed: a dead endpoint. The curl shim honours `-f`
# (exit 22 on an HTTP error, else a 404 page with exit 0 – what dropping `-f`
# or piping curl's output would see) and `date` advances 60 s per call, so the
# clock-gated poll-failed lines land and the 12-failure retirement fires. A
# loop that treats the failure as "running" prints `running` and is red.
with tempfile.TemporaryDirectory() as d:
    open(f"{d}/curl", "w").write('#!/bin/sh\ncase " $* " in *" -f"*) exit 22 ;; esac\nprintf \'<html>404</html>\'\n'); os.chmod(f"{d}/curl", 0o755)
    open(f"{d}/sleep", "w").write("#!/bin/sh\nexit 0\n"); os.chmod(f"{d}/sleep", 0o755)
    open(f"{d}/date", "w").write(f'#!/bin/sh\nn=$(cat "{d}/clock" 2>/dev/null || echo 0); n=$((n + 60)); echo "$n" > "{d}/clock"; echo "$n"\n'); os.chmod(f"{d}/date", 0o755)
    r = subprocess.run([zsh, "-c", loop_src.replace("<status_url>", "http://x/")], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120, env={**os.environ, "PATH": f"{d}:{os.environ['PATH']}"})
lines = r.stdout.splitlines()
assert r.returncode == 0 and lines and lines[-1] == "bughunt · fast · watch-retired", (r.returncode, r.stdout, r.stderr)
assert "bughunt · fast · poll-failed" in lines and "bughunt · fast · running" not in lines, r.stdout
assert 1 <= lines.count("bughunt · fast · poll-failed") <= 6, lines  # 12 failed polls, one line per 180 s of shim clock
# The properties list is normative for any rewrite of the loop: property 4
# must describe the shipped loop (clock-gated poll-failed, retirement after 12
# failures), not the pre-retirement one that printed per failure and never ended.
props = skill.split("Any form you write must keep:", 1)[1].split("\n\nNo background tasks", 1)[0]
assert "- **A poll failure is seen, not swallowed.**" in props
assert "print `poll-failed` on the heartbeat clock" in props and "only 12 consecutive failures end the\n  watch" in props
assert "does not end the watch" not in props and "print the failure, and keep polling" not in props
assert "~9 min" not in skill and "13 min" not in skill, "12 failed polls take 9-12 min: 12 x (45 + 15) s"
claude_bullet = skill.split("- **Claude Code:**", 1)[1].split("\n\nIf the runtime cannot create its monitor", 1)[0]
for phrase in ("`Monitor` tool", "240 seconds", "180 s budget", "persistent: true", "up to 150 min", "CronCreate", "every 4 minutes", "`3-59/4 * * * *`", "KEEP this job", "after 3\n  consecutive poll failures", "older than 180 minutes", "print `bughunt · <mode> · watch-retired` and only then\n  `CronDelete`", "One job per review", "older review id", "one line and nothing else", "TaskStop"):
    assert phrase in claude_bullet, phrase
assert "up to 2 h" not in claude_bullet
codex_bullet = skill.split("- **Codex:**", 1)[1].split("- **Claude Code:**", 1)[0]
# #1003: a heartbeat printed `running` on three wakes after the hunt was done,
# with no tool call in the thread — the cadence fields say when to wake, and
# nothing said what a wake IS. The server ships that sentence as `wake_rule`;
# the bullet must carry it verbatim, or the prompt the agent writes into
# automation_update is free to omit it.
WAKE_RULE = ("every wake reports the status it just read — from `wait_review`\n  or `get_findings` on a fast hunt, from the `status_url` read on a deep one —\n  and a wake with no answer prints `bughunt · <mode> · poll-failed`, never the\n  previous status")
assert WAKE_RULE in codex_bullet, "the heartbeat prompt must carry the server's wake_rule word for word"
assert "`wake_rule` — copy `wake_rule` into the prompt word for word" in codex_bullet
# ...and the hand-wait path prints on the same terms: it is the path with no
# heartbeat, i.e. the one where nothing else would catch a remembered status.
assert "a status you\nprint is a status a tool just answered" in skill
for phrase in ("poll_after_s=30", "timeout_s=45)` in a\n  loop", "up to 3 times inside one wake", "`WAIT_REVIEW_MAX_S` (45 s)", "`timed_out: true`", "call `wait_review` once", "`get_findings` every 45 seconds", "for at most\n  180 seconds", "needs_files", "older than 180 minutes", "watch-retired`, then delete it"):

    assert phrase in codex_bullet, phrase
# The 225 s hold is gone from BOTH surfaces (the comment used to promise that
# while the assert read one): the server caps a hold at 45 s, so asking for more
# returns the same timed_out answer at 45 s and waits no longer.
# The reason must not survive as the pre-clamp one: a client told to expect a
# dead socket books ordinary timed_out answers as unreachable-server wakes and
# retires a healthy watch after three of them. And that consequence is the whole
# point of this change, so the rule that forbids it is asserted on both surfaces
# in its own words — the bare token `timed_out` also matches the clause above it,
# so deleting the rule used to ship green.
router_text = open(router, encoding="utf-8").read()
# The ROUTING text is the other Codex surface and restates the whole heartbeat
# contract on its own, so a rule stated only in the skill still ships an agent
# that arms a heartbeat allowed to answer from memory.
ROUTER_WAKE_RULE = ("wake_rule — copy wake_rule into the prompt word for word: every wake reports the status it just read "
                    "(from wait_review or get_findings on a fast hunt, from the status_url read on a deep one), "
                    "and a wake with no answer prints bughunt · <mode> · poll-failed, never the previous status")
assert ROUTER_WAKE_RULE in router_text, "ROUTING must carry the whole wake rule, not a fragment of it"
# ...and the retirement counter must count wakes that read nothing, whatever the
# wake reads: a deep wake reads status_url, so a counter keyed to wait_review
# alone can never fire there and only the 180-minute cap is left.
assert "3 consecutive wakes that could not read\n  a status at all" in codex_bullet, "the skill must retire on wakes that read nothing, not on failed wait_review calls"
assert "3 consecutive wakes that could not read a status at all" in router_text, "ROUTING must carry the same retirement counter"
# ...and the age cap beside it: a cap shorter than the deep budget drops a live
# hunt, and the counter alone lets a heartbeat nothing can satisfy run forever.
assert "Retire a heartbeat older than 180 minutes" in router_text, "ROUTING must carry the 180-minute age cap"
# The deep wake reads status_url, so the agent must be told to copy the URL into
# the heartbeat and to poll it once per wake — or the rule names a read it was
# never handed, on the longest hunt there is.
assert "status_url, interval_s, wake_on, stop_on, and wake_rule" in router_text
assert "each of its wakes polling status_url once and reporting that" in router_text
assert "`review_id`, `status_url`, `interval_s`" in codex_bullet
assert "each of its wakes polls `status_url` once and\n  reports that, which is the read `wake_rule` names for a deep hunt" in codex_bullet
assert "`status_url` read,\n  whichever that wake uses" in codex_bullet
assert "status_url read, whichever that wake uses" in router_text
for text in (skill, router_text):
    assert "timeout_s=225" not in text, "a 225 s hold is capped by the server to 45 s"
    assert "client MCP timeout" not in text and "client-side timeout" not in text, "the clamp answers; it does not kill the socket"
assert "never count it towards the retirement" in skill
assert "never a wake to count towards retirement" in router_text
# The stop-early rule, in its own words on each surface: every bare needs_files
# token in the tuples above is satisfied by a neighbouring sentence, so deleting
# this clause used to ship green — and a wake that keeps waiting through a
# needs_files answer burns a file request that is held open for minutes.
assert "stop the loop the moment the answer is `done`,\n  `failed` or `needs_files`" in skill
assert "stopping early on done, failed or needs_files" in router_text
# The wake budget must leave room for the round trips: holds alone filling the
# cadence is how two wakes end up looping over the same review.
# Both branches of the wake spend the same budget, or the one left behind
# overruns the cadence the other was cut to fit: an iteration is 45 s of waiting
# plus up to 15 s of round trip, three of them, 60 s left for the status line
# and the cleanup. A count or a budget that drifts on either surface is a wake
# still looping when the next heartbeat fires.
for text in (skill, router_text):
    assert "up to 3 times" in text, "an iteration costs 45 + 15 s: more than three overruns the 240 s wake"
    assert "225s" not in text and "225 seconds" not in text, "225 s of polling leaves no handover slack either"
assert "3 x 60 s\n  = 180 s" in skill and "3 x 60 s = 180 s" in router_text
assert "15-second gap" not in skill
# The no-monitor fallback is the one place with no heartbeat to hand the wait
# to, so it must loop for a DEEP hunt as well: one call there ends the turn on
# an hour-long review nobody reads.
fallback = skill.split("If the runtime cannot create its monitor,", 1)[1].split("\n\nIf the MCP server is missing", 1)[0]
for phrase in ("`done`, `failed` or `needs_files`", "held open for minutes only", "the loop is for a deep hunt TOO", "running and unwatched", "never claim that a monitor is armed"):
    assert phrase in fallback, phrase
assert "one call for a deep one" not in fallback

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
