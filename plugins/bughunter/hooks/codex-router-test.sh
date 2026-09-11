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
# One cadence (#67): the automation fires once per interval_s and a wake is ONE
# read. The hold cap is the server's — a longer timeout_s comes back with
# timed_out:true — and that answer is the wake's reading, not a reason to loop:
# a wake that loops holds the thread when the next one fires, measured as a
# client polling once a minute against a four-minute contract.
for phrase in ("submit_review", "wait_review", "automation_update", "destination=thread", "four-minute heartbeat", "The automation is the cadence and a wake is one read", "make ONE read and end", "timed_out:true", "never loop either call inside the wake", "stop on done, failed or needs_files", "answer needs_files first", "review_report", "get_attestation", "never run fast and deep in parallel"):
    assert phrase in session_text, phrase
assert "local code-review" in session_text
# The proof and its hand-off are two steps, and a Codex session has no hook
# that writes the local record: a clean hunt met a gate that said "not
# hunted", and the agent asked for a plugin update that would have changed
# nothing. The routing text names the step, next to the proof it hands over.
for phrase in ("get_attestation is the proof", "./scripts/ticket.sh attest <review_id> hands it to the gate", "Codex has no hook that records a hunt locally"):
    assert phrase in session_text, phrase
assert "set targetThreadId" not in session_text

skill = open(str(Path(router).parent.parent / "skills/bughunter/SKILL.md"), encoding="utf-8").read()
monitor_section = skill.split("start this compact, unbounded loop immediately with the", 1)[1]
monitor_code = monitor_section.split("```", 2)[1]
assert "while :" in monitor_code
# One cadence (#67): no literal sleep. The poll gap is the body's
# next_poll_after_s (the server answers the watcher cadence for a payload
# submit and interval_s for a repo or deep one), the line gap its heartbeat_s;
# the submit response's next_poll_after_s seeds the first sleep (its
# monitor.interval_s on an older server that has none). A literal here
# is the loop that polled once a minute against a four-minute contract.
import re
assert monitor_code.count('sleep "$every"') == 2 and not re.search(r"sleep\s+\d", monitor_code)
assert "seq " not in monitor_code
# Seeded from the submit response's own watcher cadence (#1029 f2): the seed
# used to be interval_s, so a first poll that failed slept 240 s on a payload
# row whose watcher is 45 s. And the body's number takes over only when it is
# a positive one (#1029 f3): `every` is the loop's only throttle — and the
# same clamp on `beat`, whose zero would make the print gate true on every poll.
assert "\nevery=<next_poll_after_s> #" in monitor_code and "\nbeat=<heartbeat_s> " in monitor_code
assert 'n=$(num next_poll_after_s); [ -n "$n" ] && [ "$n" -gt 0 ] && every=$n' in monitor_code
assert 'n=$(num heartbeat_s); [ -n "$n" ] && [ "$n" -gt 0 ] && beat=$n' in monitor_code
assert not re.search(r"\b(45|90|100|180|225|240)\b", re.sub(r"#.*", "", monitor_code).replace("10800", "")), "a cadence literal in the loop"
assert "--max-time 15 " in monitor_code
assert "-ge \"$beat\"" in monitor_code
assert "*) printf" not in monitor_code
# The heartbeat is a heartbeat only because the clock resets when it prints:
# drop `last=$now` and the loop prints every poll after the first beat, with
# every pin above still green. Both gated branches (running AND poll-failed)
# reset it.
assert monitor_code.count("last=$now") == 2, monitor_code.count("last=$now")
# The failure branch prints on the clock only (a first-failure-immediate rule
# floods under a flapping endpoint), resets the clock INSIDE its gate (moved
# out, every failed poll refreshes `last` and an outage prints once, then
# nothing) and clears `prev` so the first good poll prints the recovery. It
# writes the watch file FIRST: the endpoint failed, the watcher did not, and a
# Stop hook reading a stale file here called a live watcher dead two polls into
# a blip and ordered a second one over it (found in review).
assert ('''    fails=$((fails + 1))
    printf 'poll-failed %s\\n' "$every" > "$watch" # still alive: the endpoint failed, not the watcher
    now=$(date +%s)
    if [ $((now - last)) -ge "$beat" ]; then
      printf 'bughunt · %s · poll-failed\\n' "$mode"
      last=$now; prev=
    fi
    sleep "$every"
    continue
''') in monitor_code, "poll-failed branch lost its shape"
# A 200 with no status word is a failed poll, not a running review: read as
# success it wrote a blank word into the watch file and the hook read the
# cadence as the status — armed — while the loop could never see `done`, so a
# finished review sat unread for the whole age cap (found in review). The status
# is extracted BEFORE the branch so the emptiness test can sit beside the rc test.
assert '''  s=$(curl -fsS --max-time 15 "$url"); rc=$?
  st=$(printf '%s' "$s" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\\([^"\\]*\\)".*/\\1/p' | head -n 1)
  if [ "$rc" -ne 0 ] || [ -z "$st" ]; then''' in monitor_code, "an unparseable 200 is not a failed poll"
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
# The watch file exists from the instant the watch starts: the first write used
# to be after the first curl returned, and a Stop inside that round trip (or
# right after a needs-files re-arm, while the file still held the exit word) had
# the hook call a just-armed Monitor dead and order a second one (found in
# review). Pinned as the line above the loop, and executed below: the curl shim
# records whether the file was already there when the first poll ran.
assert "\nprintf 'armed %s\\n' \"$every\" > \"$watch\" #" in monitor_code
assert monitor_code.index("printf 'armed %s") < monitor_code.index("while :; do")
# The running gate, verbatim, for the same reason: moving `last=$now` one line
# down (out of the gate) keeps count == 2 and silences the heartbeat for the
# whole hunt; `-lt` or a literal in the gate floods it.
assert ('''  now=$(date +%s)
  if [ "$st" != "$prev" ] || [ $((now - last)) -ge "$beat" ]; then
    printf 'bughunt · %s · running\\n' "$mode"
    last=$now; prev=$st
  fi
  sleep "$every"
done
''') in monitor_code, "running heartbeat gate lost its shape"
# needs-files must exit the loop, not print every poll — and it is written to
# the watch file BEFORE the break, so the Stop hook reads the state the loop
# exited on, not the last `running`.
assert '''  printf '%s %s\\n' "$st" "$every" > "$watch" # the Stop hook reads this: fresh + running = armed
  case "$st" in
    done|failed|needs-files) printf 'bughunt · %s · %s\\n' "$mode" "$st"; break ;;
  esac
''' in monitor_code, "terminal branch lost its shape"
assert '&& st=needs-files\n' in monitor_code
# Every printf inside the loop is either terminal (break follows) or gated.
loop = monitor_code.split("while :; do", 1)[1]
for line in loop.splitlines():
    if "printf 'bughunt" in line and "break" not in line:
        assert line.startswith("      printf") or line.startswith("    printf 'bughunt · %s · running"), line
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
# The four placeholders the agent substitutes, and only those: a fifth is a
# number the agent types, and the numbers are the server's.
assert set(re.findall(r"<[a-z_]+>", loop_src)) == {"<status_url>", "<review_id>", "<next_poll_after_s>", "<heartbeat_s>"}, set(re.findall(r"<[a-z_]+>", loop_src))
# ...and the sentence under the fence that tells the agent what to substitute
# names the same four (#1029 f1 of PR 74): it still said three, with
# `<interval_s>`, so a literal follower left `every=<next_poll_after_s>` in place
# and the loop died on a parse error, the hunt unwatched.
assert "Substitute the four placeholders from the submit response — `<status_url>`,\n`<review_id>`, `<next_poll_after_s>` (its `monitor.interval_s` on an older\nserver that has none) and `<heartbeat_s>` from its `monitor` — and nothing else" in skill
assert "the submit response's `next_poll_after_s` seeds the\n  first sleep" in skill and "`monitor.interval_s` seeds the\n  first sleep" not in skill
def armed(src): return src.replace("<status_url>", "http://x/").replace("<review_id>", "rev_test").replace("<next_poll_after_s>", "240").replace("<heartbeat_s>", "225")
def shims(d, curl_body):
    # The shim notes whether the watch file already existed when it was called:
    # the file must be there before the first poll, not one poll later.
    open(f"{d}/curl", "w").write(f"#!/bin/sh\n[ -f \"$HOME/.ohmybug/watch/rev_test\" ] && echo yes >> \"{d}/seen\"\nprintf '%s' '" + curl_body + "'\n"); os.chmod(f"{d}/curl", 0o755)
    # The sleep shim records what it was asked for: that number IS the cadence.
    open(f"{d}/sleep", "w").write(f'#!/bin/sh\necho "$1" >> "{d}/slept"\nexit 0\n'); os.chmod(f"{d}/sleep", 0o755)
    return {**os.environ, "PATH": f"{d}:{os.environ['PATH']}", "HOME": d}
