#!/bin/bash
# The Bugarium's two notices, handed to the PERSON rather than the agent: a new
# bug species hatching from stories they published (they may pick its name and
# mascot until the vote closes), and a species they are a discoverer of.
#
# The server puts both under `bugarium` on submit_review, confirm_findings and
# get_balance, and asks the agent to pass them on. An agent busy with a merge
# forgets; the vote closes in a day and the discovery is said once. So the
# person hears it from here as well — Claude Code shows `systemMessage` to the
# user, and a client that does not know the field ignores it.
#
# Only SHAPES are taken from the body: an https URL, an ISO timestamp, a short
# plain name. The sentence is this hook's own, so nothing else a response
# carries — a review quoting text, a body that did not come from the server —
# can reach the person through it. Silent on any answer without the field.
set -u

INPUT=$(cat 2>/dev/null) || exit 0

printf '%s' "$INPUT" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

def body_of(r):
    # The client picks the envelope: the object itself, {content:[...]}, the
    # bare content list, or one text part carrying the JSON.
    if isinstance(r, str):
        try:
            r = json.loads(r)
        except Exception:
            return {}
    if isinstance(r, list):
        r = {"content": r}
    if not isinstance(r, dict):
        return {}
    if "bugarium" in r:
        return r
    parts = [r] if isinstance(r.get("text"), str) else r.get("content")
    for part in parts if isinstance(parts, list) else []:
        if isinstance(part, dict) and isinstance(part.get("text"), str):
            try:
                inner = json.loads(part["text"])
            except Exception:
                continue
            if isinstance(inner, dict):
                return inner
    return {}

def url(v):
    # Printable ASCII with no whitespace of any kind, bounded, https, and a
    # Bugarium path: a link shown to a person is a link and nothing more.
    return v if isinstance(v, str) and len(v) <= 300 and re.fullmatch(r"https://[!-~]+/bugs/[!-~]+", v) else ""

def when(v):
    m = re.fullmatch(r"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})(:\d{2}(\.\d+)?)?Z", v) if isinstance(v, str) else None
    return m.group(1) + " " + m.group(2) + " UTC" if m else ""

def name(v):
    return v if isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ,.()/-]{0,79}", v) else ""

b = body_of(d.get("tool_response")).get("bugarium")
if not isinstance(b, dict):
    sys.exit(0)
lines = []
vote = b.get("vote")
if isinstance(vote, dict) and url(vote.get("url")):
    by = when(vote.get("closes_at"))
    lines.append("OhMyBug Bugarium: a new bug species is hatching from stories you published. "
                 + "Pick its name and its mascot" + (" before " + by if by else "") + ": " + url(vote.get("url")))
for f in b.get("discovered") if isinstance(b.get("discovered"), list) else []:
    if isinstance(f, dict) and url(f.get("url")) and name(f.get("species")):
        lines.append("OhMyBug Bugarium: you are a discoverer of a new bug species, \"" + name(f.get("species"))
                     + "\" (your name is on its page): " + url(f.get("url")))
if lines:
    print(json.dumps({"systemMessage": "\n".join(lines[:4])}))
' 2>/dev/null

exit 0
