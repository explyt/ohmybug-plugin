#!/bin/bash
# Run me after touching pre-pr-gate.sh: `hooks/gate-test.sh`
#
# Every row here is a defect that shipped. Deciding "is this a merge" by string
# surgery in shell produced four of them in twenty lines — an infinite loop on
# any bare NAME=value segment (which hung EVERY Bash call, because this hook
# runs on all of them), a false block on a command that merely quoted the
# words, SKIP_BUGHUNT=1 on an unrelated earlier segment disarming the gate, and
# `bash -c "gh pr merge"` walking straight through. Keep the table; it is the
# cheapest thing standing between this hook and the next one of those.
set -u
G=$(cd "$(dirname "$0")" && pwd)
export HOME=$(mktemp -d)
cd "$(git -C "$G" rev-parse --show-toplevel)" || exit 1
fails=0

mk() { python3 -c "import json,sys;print(json.dumps({'tool_input':{'command':sys.argv[1]},'cwd':sys.argv[2]}))" "$1" "$2"; }
t() {
  want=$2
  # perl, not timeout(1): macOS has no timeout, and a hang must be reported as
  # a hang rather than as a pass.
  rc=$(mk "$1" "$PWD" | perl -e 'alarm 10; exec @ARGV' bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
  [ "$rc" = 142 ] && rc=HUNG
  if [ "$rc" != "$want" ]; then
    printf 'FAIL want=%s got=%s : %s\n' "$want" "$rc" "$(printf '%s' "$1" | tr '\n' '~')"
    fails=$((fails + 1))
  fi
}

# Built by pieces so this file does not trip the gate it is testing.
V="gh pr"; V="$V merge 5 --squash"

t "$V"                                   2  # the case the gate exists for
t "echo 'later: $V'"                     0  # a mention is not an invocation
t "grep -rn '$V' docs/"                  0
t "SKIP_BUGHUNT=1 $V"                    0  # explicit opt-out
t "SKIP_BUGHUNT=1 npm test; $V"          2  # opt-out counts only on the merge
t "git push && $V"                       2
t "FOO=bar $V"                           2  # env prefix does not hide it
t "gh pr view 5"                         0
t "n=5
echo \$n"                                0  # hung forever before
t "cat > .env <<'EOF'
API_KEY=abc123
EOF"                                     0  # heredoc line hung forever before
t "VERSION=1.2.3; echo \$VERSION"        0
t "$V; DONE=1"                           2
t "bash -c '$V'"                         2  # walked through before
t "( $V )"                               2
t "if true; then $V; fi"                 2
t "npm run build && (cd api && $V)"      2


# --- the stamp half -----------------------------------------------------
# The gate is only as honest as its evidence. When the marker was written by
# the skill, a hunt driven straight through the MCP tools left none, and the
# gate blocked work that HAD been hunted (owner report, 2026-08-11) — which is
# how a control teaches people to disarm it. These rows pin the stamp to the
# tool calls themselves.
post() { # tool, done?, -> runs stamp-hunt.sh
  python3 -c "import json,sys;print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__'+sys.argv[1],
    'tool_response':{'content':[{'type':'text','text':json.dumps(
       {'review_id':'rev_x','status':'done' if sys.argv[2]=='1' else 'running'})}]},
    'cwd':sys.argv[3]}))" "$1" "$2" "$PWD" | bash "$G/stamp-hunt.sh"
}
. "$G/diff-id.sh"
M=$(ohmybug_marker_path)
s() { # label, expected marker content ('' = absent)
  got=$([ -f "$M" ] && cat "$M")
  if [ "$got" != "$2" ]; then
    printf 'FAIL stamp %s: want=%s got=%s\n' "$1" "${2:-<none>}" "${got:-<none>}"
    fails=$((fails + 1))
  fi
}

rm -f "$M" "$M.pending"
ID=$(ohmybug_diff_id)
if [ -z "$ID" ]; then
  echo "stamp: no working diff here, cannot exercise the stamp (commit something first)" >&2
  fails=$((fails + 1))
else
  post get_findings 0; s "still running writes nothing" ""
  post submit_review 0; s "submit alone does not authorise" ""
  post get_findings 1; s "done promotes the submitted diff" "$ID"
  t "$V" 0                                    # ...and the gate now lets it through
  # Fixes written WHILE the review runs were never hunted. The marker must
  # name the diff that was sent, not whatever the tree looks like when the
  # answer arrives — otherwise the gate blesses code the hunt never saw.
  rm -f "$M" "$M.pending"
  post submit_review 0
  echo "# stamp-test-race $$" >> README.md
  post get_findings 1; s "done stamps the SENT diff, not the current one" "$ID"
  t "$V" 2
  git checkout -- README.md 2>/dev/null || true
  rm -f "$M"
  post confirm_findings 0; s "confirm stamps even with no pending" "$ID"
  # The whole point of hashing the diff: fixes written after the hunt must
  # re-block, or the gate authorises code nobody reviewed.
  echo "# stamp-test $$" >> README.md
  t "$V" 2
  git checkout -- README.md 2>/dev/null || sed -i '' -e "/# stamp-test $$/d" README.md
fi

rm -rf "$HOME"
if [ "$fails" = 0 ]; then echo "gate+stamp: ok"; else echo "gate+stamp: $fails failing"; exit 1; fi
