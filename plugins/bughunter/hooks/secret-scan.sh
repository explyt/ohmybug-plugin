#!/bin/bash
# Refuse a submit_review whose inline payload carries a credential.
#
# Why a shell hook and not the Claude Code mod: a check that only some clients
# run is a check the others silently lack. This one fires wherever hooks.json
# does — Claude Code of any version, and Codex — so the same diff is refused
# everywhere, headless runs included (a refusal, never a dialog nobody answers).
#
# Only high-signal shapes: a token with a vendor prefix, a private-key block, a
# file whose name says it holds keys. A false refusal here costs a re-submit and
# teaches agents to strip context to get past it, so no entropy guessing.
#
# The message masks every value. It reaches the model's context, and printing
# the secret to say we did not send it would be a leak of its own.
#
# It reads whatever payload the call carries: submit_review's diff and files,
# provide_files' files. A repo+ref submit carries none, so nothing is read.
#
# It also FILLS provide_files' `paths`: the agent names the requested files,
# and this hook reads them from disk and hands the call on with their contents
# (updatedInput). In auto mode the classifier refuses a shell POST of repo
# files as data exfiltration, and the permission rule the first-run notice
# suggests covers MCP tools only; this keeps the answer an MCP call that rule
# covers, with no bytes through the model's context. It never decides a
# permission: it only rewrites the call the user already allowed. The bytes it
# reads are scanned below like any other payload. Not under Codex (it sets
# PLUGIN_DATA): there the paths reach the server, which refuses them and points
# at its own door.
# ponytail: the out-of-band upload (upload=true, bytes POSTed by a script later) is not scanned here.
#
# It is the ONE PreToolUse hook on submit_review, and it hands the call on to
# stamp-hunt.sh only when it lets the call through. Two hooks in parallel would
# let stamp-hunt record an attempt for a call this scan refuses; nothing clears
# that record, and the merge gate reads a lone attempt as "the environment
# refused the hunt" and warns the merge through.
set -u

STAMP=${OHMYBUG_TEST_STAMP:-$(dirname "$0")/stamp-hunt.sh}
INPUT=$(cat 2>/dev/null) || INPUT=
pass() { # the call goes on: a submit is recorded exactly as before
  case "$INPUT" in *'__submit_review"'*) printf '%s' "$INPUT" | exec bash "$STAMP" ;; esac
  exit 0
}
# The user's way out, in the env block of settings.json: no scan at all. A
# provide_files still goes through python, which fills its paths unscanned.
if [ "${OHMYBUG_SECRET_SCAN:-1}" = 0 ]; then
  case "$INPUT" in *'__provide_files"'*) ;; *) pass ;; esac
fi
command -v python3 >/dev/null 2>&1 || {
  printf '%s\n' '{"systemMessage":"OhMyBug: secret scan skipped before this upload (python3 not found)."}'
  pass
}