for body, want in (('{"status":"done"}', "done"), ('{"status":"failed"}', "failed"), ('{"status":"running","files_requested":true}', "needs-files")):
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run([zsh, "-c", armed(loop_src)], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, env=shims(d, body))
        # The Stop hook's file: the state the loop exited on, so a terminal or
        # needs-files word there is what tells the hook to speak again.
        assert open(f"{d}/.ohmybug/watch/rev_test").read() == f"{want} 240\n", open(f"{d}/.ohmybug/watch/rev_test").read()
        assert open(f"{d}/seen").read() == "yes\n", "the watch file must exist before the first poll runs"
    assert r.returncode == 0 and r.stdout == f"bughunt · fast · {want}\n", (want, r.returncode, r.stdout, r.stderr)
# The cadence comes off the body (#67): a payload submit's body says
# next_poll_after_s 45 and heartbeat_s 225, and the loop sleeps 45 — not the
# 240 it was seeded with — and writes that cadence into the watch file, so the
# hook's freshness bound follows the same number. `date` advances 60 s per call
# and the loop reads it twice per iteration, so a poll costs 120 s of shim clock:
# the first reading prints at once (empty prev), then one `running` per 225 s of
# clock, never per poll — five polls of running, three lines (polls 1, 3, 5).
with tempfile.TemporaryDirectory() as d:
    env = shims(d, '')
    open(f"{d}/curl", "w").write(f'#!/bin/sh\nn=$(cat "{d}/polls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "{d}/polls"\n'
        'if [ "$n" -le 5 ]; then printf \'%s\' \'{"status":"running","monitor":{"interval_s":240,"heartbeat_s":225},"next_poll_after_s":45,"files_requested":false}\'; else printf \'%s\' \'{"status":"done","monitor":{"interval_s":240,"heartbeat_s":225},"next_poll_after_s":240}\'; fi\n'); os.chmod(f"{d}/curl", 0o755)
    open(f"{d}/date", "w").write(f'#!/bin/sh\nn=$(cat "{d}/clock" 2>/dev/null || echo 0); n=$((n + 60)); echo "$n" > "{d}/clock"; echo "$n"\n'); os.chmod(f"{d}/date", 0o755)
    r = subprocess.run([zsh, "-c", armed(loop_src)], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, env=env)
    slept = open(f"{d}/slept").read().split()
    watch = open(f"{d}/.ohmybug/watch/rev_test").read()
assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
assert slept == ["45"] * 5, slept
assert watch == "done 240\n", watch
assert r.stdout.splitlines() == ["bughunt · fast · running"] * 3 + ["bughunt · fast · done"], r.stdout
# A body whose heartbeat_s is 0 must not become the line clock either: the
# print gate is `now - last >= beat`, so a zero there prints `running` on every
# poll — the flood property 3 forbids. Same shim clock as above (120 s per
# poll), five running polls: the seeded 225 s clock prints on polls 1, 3, 5 —
# three lines, not five.
with tempfile.TemporaryDirectory() as d:
    env = shims(d, '')
    open(f"{d}/curl", "w").write(f'#!/bin/sh\nn=$(cat "{d}/polls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "{d}/polls"\n'
        'if [ "$n" -le 5 ]; then printf \'%s\' \'{"status":"running","monitor":{"interval_s":240,"heartbeat_s":0},"next_poll_after_s":45}\'; else printf \'%s\' \'{"status":"done","next_poll_after_s":240}\'; fi\n'); os.chmod(f"{d}/curl", 0o755)
    open(f"{d}/date", "w").write(f'#!/bin/sh\nn=$(cat "{d}/clock" 2>/dev/null || echo 0); n=$((n + 60)); echo "$n" > "{d}/clock"; echo "$n"\n'); os.chmod(f"{d}/date", 0o755)
    r = subprocess.run([zsh, "-c", armed(loop_src)], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, env=env)
assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
assert r.stdout.splitlines() == ["bughunt · fast · running"] * 3 + ["bughunt · fast · done"], r.stdout
# A body whose next_poll_after_s is 0 must not become the cadence (#1029 f3):
# `every` is the only throttle, and a zero there is a flood against the status
# door. The seed stays — 240 here — and the watch file says so.
with tempfile.TemporaryDirectory() as d:
    env = shims(d, '')
    open(f"{d}/curl", "w").write(f'#!/bin/sh\nn=$(cat "{d}/polls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "{d}/polls"\n'
        'if [ "$n" -le 2 ]; then printf \'%s\' \'{"status":"running","monitor":{"interval_s":240,"heartbeat_s":225},"next_poll_after_s":0}\'; else printf \'%s\' \'{"status":"done","next_poll_after_s":0}\'; fi\n'); os.chmod(f"{d}/curl", 0o755)
    r = subprocess.run([zsh, "-c", armed(loop_src)], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, env=env)
    slept = open(f"{d}/slept").read().split()
    watch = open(f"{d}/.ohmybug/watch/rev_test").read()
assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
assert slept == ["240"] * 2, slept
assert watch == "done 240\n", watch
# The failed-poll path, executed: a dead endpoint. The curl shim honours `-f`
# (exit 22 on an HTTP error, else a 404 page with exit 0 – what dropping `-f`
# or piping curl's output would see) and `date` advances 60 s per call, so the
# clock-gated poll-failed lines land and the 12-failure retirement fires. A
# loop that treats the failure as "running" prints `running` and is red. No body
# ever arrived, so the loop sleeps the seeded next_poll_after_s — and still writes the
# watch file, `poll-failed 240`: the watcher is alive, the endpoint is not, and a
# Stop hook that read the missing file as a dead watcher ordered a second monitor
# over a live one for the length of a blip (found in review).
with tempfile.TemporaryDirectory() as d:
    env = shims(d, '')
    open(f"{d}/curl", "w").write('#!/bin/sh\ncase " $* " in *" -f"*) exit 22 ;; esac\nprintf \'<html>404</html>\'\n'); os.chmod(f"{d}/curl", 0o755)
    open(f"{d}/date", "w").write(f'#!/bin/sh\nn=$(cat "{d}/clock" 2>/dev/null || echo 0); n=$((n + 60)); echo "$n" > "{d}/clock"; echo "$n"\n'); os.chmod(f"{d}/date", 0o755)
    r = subprocess.run([zsh, "-c", armed(loop_src)], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120, env=env)
    slept = set(open(f"{d}/slept").read().split())
    assert open(f"{d}/.ohmybug/watch/rev_test").read() == "poll-failed 240\n", open(f"{d}/.ohmybug/watch/rev_test").read()
assert slept == {"240"}, slept
lines = r.stdout.splitlines()
assert r.returncode == 0 and lines and lines[-1] == "bughunt · fast · watch-retired", (r.returncode, r.stdout, r.stderr)
assert "bughunt · fast · poll-failed" in lines and "bughunt · fast · running" not in lines, r.stdout
assert 1 <= lines.count("bughunt · fast · poll-failed") <= 6, lines  # 12 failed polls, one line per 240 s of shim clock
# The same run against an endpoint that answers 200 with something that is not
# the review (a redirect page, a proxy's HTML): no status word, so a failed poll
# — `poll-failed` in the file, never `running` on stdout, retired on the twelfth.
# A loop that takes the success path here writes a blank status word the Stop
# hook reads as armed, and prints `running` on a body it could not read.
with tempfile.TemporaryDirectory() as d:
    env = shims(d, '<html><body>Moved</body></html>')
    open(f"{d}/date", "w").write(f'#!/bin/sh\nn=$(cat "{d}/clock" 2>/dev/null || echo 0); n=$((n + 60)); echo "$n" > "{d}/clock"; echo "$n"\n'); os.chmod(f"{d}/date", 0o755)
    r = subprocess.run([zsh, "-c", armed(loop_src)], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120, env=env)
    assert open(f"{d}/.ohmybug/watch/rev_test").read() == "poll-failed 240\n", open(f"{d}/.ohmybug/watch/rev_test").read()
