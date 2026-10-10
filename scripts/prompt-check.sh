#!/bin/bash
# Does the skill reach the agent intact, and do its commands reach the user
# without a security warning? Asked of a real Claude Code client, not of a copy
# of its rules.
#
# Two things went wrong on real clients, and both are the client's doing:
#
#   1. The client replaces every `$<digits>` in a skill body with an argument of
#      the skill call (older clients with "" whenever args is present at all), so
#      `local base=$1` reached the agent as `local base=`, and a price of `$10`
#      as an empty word. The check loads the skill through the client's Skill
#      tool with two arguments and wants every line of its body back verbatim.
#   2. Its permission check refuses, with "Contains brace with quote character
#      (expansion obfuscation)", any unquoted `{` followed by a quote before the
#      next `}` – a function body, a dict literal in a heredoc. The user sees
#      that warning on every prompt and learns to click through warnings. The
#      check asks the client for one Bash call per bash block and reads its
#      refusal reasons.
#
# The client talks to a stub Messages API on localhost that plays the model: it
# asks for the tool calls, then ends the turn. No model, no credentials. The
# client may RUN a command it judges harmless, so every placeholder becomes a
# dead local address or a one-second cadence, in an empty directory.
#
#   --self-test  positive control: a copy whose skill carries a block with both
#                defects must fail both checks. A client that renames its reason
#                or ignores the arguments would otherwise turn this green for good.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
usage() { echo "usage: scripts/prompt-check.sh [--self-test] <claude-binary>" >&2; exit 2; }
self_test=
[ "${1:-}" = --self-test ] && { self_test=1; shift; }
[ $# = 1 ] || usage
claude=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/stub.js" <<'JS'
// Plays the model for one turn: the first request that offers tools gets the
// tool calls in $CALLS; every later one ends the turn. Each request's message
// text is appended to $OUT/texts, each tool result to $OUT/results.
const http = require('http'), fs = require('fs');
const calls = JSON.parse(fs.readFileSync(process.env.CALLS, 'utf8'));
const out = process.env.OUT;
let asked = false, n = 0;
const strings = (v, acc) => {
  if (typeof v === 'string') acc.push(v);
  else if (Array.isArray(v)) v.forEach(x => strings(x, acc));
  else if (v && typeof v === 'object') Object.values(v).forEach(x => strings(x, acc));
  return acc;
};
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    let j = {};
    try { j = JSON.parse(body); } catch {}
    for (const m of j.messages || []) {
      for (const b of Array.isArray(m.content) ? m.content : []) {
        if (b.type === 'tool_result') fs.appendFileSync(out + '/results', JSON.stringify({id: b.tool_use_id, text: strings(b.content, []).join('\n')}) + '\n');
      }
    }
    fs.appendFileSync(out + '/texts', strings(j.messages || [], []).join('\n') + '\n');
    if (!req.url.startsWith('/v1/messages') || req.url.includes('count_tokens')) {
      res.writeHead(200, {'content-type': 'application/json'});
      return res.end('{"input_tokens":1,"data":[]}');
    }
    const ask = !asked && (j.tools || []).some(t => t.name === calls[0].name);
    if (ask) asked = true;
    const id = 'msg_' + (++n), usage = {input_tokens: 1, output_tokens: 1};
    const content = ask ? calls.map(c => ({type: 'tool_use', id: c.id, name: c.name, input: c.input}))
                        : [{type: 'text', text: 'ok'}];
    const stop = ask ? 'tool_use' : 'end_turn';
    if (!j.stream) {
      res.writeHead(200, {'content-type': 'application/json'});
      return res.end(JSON.stringify({id, type: 'message', role: 'assistant', model: j.model, content, stop_reason: stop, usage}));
    }
    res.writeHead(200, {'content-type': 'text/event-stream'});
    const ev = (type, d) => res.write(`event: ${type}\ndata: ${JSON.stringify({type, ...d})}\n\n`);
    ev('message_start', {message: {id, type: 'message', role: 'assistant', model: j.model, content: [], stop_reason: null, usage}});
    content.forEach((b, index) => {
      if (b.type === 'text') {
        ev('content_block_start', {index, content_block: {type: 'text', text: ''}});
        ev('content_block_delta', {index, delta: {type: 'text_delta', text: b.text}});
      } else {
        ev('content_block_start', {index, content_block: {...b, input: {}}});
        ev('content_block_delta', {index, delta: {type: 'input_json_delta', partial_json: JSON.stringify(b.input)}});
      }
      ev('content_block_stop', {index});
    });
    ev('message_delta', {delta: {stop_reason: stop, stop_sequence: null}, usage: {output_tokens: 1}});
    ev('message_stop', {});
    res.end();
  });
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(out + '/port', String(server.address().port)));
JS

# blocks <file>: every ```bash block, one per NUL-terminated record, indent removed.
blocks() {
  awk '
    /^ *```bash *$/ { inb = 1; match($0, /^ */); ind = RLENGTH; buf = ""; next }
    inb && /^ *``` *$/ { inb = 0; printf "%s%c", buf, 0; next }
    inb { buf = buf substr($0, ind + 1) "\n" }
  ' "$1"
}

