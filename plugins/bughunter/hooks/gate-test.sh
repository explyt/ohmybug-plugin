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

rm -rf "$HOME"
if [ "$fails" = 0 ]; then echo "gate: 16/16 ok"; else echo "gate: $fails failing"; exit 1; fi