lines = r.stdout.splitlines()
assert r.returncode == 0 and lines and lines[-1] == "bughunt · fast · watch-retired", (r.returncode, r.stdout, r.stderr)
assert "bughunt · fast · running" not in lines and "bughunt · fast · poll-failed" in lines, r.stdout
# The properties list is normative for any rewrite of the loop: property 4
# must describe the shipped loop (clock-gated poll-failed, retirement after 12
# failures), not the pre-retirement one that printed per failure and never ended.
props = skill.split("Any form you write must keep:", 1)[1].split("\n\nNo background tasks", 1)[0]
assert "- **A poll failure is seen, not swallowed.**" in props
assert "print `poll-failed` on the heartbeat clock" in props and "only 12 consecutive failures end the\n  watch" in props
assert "does not end the watch" not in props and "print the failure, and keep polling" not in props
# Property 5 (#67): the watch file is what makes the Stop hook stand down.
assert "- **Writes `~/.ohmybug/watch/<review_id>` before the first poll and on every\n  poll after it, failed ones too**" in props
assert "`next_poll_after_s` is the sleep, `monitor.heartbeat_s` the line\n  clock" in props
# Property 3's clock is a reading once per poll, so its real gap is the
# heartbeat rounded up to whole poll cadences, and the whole thing must stay
# under the prompt-cache TTL: a rewrite to "at least every heartbeat_s" is the
# promise no once-per-poll loop can keep.
assert "rounded up to\n  whole poll cadences" in props and "must stay under the\n  prompt-cache TTL" in props
assert "~9 min" not in skill and "13 min" not in skill and "9–12 min" not in skill, "the failure window is 12 poll cadences, and the cadence is the server's"
claude_bullet = skill.split("- **Claude Code:**", 1)[1].split("\n\nIf the runtime cannot create its monitor", 1)[0]
for phrase in ("`Monitor` tool", "`next_poll_after_s`", "on the `monitor.heartbeat_s` clock", "Every number in the loop\n  comes from the server", "persistent: true", "up to 150 min", "CronCreate", "`3-59/4 * * * *`", "KEEP this job", "after `<fail_cap>` consecutive poll failures (3 for a job at\n  `interval_s`, 12 for one every minute", "older than 180 minutes", "print `bughunt · <mode> · watch-retired` and only then\n  `CronDelete`", "One job per review", "older review id", "one line and nothing else", "TaskStop", "`~/.ohmybug/watch/<review_id>`", "do\n  not add a foreground `get_findings` beside an armed monitor"):
    assert phrase in claude_bullet, phrase
assert "up to 2 h" not in claude_bullet
# No cadence literal in the bullet either (#67): the 240 in the cron example is
# a derivation from interval_s, stated as one; the rest are the server's.
for literal in ("every 45 seconds", "every 240 seconds", "180 s budget", "every 4 minutes"):
    assert literal not in claude_bullet, literal
# The deep bullet must not tell the agent nothing will prod it mid-run: the deep
# wake is exactly what catches a file request now.
assert "rarely needs files from you, so little prods you mid-run — the heartbeat's\n  `status_url` poll is what catches a request when it does" in skill
# The fourth statement of the same rule lives after the watch loop, outside the
# claude_bullet slice — the surface that owns the loop must re-arm on the same
# predicate as the three that do not.
assert "call `get_findings` once; if the review is still running or\nwaiting for files, tell the user, and arm a fresh monitor unless the watch\nretired on age" in skill
# The bullet is what an agent condenses when it rewrites the loop, so its exit
# condition must be the one the loop actually breaks on: the flags, not a status
# word that body never carries. And the cron job, the surface with no Monitor
# behind it, retires with the same remedy as the other two: read once, re-arm.
assert "exits on `done` / `failed` or on the\n  `awaiting_client_files`/`files_requested` flags" in claude_bullet
assert "never in its status word" in claude_bullet
assert "call `get_findings` once and create a fresh job if the\n  review is still running" in claude_bullet
assert "fourteen minutes" not in skill
# The cron prompt is the whole instruction its wake sees, so it carries the wake
# rule itself: without it, failures one and two have no line but the remembered
# one, which is the incident.
assert "call `get_findings`\n  once and print what that answered, and only if THAT fails too print `bughunt ·\n  <mode> · poll-failed` and count the wake as a poll failure — never the\n  previous status" in claude_bullet
# Either shape means a file request: the status body flags it beside the word,
# get_findings puts it IN the word — and the wake that falls back to the tool
# is exactly the one that would otherwise match neither branch.
assert "or `needs_files`\n  from the `get_findings` fallback (which flags it exactly there) call\n  `get_findings`, serve the files and KEEP this job" in claude_bullet
assert "review is still running or waiting for files AND the retirement came from poll\n  failures, not from the age cap" in claude_bullet
# The cron fallback curls the same status body as the deep wake, so it reads the
# request off the flags too: keyed to the status word it sits through the window.
assert "on `awaiting_client_files`/`files_requested` in the status\n  body (which flags a request there, not in its status word)" in claude_bullet
codex_bullet = skill.split("- **Codex:**", 1)[1].split("- **Claude Code:**", 1)[0]
# #1003: a heartbeat printed `running` on three wakes after the hunt was done,
# with no tool call in the thread — the cadence fields say when to wake, and
# nothing said what a wake IS. The server ships that sentence as `wake_rule`;
# the bullet must carry it verbatim, or the prompt the agent writes into
# automation_update is free to omit it.
WAKE_RULE = ("every wake reports the status it just read — from `wait_review`\n  or `get_findings` on a fast hunt, from the `status_url` read on a deep one —\n  and a wake with no answer prints `bughunt · <mode> · poll-failed`, never the\n  previous status")
assert WAKE_RULE in codex_bullet, "the heartbeat prompt must carry the server's wake_rule word for word"
# The war story that justifies the rule carries the magnitude the record supports:
# three wakes at the four-minute cadence is twelve minutes, not more.
assert "on three wakes — twelve minutes — after" in codex_bullet
assert "copy `wake_rule` into the prompt word for word" in codex_bullet
# ...and the hand-wait path prints on the same terms: it is the path with no
# heartbeat, i.e. the one where nothing else would catch a remembered status.
assert "a status you\nprint is a status a tool just answered" in skill
# One read per wake (#67), on this surface too: the loop of short holds that
# filled the cadence is what made a client poll once a minute.
for phrase in ("**The automation is the cadence; a wake is one read.**", "makes ONE read and\n  ends", "one `wait_review(review_id)` with its\n  default hold", "`timed_out: true`\n  answer IS this wake's reading: `running`", "Do not loop either call inside the\n  wake", "needs_files", "older than 180 minutes", "watch-retired`, then delete it"):
    assert phrase in codex_bullet, phrase