# session <dir> <calls.json> [claude args...]: one headless turn against the stub.
session() {
  local dir=$1 calls=$2 port pid i
  shift 2
  mkdir -p "$dir/run"
  : >"$dir/results"; : >"$dir/texts"
  CALLS=$calls OUT=$dir node "$work/stub.js" & pid=$!
  for i in $(seq 50); do [ -s "$dir/port" ] && break; sleep 0.1; done
  port=$(cat "$dir/port")
  (cd "$dir/run" && OMB_STATE_DIR=$CLAUDE_CONFIG_DIR/state ANTHROPIC_API_KEY= ANTHROPIC_AUTH_TOKEN=stub \
    ANTHROPIC_BASE_URL=http://127.0.0.1:$port "$claude" -p check --permission-mode default "$@" \
    </dev/null >"$dir/session.json" 2>&1) || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# check <checkout>: prints what fails; 0 when both checks pass.
check() {
  local src=$1 skill=$1/plugins/bughunter/skills/bughunter/SKILL.md dir=$work/c$RANDOM bad=0 f
  mkdir -p "$dir"
  export CLAUDE_CONFIG_DIR=$dir/cfg
  "$claude" plugin marketplace add "$src" >/dev/null
  "$claude" plugin install bughunter@ohmybug >/dev/null

  # 1. The skill through the Skill tool, called with two arguments.
  node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify([{id: "toolu_skill", name: "Skill", input: {skill: "bughunter:bughunter", args: "one two"}}]))' "$dir/skill.json"
  session "$dir/s" "$dir/skill.json" --allowedTools Skill
  if ! grep -q 'Default scope: everything that would land' "$dir/s/texts"; then
    echo "prompt-check: the skill never reached the agent"; tail -c 600 "$dir/s/session.json"; return 1
  fi
  while IFS= read -r line; do
    [ -n "${line// }" ] || continue
    grep -qF -- "$line" "$dir/s/texts" || { echo "prompt-check: the agent got this skill line altered: $line"; bad=1; }
  done < <(awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { fm = 0; next } !fm' "$skill")

  # 2. Every bash block as one Bash call, plus the control the client must refuse.
  for f in "$skill" "$src"/plugins/bughunter/commands/*.md; do blocks "$f"; done |
    node -e '
      const fs = require("fs");
      const cmds = fs.readFileSync(0, "utf8").split("\0").filter(Boolean).map(c => c
        .replace(/<[a-z_]*_s>/g, "1")
        .replace(/<review_id>/g, "rev_check")
        .replace(/<[a-z_.]*url>|<share\.how URL>/gi, "http://127.0.0.1:9/x"));
      cmds.push("control() { echo \"x\"; }");
      fs.writeFileSync(process.argv[1], JSON.stringify(cmds.map((command, i) =>
        ({id: "toolu_" + i, name: "Bash", input: {command, description: "check " + i}}))));
    ' "$dir/bash.json"
  session "$dir/b" "$dir/bash.json"
  node -e '
    const fs = require("fs");
    const calls = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const got = new Map(fs.readFileSync(process.argv[2], "utf8").split("\n").filter(Boolean)
      .map(l => JSON.parse(l)).map(r => [r.id, r.text]));
    const control = calls.at(-1).id;
    let bad = 0;
    for (const c of calls) {
      const why = got.get(c.id);
      if (why === undefined) { console.log("prompt-check: no tool result for " + c.input.description); bad = 1; continue; }
      const warned = /expansion obfuscation/.test(why);
      if (c.id === control && !warned) { console.log("prompt-check: the control was not refused (" + why.slice(0, 120) + ")"); bad = 1; }
      if (c.id !== control && warned) { console.log("prompt-check: warning on this command:\n" + c.input.command); bad = 1; }
    }
    process.exit(bad);
  ' "$dir/bash.json" "$dir/b/results" || bad=1
  return $bad
}

v=$("$claude" --version)
if [ -n "$self_test" ]; then
  copy=$work/bad
  mkdir -p "$copy"
  cp -R "$ROOT/.claude-plugin" "$ROOT/plugins" "$copy/"
  printf '\n```bash\ncanary() { echo "$1"; }\n```\n' >>"$copy/plugins/bughunter/skills/bughunter/SKILL.md"
  out=$(check "$copy" || true)
  grep -q 'altered: canary' <<<"$out" || { echo "$out"; echo "prompt-check self-test ($v): FAILED, the argument substitution passed"; exit 1; }
  grep -q 'warning on this command' <<<"$out" || { echo "$out"; echo "prompt-check self-test ($v): FAILED, the brace warning passed"; exit 1; }
  echo "prompt-check self-test ($v): ok"
else
  check "$ROOT" || { echo "prompt-check: $v FAILED"; exit 1; }
  echo "prompt-check: $v sees the skill intact and no warning on its commands"
fi