# The rule that closes every edge at once: the scan passes a call only when it
# READ the call and found nothing (exit 0), and refuses on a hit (exit 3). Any
# other outcome — unreadable input, a payload of an unexpected shape, a bug in
# here — is "could not scan", and that refuses too. Passing on its own failure
# is how a check turns into a hole for every input it did not foresee.
# Bytes in, bytes out, UTF-8 both ways: nothing below depends on the locale.
OUT=$(printf '%s' "$INPUT" | python3 -c '
import json, os, re, sys
d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
if os.environ.get("OHMYBUG_TEST_SCAN_RAISE"):
    raise RuntimeError("forced by the test")
ti = d.get("tool_input")
if ti is None:
    ti = {}
if not isinstance(ti, dict):
    raise TypeError("tool_input")

def stop(rc, msg):
    sys.stdout.buffer.write((msg + "\n").encode("utf-8"))
    sys.stdout.flush()
    sys.exit(rc)

# The selection rules of the files_url recipe the server hands out: the git top level of
# the session directory, a regular file whose real path (symlinks followed)
# git lists as tracked or untracked-not-ignored. Missing, a directory, under
# .git or resolving outside: skipped and named. Inside the work tree but not
# listed (ignored, or in a submodule): nothing is sent, the agent decides.
filled = None
if str(d.get("tool_name") or "").endswith("__provide_files") and "paths" in ti and not os.environ.get("PLUGIN_DATA"):
    import subprocess
    paths = ti["paths"]
    if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
        raise TypeError("paths")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=d.get("cwd") or None,
                                      env=env, stderr=subprocess.DEVNULL).rstrip(b"\n")
    except (OSError, subprocess.CalledProcessError):
        stop(5, "")
    top = os.path.realpath(top)
    listed = set(subprocess.check_output(["git", "ls-files", "-z", "-co", "--exclude-standard"], cwd=top, env=env).split(b"\0"))
    files = list(ti.get("files") or [])
    sent, skipped, unlisted = [], [], []
    for p in paths:
        full = os.path.join(top, os.fsencode(p))
        rel = os.path.relpath(os.path.realpath(full), top).replace(os.fsencode(os.sep), b"/") if os.path.isfile(full) else None
        if rel is not None and rel in listed:
            sent.append(p)
            files.append({"path": p, "content": open(full, encoding="utf-8", errors="replace").read()})
        elif rel is not None and not rel.startswith(b"../") and rel.split(b"/")[0] != b".git":
            unlisted.append(p)
        else:
            skipped.append(p)
    if unlisted:
        stop(4, "\n".join("  - " + p for p in unlisted))
    filled = {k: v for k, v in ti.items() if k != "paths"}
    filled["files"] = files
    ti = filled
    note = "OhMyBug read %d requested file(s) from disk for provide_files%s." % (len(sent), (": " + ", ".join(sent)) if sent else "")
    if skipped:
        note += " Not sent (missing, a directory, under .git or outside the repository): " + ", ".join(skipped) + "."
if os.environ.get("OHMYBUG_SECRET_SCAN", "1") == "0":
    ti = {}

SHAPES = [
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("private key", re.compile(r"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY(?: BLOCK)?-----")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})\b")),
    ("Slack token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}")),
    ("Stripe live key", re.compile(r"\b(?:sk|rk)_live_[A-Za-z0-9]{20,}")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])")),
    ("Anthropic key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}")),
    ("OpenAI key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}")),
]
# Documentation placeholders, not credentials.
PLACEHOLDER = re.compile(r"EXAMPLE|XXXX|xxxx|0000000000|REDACTED", re.I)
KEY_FILE = re.compile(r"(^|/)(id_(rsa|dsa|ecdsa|ed25519)|[^/]+\.(pem|p12|pfx|key))$")
# A whole .env attached as context is a file of secrets; a diff that touches one
# may only change PORT=3000, and its values are scanned line by line anyway.
ENV_FILE = re.compile(r"(^|/)\.env(\.(?!example$|sample$|template$|dist$)[^/]+)?$")

def mask(v):
    return v[:4] + "..." + v[-2:] if len(v) > 10 else v[:2] + "..."

hits = []
def scan(where, text):
    for no, line in enumerate(text.splitlines(), 1):
        for kind, rx in SHAPES:
            for m in rx.finditer(line):
                if PLACEHOLDER.search(m.group(0)):
                    continue
                hits.append("%s:%d %s (%s)" % (where, no, kind, mask(m.group(0))))

