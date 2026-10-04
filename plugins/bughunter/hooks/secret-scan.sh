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
# ponytail: the out-of-band upload (upload=true, bytes POSTed by a script later) is not scanned here.
#
# It is the ONE PreToolUse hook on submit_review, and it hands the call on to
# stamp-hunt.sh only when it lets the call through. Two hooks in parallel would
# let stamp-hunt record an attempt for a call this scan refuses; nothing clears
# that record, and the merge gate reads a lone attempt as "the environment
# refused the hunt" and warns the merge through.
set -u

INPUT=$(cat 2>/dev/null) || exit 0
STAMP=${OHMYBUG_TEST_STAMP:-$(dirname "$0")/stamp-hunt.sh}
pass() { # the call goes on: a submit is recorded exactly as before
  case "$INPUT" in *'__submit_review"'*) printf '%s' "$INPUT" | exec bash "$STAMP" ;; esac
  exit 0
}
command -v python3 >/dev/null 2>&1 || {
  printf '%s\n' '{"systemMessage":"OhMyBug: secret scan skipped before this upload (python3 not found)."}'
  pass
}

OUT=$(printf '%s' "$INPUT" | python3 -c '
import json, os, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
if not isinstance(ti, dict):
    sys.exit(0)

SHAPES = [
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("private key", re.compile(r"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})\b")),
    ("Slack token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}")),
    ("Stripe live key", re.compile(r"\b(?:sk|rk)_live_[A-Za-z0-9]{20,}")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
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
    return v[:4] + "…" + v[-2:] if len(v) > 10 else v[:2] + "…"

hits = []
def scan(where, text):
    for no, line in enumerate(text.splitlines(), 1):
        for kind, rx in SHAPES:
            for m in rx.finditer(line):
                if PLACEHOLDER.search(m.group(0)):
                    continue
                hits.append("%s:%d %s (%s)" % (where, no, kind, mask(m.group(0))))

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)")
def scan_diff(diff):
    # Name the file and its line, not the line of the diff text.
    path, new = "diff", 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            path = raw[6:].strip() if raw.startswith("+++ b/") else raw[4:].strip()
            continue
        if raw.startswith("--- ") or raw.startswith("diff ") or raw.startswith("index "):
            continue
        h = HUNK.match(raw)
        if h:
            new = int(h.group(1))
            continue
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
if isinstance(diff, str) and diff:
    scan_diff(diff)
    for m in re.finditer(r"^\+\+\+ b/(.+)$", diff, re.M):
        if KEY_FILE.search(m.group(1).strip()):
            hits.append("diff changes %s, a file that holds keys" % m.group(1).strip())
for f in ti.get("files") or []:
    if not isinstance(f, dict):
        continue
    path = str(f.get("path") or "?")
    if KEY_FILE.search(path) or ENV_FILE.search(path):
        hits.append("%s is a file that holds keys" % path)
    if isinstance(f.get("content"), str):
        scan(path, f["content"])

if hits:
    shown = hits[:12] + (["… and %d more" % (len(hits) - 12)] if len(hits) > 12 else [])
    print("\n".join(shown))
' 2>/dev/null) || pass

[ -n "$OUT" ] || pass
{
  echo "OhMyBug: this upload carries what looks like credentials, so it was NOT sent:"
  printf '%s\n' "$OUT" | sed 's/^/  - /'
  echo "Drop those files or replace each value with [REDACTED], then submit again. Or submit with meta.repo + meta.ref and no payload: the server reads the pushed commit and nothing leaves this machine."
} >&2
exit 2