for literal in ("up to 3 times", "3 x 60 s", "180 + 60", "poll_after_s=30", "timeout_s=45", "every 45 seconds", "for at most\n  180 seconds", "loop instead", "Loop instead"):
    assert literal not in codex_bullet, literal
# ...with the one carve-out the other two surfaces keep (found in review): a
# payload submit is the one path where the server cannot serve the reviewers'
# file requests itself, the request is held open for minutes, and one read per
# interval_s misses it — there the wake's back-to-back wait_review IS the
# watcher, bounded so it ends before the next wake fires.
# The bound is the iteration's cost against heartbeat_s, not one hold against
# interval_s: a hold costs the server's cap plus a round trip, and subtracting
# the hold alone let a fourth one start at 180 s and return at 240 s — as the
# next wake fired, with nothing left for the line or the file answer (found in
# review). heartbeat_s is the contract's own "the line must land by then", so
# the handover before interval_s is derived, not typed.
# ...and the handover is priced in round trips, not left to the
# heartbeat_s–interval_s gap: at a 10 s round trip that gap-derived handover
# was 20 s for calls that are themselves round trips (found in review).
for phrase in ("a PAYLOAD submit\n  (§2, rung 3) while a file request can still arrive", "call `wait_review` back to back", "start another hold only if\n  it, its round trip, and one more round trip for the handover's own calls\n  would end inside `heartbeat_s` from this wake's start", "a bound that subtracts the hold alone lets the last one return\n  exactly as the next wake fires", "shrinks it on exactly the slow links whose\n  calls need it", "A repo or deep submit never needs this"):
    assert phrase in codex_bullet, phrase
assert "less one hold" not in skill and "less one hold" not in session_text
assert "it and its round trip would end inside" not in skill and "it and its round trip would end inside" not in session_text
for phrase in ("the one exception is a payload submit", "inside that wake call wait_review back to back", "start another hold only if it, its round trip, and one more round trip for the handover's own calls would end inside heartbeat_s from this wake's start", "a bound that subtracts the hold alone lets the last one return as the next wake fires", "shrinks it on the slow links that need it", "a repo or deep submit never needs this"):
    assert phrase in session_text, phrase
# The Monitor surface reads on a failed poll like the other two (found in
# review): a fresh poll-failed file keeps the Stop hook quiet for twelve polls,
# so without this read a review sat done and unread behind that silence.
assert "on `poll-failed` → one\n  `get_findings`, print what it answered" in claude_bullet
after_loop = skill.split("Every printed line wakes you.", 1)[1].split("The loop above keeps", 1)[0]
assert "**A `poll-failed`\nwake is a wake with no answer, and the wake rule applies: call `get_findings`\nonce" in after_loop
assert "this surface must not be the one that only prints" in after_loop
# The cron fallback follows the body's cadence too (found in review): a payload
# submit's next_poll_after_s is under a minute and its file request is held open
# for minutes, so the job runs every minute there and at interval_s otherwise.
for phrase in ("the submit response names — `next_poll_after_s`", "an older server's submit\n  answer carries only `interval_s`: then curl `status_url` ONCE before creating\n  the job", "Under a minute", "every minute, the tightest cron\n  allows (`* * * * *`)", "otherwise `interval_s`", "one\n  job at one cadence for the whole hunt", "3 consecutive failures at `interval_s`, 12 at every minute"):
    assert phrase in claude_bullet, phrase
# The placeholders the cron prompt carries: the fail cap is one of them now, so
# a job created every minute is not retired by a three-minute blip.
assert "after `<fail_cap>` consecutive poll failures" in claude_bullet
assert "after 3\n  consecutive poll failures" not in claude_bullet
# No literal hold or cadence on either surface: the server caps the hold and
# names the cadence, and a number written here is the one an agent obeys when
# the two disagree (measured: the tool's 45 beat the field's 240).
for text in (skill, session_text):
    assert "timeout_s=45" not in text and "up to 3 times" not in text and "3 x 60" not in text, "the wake loop is back"