HUNK = re.compile(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
def scan_diff(diff):
    # Name the file and its line, not the line of the diff text. Headers are
    # read only between hunks: inside one, "--- x" is a removed "-- x" line.
    # The new side of a deleted file is /dev/null: name it by its old path.
    path, gone, new, old_left, new_left = "diff", "diff", 0, 0, 0
    for raw in diff.splitlines():
        if old_left <= 0 and new_left <= 0:
            if raw.startswith("--- "):
                gone = raw[6:].strip() if raw.startswith("--- a/") else raw[4:].strip()
                continue
            if raw.startswith("+++ "):
                path = raw[6:].strip() if raw.startswith("+++ b/") else raw[4:].strip()
                if path == "/dev/null":
                    path = gone
                continue
            if raw.startswith("diff ") or raw.startswith("index "):
                continue
            h = HUNK.match(raw)
            if h:
                old_left = int(h.group(1) or 1)
                new, new_left = int(h.group(2)), int(h.group(3) or 1)
                continue
        elif raw.startswith("\\"):
            continue
        if raw.startswith("-"):
            old_left -= 1
        elif raw.startswith("+"):
            new_left -= 1
        else:
            old_left -= 1
            new_left -= 1
        if raw.startswith("-"):
            where = "%s (a removed line)" % path
        else:
            where = "%s:%d" % (path, new)
            new += 1
        for kind, rx in SHAPES:
            for m in rx.finditer(raw):
                if not PLACEHOLDER.search(m.group(0)):
                    hits.append("%s %s (%s)" % (where, kind, mask(m.group(0))))

diff = ti.get("diff")
if diff is not None and not isinstance(diff, str):
    raise TypeError("diff")
if diff:
    scan_diff(diff)
    # The old side too: a diff that deletes a key file carries the key.
    for name in dict.fromkeys(m.group(1).strip() for m in re.finditer(r"^(?:\+\+\+ b|--- a)/(.+)$", diff, re.M)):
        if KEY_FILE.search(name):
            hits.append("diff changes %s, a file that holds keys" % name)
files = ti.get("files")
if files is not None and not isinstance(files, list):
    raise TypeError("files")
for f in files or []:
    content = f.get("content")
    if content is not None and not isinstance(content, str):
        raise TypeError("content")
    path = str(f.get("path") or "?")
    if KEY_FILE.search(path) or ENV_FILE.search(path):
        hits.append("%s is a file that holds keys" % path)
    if content:
        scan(path, content)

if hits:
    shown = hits[:12] + (["... and %d more" % (len(hits) - 12)] if len(hits) > 12 else [])
    stop(3, "\n".join(shown))
if filled is not None:
    stop(0, json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": filled, "additionalContext": note}}))
' 2>/dev/null)
rc=$?
if [ "$rc" = 0 ]; then
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  pass
fi
if [ "$rc" = 4 ] && [ -n "$OUT" ]; then
  {
    echo "OhMyBug: git does not list these requested files (ignored: build output, generated code, a secret; or in a submodule), so nothing was sent:"
    printf '%s\n' "$OUT"
    echo "Call provide_files again for the same review without them in paths. If the user approves sending them, put them in files with their content instead."
  } >&2
  exit 2
fi
if [ "$rc" = 5 ]; then
  echo "OhMyBug: provide_files paths are read from the git repository this session runs in, and this directory is not inside one, so nothing was sent. Call provide_files again with files [{path, content}] for the files you approve." >&2
  exit 2
fi
if [ "$rc" != 3 ] || [ -z "$OUT" ]; then
  {
    echo "OhMyBug: could not scan this payload for credentials, so it was NOT sent."
    case "$INPUT" in
      *'__provide_files"'*) echo "Call provide_files again for the same review (do not start a new hunt for this), or set OHMYBUG_SECRET_SCAN=0 to skip the scan." ;;
      *) echo "Resend it, or set OHMYBUG_SECRET_SCAN=0 to skip the scan. A submit with meta.repo + meta.ref and no payload has nothing to scan." ;;
    esac
  } >&2
  exit 2
fi
{
  echo "OhMyBug: this upload carries what looks like credentials, so it was NOT sent:"
  printf '%s\n' "$OUT" | LC_ALL=C sed 's/^/  - /'
  case "$INPUT" in
    *'__provide_files"'*) echo "Call provide_files again for the same review without those files (or with each value replaced by [REDACTED]); an empty list is a valid answer. Do not start a new hunt for this." ;;
    *) echo "Drop those files or replace each value with [REDACTED], then submit again. Or submit with meta.repo + meta.ref and no payload: the server reads the pushed commit and nothing leaves this machine." ;;
  esac
} >&2
exit 2
