#!/bin/bash
# Run me after touching secret-scan.sh: `hooks/secret-scan-test.sh`
#
# Tokens are glued together at run time, so this public file never holds a
# string that a secret scanner (ours, or a push protection) reads as a key.
set -u
G=$(cd "$(dirname "$0")" && pwd)
fails=0

AWS="AKIA""QWERTYUIOPASDFGH"
GHP="ghp_""$(printf 'a%.0s' $(seq 1 36))"
PEM="-----BEGIN RSA ""PRIVATE KEY-----"

hook() { # tool_input JSON -> "<exit> <stderr>"
  local err rc
  err=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'mcp__plugin_bughunter_ohmybug__submit_review','tool_input':json.loads(sys.argv[1])}))" "$1" \
    | bash "$G/secret-scan.sh" 2>&1 >/dev/null); rc=$?
  printf '%s %s' "$rc" "$err"
}
row() { # name, want exit, tool_input JSON, [text the message must hold]
  local got; got=$(hook "$3")
  if [ "${got%% *}" != "$2" ]; then echo "FAIL $1: exit ${got%% *}, want $2 — ${got#* }"; fails=$((fails + 1)); return; fi
  if [ -n "${4:-}" ] && ! printf '%s' "$got" | grep -qF -- "$4"; then echo "FAIL $1: message lacks '$4' — ${got#* }"; fails=$((fails + 1)); return; fi
  echo "ok   $1"
}
j() { python3 -c "import json,sys; print(json.dumps(eval(sys.argv[1])))" "$1"; }

row "AWS key in the diff is refused"            2 "$(j "{'diff':'+++ b/app.py\n+key = \"$AWS\"\n'}")" "AWS access key"
row "the refusal masks the value"               2 "$(j "{'diff':'+k=\"$AWS\"'}")" "AKIA…GH"
row "GitHub token in a context file"            2 "$(j "{'files':[{'path':'ci.sh','content':'export T=$GHP'}]}")" "ci.sh:1 GitHub token"
row "private key block"                          2 "$(j "{'files':[{'path':'fixture.txt','content':'$PEM'}]}")" "private key"
row "a whole .env attached as context"          2 "$(j "{'files':[{'path':'deploy/.env.staging','content':'PORT=3000'}]}")" ".env.staging is a file that holds keys"
row "a diff touching a .pem file"               2 "$(j "{'diff':'+++ b/certs/server.pem\n+abc\n'}")" "server.pem"
row "AWS documentation placeholder passes"      0 "$(j "{'diff':'+k=\"AKIAIOSFODNN7EXAMPLE\"'}")"
row ".env.example attached passes"              0 "$(j "{'files':[{'path':'.env.example','content':'PORT=3000'}]}")"
row "a diff touching .env with no secret passes" 0 "$(j "{'diff':'+++ b/.env\n+PORT=3000\n'}")"
row "clean diff passes"                          0 "$(j "{'diff':'+++ b/a.py\n+print(1)\n'}")"
row "repo+ref submit has nothing to scan"       0 "$(j "{'meta':{'repo':'o/r','ref':'abc','base_branch':'main'}}")"
row "upload=true is not read here"              0 "$(j "{'upload':True,'diff':'+k=\"$AWS\"'}")"

full=$(hook "$(j "{'diff':'+k=\"$AWS\"'}")")
if printf '%s' "$full" | grep -qF "$AWS"; then echo "FAIL the full key reached the message"; fails=$((fails + 1)); else echo "ok   the full key never reaches the message"; fi

rc=$(printf 'not json' | bash "$G/secret-scan.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] && echo "ok   unreadable input stands down" || { echo "FAIL unreadable input exit $rc"; fails=$((fails + 1)); }

[ "$fails" = 0 ] && echo "secret-scan: all rows pass" || { echo "secret-scan: $fails failing"; exit 1; }