# The reason must not survive as the pre-clamp one: a client told to expect a
# dead socket books ordinary timed_out answers as unreachable-server wakes and
# retires a healthy watch after three of them. And that consequence is the whole
# point of this change, so the rule that forbids it is asserted on both surfaces
# in its own words — the bare token `timed_out` also matches the clause above it,
# so deleting the rule used to ship green.
# The routing rules are asserted against the context the router EMITS, not its
# source: a clause parked in the file but dropped from the emitted array would
# otherwise ship green, and every Codex session would be routed without it.
router_text = session_text
# The ROUTING text is the other Codex surface and restates the whole heartbeat
# contract on its own, so a rule stated only in the skill still ships an agent
# that arms a heartbeat allowed to answer from memory.
ROUTER_WAKE_RULE = ("copy wake_rule into the prompt word for word: every wake reports the status it just read "
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
# Said at the start of every session: a session that began without the tools
# never gets them, and the merge gate is too late to learn it.
assert "confirm the ohmybug MCP tools are present" in router_text, "ROUTING must ask for the tools-present check at session start"
assert "tell the user once" in router_text and "go on with what they asked" in router_text, "the tools check is one notice and the user's decision, never a refusal of their task"
# The deep wake reads status_url, so the agent must be told to copy the URL into
# the heartbeat and to poll it once per wake — or the rule names a read it was
# never handed, on the longest hunt there is.
# heartbeat_s travels in the prompt too (found in review): the carve-out is
# measured against it, and a wake holds nothing but its prompt.
assert "status_url, interval_s, heartbeat_s, wake_on, stop_on, and wake_rule" in router_text
assert "every number the wake will measure against goes into the prompt" in router_text
assert "for a deep hunt the wake polls status_url once and reports that" in router_text
# ...and that poll sees a file request only in the body's flags, never in the
# status word, so the deep wake is told to read them; a failed poll falls back to
# one get_findings before it counts against retirement, and a retired watch calls
# once and re-arms — a deep wake is a single plain-HTTPS poll, so three blocked
# ones would otherwise drop the watch of a hunt budgeted at 150 min at minute 12.
assert "so a wake seeing either flag prints bughunt · <mode> · needs-files and serves the files first" in router_text
assert "on retiring, print bughunt · <mode> · watch-retired, then call get_findings once" in router_text
assert "`awaiting_client_files`/`files_requested`, not off its\n  status word" in codex_bullet
assert "needs-files` and serves the files first" in codex_bullet
assert "before it counts as a wake that read nothing" in codex_bullet
assert "before it counts as a wake that read nothing" in router_text
# Every surface re-arms on the same predicate: needs_files is not terminal, so a
# watch retired while the reviewers wait for files must come back.
assert "call `get_findings` once: if the review is\n  still running or waiting for files, tell the user and — if the retirement came\n  from unreadable wakes, not from the age cap — arm a fresh heartbeat" in codex_bullet
# The age cap is the one retirement nothing re-arms: it is the only bound on a
# heartbeat whose review never reaches a terminal state.
assert "the age cap is the one that ends it for good" in codex_bullet
assert "then call get_findings once and arm a fresh heartbeat if the review is still running or waiting for files and the retirement came from unreadable wakes rather than the age cap" in router_text
# ...and the routing text names the flags itself: the consequent alone leaves a
# dangling "either flag" if the names are deleted.
assert "that body flags a file request as awaiting_client_files/files_requested rather than in its status word" in router_text
assert "`review_id`, `status_url`, `interval_s`,\n  `heartbeat_s`, `wake_on`, `stop_on` and `wake_rule`" in codex_bullet
# The person's live page (found in review): the ROUTING text is the only
# Codex-side rule about a capability link that reads the findings for 6 hours,
# and the skill restates it for the agent that reads that instead. Pinned like
# every sibling clause — parked in the file but dropped from the emitted array,
# every Codex session would be routed free to paste the link into a PR body.
assert "carry live_url: the private page where the person who started the hunt watches it in a browser" in router_text, "ROUTING must name live_url and whose page it is"
# One moment for the agent's line, stated the same way in the hook's sentence,
# here and in the skill (found in review): "once, right now" in the hook beside
# "once, beside the done line" here had the agent either withhold the page
# until the hunt was over or print twice under two instructions that said once.
assert "Print it for the user as a plain line twice: once when the submit answer arrives, and once more beside your terminal done/failed line" in router_text, "ROUTING must name both moments for the link"
assert "you print it as a plain line twice \u2013 once when that answer arrives,\nand once more beside your terminal `done` / `failed` line" in skill, "the skill must name the same two moments"
assert "It is a capability link: never paste it into a PR, an issue, a commit or anything shared, and never poll it yourself" in router_text, "ROUTING must carry the never-paste, never-poll rule"
assert "No live_url on the body (an older server) means no page: say nothing about one" in router_text, "ROUTING must cover the older server"
assert "**The person's own window: `live_url`.**" in skill, "the skill must have the live_url section"
assert "Never paste it into a PR, an issue, a commit message, a comment\nor anything shared, and never poll it yourself" in skill, "the skill must carry the never-paste, never-poll rule"
assert "**the link stops working 6 hours after the result**" in skill, "the skill must state the link's lifetime"
assert "its wake polls `status_url` once and reports\n  that, which is the read `wake_rule` names for a deep hunt" in codex_bullet
assert "`status_url` read,\n  whichever that wake uses" in codex_bullet
# A prompt rule did not hold (a heartbeat carrying wake_rule word for word still
# answered `running` from memory for forty minutes after done): the prompt must
# carry FACTS — an ISO retire_at the model compares to the clock — and the stop
# must be mechanical: same turn as the read, and on the server's own
# "first read after done" next_step. Dropping any one of the four leaves a
# heartbeat that can outlive its hunt again.
for phrase in (
    # Anchored at SUBMIT and carried into every replacement: a per-job cap plus
    # the re-arm rule is a watch that never ends.
    "`retire_at` = submit time + 180 min", "the SAME instant into every replacement heartbeat",
    # A retirement with a clock in it, not a verdict: 180 min is budget plus
    # queue, so a queued deep hunt can still be live there (the wake must say so).
    # Delete BEFORE the read: a delete behind a tool call is lost when it fails.
    "watch-retired`, delete this\n    automation, then call `get_findings` once and report what it answered —\n    `still running` when it is",
    "Delete BEFORE the read",
    "retired at wake regardless of what the wake\n    believes",
    # findings=N on the TERMINAL line only; the enumeration carries that form.
    # Keyed on the wake's READ, not a tool call: a deep wake polls status_url.
    "read from that wake's read — `wait_review`, `get_findings`\n    or the `status_url` body", "Non-terminal wakes keep the enumerated lines",
    "no answer from this wake's\n    read → the only line allowed is `bughunt · <mode> · poll-failed`",
    "done for more than ten minutes",
    "deletes this heartbeat in the turn that read the\n    status",
    "delete it first, then report",
    "begins \"this is the first read after done\"", "delete it in that same turn",
):
    assert phrase in codex_bullet, phrase
assert "terminal by construction" not in skill, "the age cap is a retirement, not a verdict about the review"
assert "`bughunt · fast · done · findings=N`" in codex_bullet, "the enumerated lines must carry the terminal form"
for phrase in (
    "retire_at = submit time + 180 min", "the same instant into every replacement heartbeat", "print bughunt · <mode> · watch-retired, delete this automation, then call get_findings once and report what it answered (still running when it is",
    "delete before the read",
    "whatever the wake believes",
    "on done print findings=N from that wake's read (wait_review, get_findings or the status_url body", "non-terminal wakes keep the enumerated lines",
    "no answer from a wake's read means the only line allowed is bughunt · <mode> · poll-failed", "done for over ten minutes",
    "delete the heartbeat in the same turn as the read", "delete it first, then report",
    'next_step begins "this is the first read after done"', "delete it in that same turn",
):
    assert phrase in router_text, phrase
assert "terminal by construction" not in router_text
# The CronCreate fallback is the other model-driven wake: a fresh cron turn has
# no creation time, so the same ISO instant and the same first-read clause
# travel in its prompt (rev: the remedy had landed on the Codex heartbeat only).
assert "past `<retire_at>` (an\n  ISO timestamp you substitute at creation: the SUBMIT time + 180 minutes,\n  carried unchanged into every replacement job" in claude_bullet
assert "now + 180" not in skill and "tool result" not in codex_bullet
assert "begins \"this is the first read after done\", say so" in claude_bullet
assert "print `findings=N` from that answer" in claude_bullet
# The count is `done`'s alone on this surface too: the Codex rule scopes it to
# done and the enumerated failed line is bare, but the cron prompt read
# "on done/failed … print findings=N" (rev: a failed hunt has no count to quote).
# ...but the READ stays on both branches: this surface polls with curl, so
# its get_findings is the only tool call that clears the pending record on a
# failed hunt (rev: the first cut dropped the call with the count, and the
# gate then said "a hunt is RUNNING" until the record aged out).
assert "on `done` or `failed` call `get_findings`" in claude_bullet
assert "on `done`\n  print `findings=N` from that answer, on `failed` the bare `bughunt ·\n  <mode> · failed`" in claude_bullet
assert "on done/failed call `get_findings`" not in claude_bullet
assert "on `failed` print the bare" not in claude_bullet, "a bare print on failed with no read leaves the pending record"
# The age-cap retirement is honest on this surface too: a bare watch-retired on
# a live hunt reads as "the hunt is over" (the queued deep hunt past 180 min).
assert "either\n  way print what that `get_findings` answered — `still running` when it is" in claude_bullet
assert "status_url read, whichever that wake uses" in router_text
for text in (skill, router_text):
    assert "timeout_s=225" not in text, "a 225 s hold is capped by the server to 45 s"
    assert "client MCP timeout" not in text and "client-side timeout" not in text, "the clamp answers; it does not kill the socket"
assert "never a wake to\n  count towards the retirement rule" in skill
assert "never a wake to count towards retirement" in router_text
# The stop rule, in its own words on each surface: every bare needs_files
# token in the tuples above is satisfied by a neighbouring sentence, so deleting
# this clause used to ship green — and a wake that keeps waiting through a
# needs_files answer burns a file request that is held open for minutes.
assert "On `needs_files`, send files first; on `done` or\n  `failed`, process the result and delete the heartbeat" in skill
assert "stop on done, failed or needs_files" in router_text
# The wake's shape is one read, on both surfaces, in the same words: a wake that
# loops is still holding the thread when the next one fires. The budget
# arithmetic that used to size the loop (holds plus round trips against the
# cadence) is gone with it — there is nothing left to size.
for text in (skill, router_text):
    assert "a wake that\n  loops is still holding the thread when the next one fires" in text or "a wake that loops is still holding the thread when the next one fires" in text
    assert "225s" not in text and "225 seconds" not in text
assert "15-second gap" not in skill and "handover slack" not in skill
# The no-monitor fallback is the one place with no heartbeat to hand the wait
# to, so it must keep waiting for a DEEP hunt as well: one call there ends the
# turn on an hour-long review nobody reads. It waits at the server's cadence —
# read, sleep retry_after_s in the foreground, read — and loops wait_review back
# to back only for a payload submit, where the hold is the watcher a file
# request needs.
fallback = skill.split("If the runtime cannot create its monitor,", 1)[1].split("\n\nIf the MCP server is missing", 1)[0]
# Every read names its sleep (#1029 f5): `retry_after_s` comes only from a
# timed-out wait_review and `next_poll_after_s` only from the status body, so
# a get_findings read has to be told where its cadence is.
for phrase in ("`done`, `failed` or `needs_files`", "held open for minutes only", "the waiting is for a deep hunt TOO", "running and unwatched", "never claim that a monitor is armed", "`retry_after_s`\nfrom a timed-out `wait_review`, or `next_poll_after_s` from the `status_url` body", "a `get_findings` answer carries neither", "sleep <retry_after_s>", "Do not loop `wait_review` back to back to fill the gap", "The one place the hold IS the watcher is a payload submit"):
    assert phrase in fallback, phrase
# The hand-wait read of status_url sees a file request in the body's FLAGS, never
# in its status word — the same rule the Monitor loop and the deep wake carry.
# Told to stop on the word `needs_files`, this path slept through a request the
# body was flagging on every poll (found in review).
assert "a `status_url` body flags a file request in\n`awaiting_client_files`/`files_requested`, never in its status word" in fallback
assert "treat either flag as `needs_files`" in fallback
assert "one call for a deep one" not in fallback
assert "poll_after_s=30" not in fallback and "timeout_s=45" not in fallback
# The last-resort paragraph after the loop waits at the same cadence.
assert "No background tasks in your harness? Then wait at the server's cadence" in skill
# ...and names the sleep for every read there too (#1029 f5).
last_resort = skill.split("No background tasks in your harness?", 1)[1].split("\n\n", 1)[0]
assert "sleep `retry_after_s` from a timed-out `wait_review`\nor `next_poll_after_s` from the `status_url` body (a `get_findings` answer\ncarries neither)" in last_resort, last_resort
assert "every 45-60\nseconds" not in skill

review = run("prompt", {"prompt": "Please do a deep review of PR 3401 before merge"})
review_text = review["hookSpecificOutput"]["additionalContext"]
assert "Route this request now" in review_text
assert "local review agents" in review_text

# Deep as the first review, on the user's word alone. The server takes
# `deep: true` from nobody else, so the routing text puts deep first only when
# the user asked, the prompt hook adds its sentence only when the prompt
# carries the words, and a plain review request never reads as a deep ask.
DEEP_MARK = "submit_review with deep: true is the first and only review – no fast stage first, no second question"
assert DEEP_MARK in review_text
for phrase in ("unless the user asked for the deep hunt in their own words (deep hunt, deep review, full-repo, --deep or a bare deep as the argument of the review command, in any language – the adjective alone, as in deep-dive review or a deep look, asks for a thorough fast review)",
               "one submit_review with deep: true and meta.repo + meta.ref (the pushed head sha) + meta.base_branch, no payload, is the first and only review",
               "On your own initiative start deep only after the server returns deep_offer",
               "A refusal of a deep-first request (repo_required, repo_too_big, commit_required, fast_running, deep_at_capacity) is shown to the user verbatim",
               "never a silent downgrade to fast",
               "its compact line reads bughunt · deep · running"):
    assert phrase in session_text, phrase
assert "Only start deep after the server returns deep_offer" not in session_text
assert DEEP_MARK not in session_text
# The full-repo alternative is pinned by a prompt with no other trigger word
# (a mutation that drops it left every row green: the only full-repo prompt
# also said "review").
for prompt in ("run a deep hunt on this", "full-repo review of the branch please", "do a full-repo hunt of this codebase", "full-repository audit before I merge this branch",
               "/bughunter:review --deep", "/bughunter:review deep"):
    text = run("prompt", {"prompt": prompt})["hookSpecificOutput"]["additionalContext"]
    assert "Route this request now" in text and DEEP_MARK in text, prompt
# The adjective alone is not the ask, and every alternative is closed on both
# sides: a hyphen is a word boundary, so a \bdeep\b test took "deep-dive
# review" for the paid hour-long hunt with the confirming question waived, and
# an open-ended full[- ]repo took "give me a full report" the same way. Every
# negative here is asserted ROUTED, so the marker's absence is the deep test's
# doing, not the review filter's.
for prompt in ("review this PR before merge", "hunt bugs in the diff", "review this PR, the deeply nested loop in the deeper module worries me",
               "Please do a deep-dive review before merge", "review this PR, the deep copy in cache.js worries me", "review the deep-linking refactor", "take a deep look at this PR",
               "review this PR and give me a full report", "we need full reporting on this PR before merge"):
    text = run("prompt", {"prompt": prompt})["hookSpecificOutput"]["additionalContext"]
    assert "Route this request now" in text and DEEP_MARK not in text, prompt
# ...and "full report" alone is no review request at all.
assert run("prompt", {"prompt": "give me a full report on the sales numbers"}) == {}
assert "Route this request now" in run("prompt", {"prompt": "review this PR before merge"})["hookSpecificOutput"]["additionalContext"]

# SKILL.md and the command carry the same rule: the "never as a first review"
# sentence is gone, deep first is the user's word, a refusal is shown verbatim
# with the fast hunt offered, and the watcher is the deep one.
assert "never as a first review" not in skill and "Every review starts fast" not in skill
assert "always fast" not in skill  # the third spelling, on the rung-1 path a deep-first submit takes
for phrase in ("**Deep first, only on the user's word.**",
               "The adjective alone is not the\n  ask",
               "The mode is `fast` – stage one – unless this submit\n  carried `deep: true` on the user's word (§3b): then it is `deep`",
               "`deep` or `--deep` as the argument of `/bughunter:review`",
               "no fast stage first, and no",
               "second \"are you sure\" – they already said yes",
               "Never read the ask into the\n  size of the diff or a fast result that looks thin",
               "show it verbatim,\n  then offer the fast hunt as the alternative with ONE yes/no question",
               "`repo_required`", "`repo_too_big`", "`commit_required`", "`fast_running`",
               "`mode=deep`, the cadence from ITS response",
               "the compact line reads `bughunt · deep · running`"):
    assert phrase in skill, phrase
assert "unless the user asked for\nthe deep hunt outright" in skill
assert "mode=fast # deep for a deep submit – an escalation or a deep-first hunt (`deep: true`)" in monitor_code
command = open(str(Path(router).parent.parent / "commands/review.md"), encoding="utf-8").read()
for phrase in ("except `deep` / `--deep`", "carries\n`deep: true`", "no fast stage first, no second question", "show its answer verbatim and offer the\nfast hunt instead; never downgrade silently"):
    assert phrase in command, phrase

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
