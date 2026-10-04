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

STAMP=${OHMYBUG_TEST_STAMP:-$(dirname "$0")/stamp-hunt.sh}
INPUT=$(cat 2>/dev/null) || INPUT=
pass() { # the call goes on: a submit is recorded exactly as before
  case "$INPUT" in *'__submit_review"'*) printf '%s' "$INPUT" | exec bash "$STAMP" ;; esac
  exit 0
}
# The user's way out, in the env block of settings.json: no scan at all.
[ "${OHMYBUG_SECRET_SCAN:-1}" = 0 ] && pass
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
    path, new, old_left, new_left = "diff", 0, 0, 0
    for raw in diff.splitlines():
        if old_left <= 0 and new_left <= 0:
            if raw.startswith("+++ "):
                path = raw[6:].strip() if raw.startswith("+++ b/") else raw[4:].strip()
                continue
            if raw.startswith("--- ") or raw.startswith("diff ") or raw.startswith("index "):
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
    for m in re.finditer(r"^\+\+\+ b/(.+)$", diff, re.M):
        if KEY_FILE.search(m.group(1).strip()):
            hits.append("diff changes %s, a file that holds keys" % m.group(1).strip())
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
    sys.stdout.buffer.write(("\n".join(shown) + "\n").encode("utf-8"))
    sys.stdout.flush()
    sys.exit(3)
' 2>/dev/null)
rc=$?
[ "$rc" = 0 ] && pass
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
