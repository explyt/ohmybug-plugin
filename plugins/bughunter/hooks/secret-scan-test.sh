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

# stamp-hunt.sh is chained from the scan; a stub stands in for it and leaves a
# mark, so a row can tell "recorded" from "refused before recording".
STUB=$(mktemp -d); MARK="$STUB/stamped"
printf '#!/bin/sh\ncat >/dev/null\n: > "%s"\n' "$MARK" > "$STUB/stamp.sh"
export OHMYBUG_TEST_STAMP="$STUB/stamp.sh"
TOOL=submit_review
hook() { # tool_input JSON -> "<exit> <stderr>"; the tool is $TOOL
  local err rc
  rm -f "$MARK"
  # Raw UTF-8 bytes, not \u escapes: that is what a client sends, and only raw
  # bytes reach a stdin decoded in the locale codec.
  err=$(python3 -c "import json,sys; sys.stdout.buffer.write(json.dumps({'tool_name':'mcp__plugin_bughunter_ohmybug__'+sys.argv[2],'tool_input':json.loads(sys.argv[1])}, ensure_ascii=False).encode('utf-8'))" "$1" "$TOOL" \
    | bash "$G/secret-scan.sh" 2>&1 >/dev/null); rc=$?
  printf '%s %s' "$rc" "$err"
}
stamped() { [ -e "$MARK" ] && echo yes || echo no; }
check() { # name, got, want
  [ "$2" = "$3" ] && echo "ok   $1" || { echo "FAIL $1: got $2, want $3"; fails=$((fails + 1)); }
}
row() { # name, want exit, tool_input JSON, [text the message must hold]
  local got; got=$(hook "$3")
  if [ "${got%% *}" != "$2" ]; then echo "FAIL $1: exit ${got%% *}, want $2 — ${got#* }"; fails=$((fails + 1)); return; fi
  if [ -n "${4:-}" ] && ! printf '%s' "$got" | LC_ALL=C grep -qF -- "$4"; then echo "FAIL $1: message lacks '$4' — ${got#* }"; fails=$((fails + 1)); return; fi
  echo "ok   $1"
}
j() { python3 -c "import json,sys; print(json.dumps(eval(sys.argv[1])))" "$1"; }

row "AWS key in the diff names file and line"   2 "$(j "{'diff':'+++ b/app.py\n@@ -1,2 +1,3 @@\n x = 1\n+key = \"$AWS\"\n'}")" "app.py:2 AWS access key"
row "the refusal masks the value"               2 "$(j "{'diff':'+k=\"$AWS\"'}")" "AKIA...GH"
row "GitHub token in a context file"            2 "$(j "{'files':[{'path':'ci.sh','content':'export T=$GHP'}]}")" "ci.sh:1 GitHub token"
row "private key block"                          2 "$(j "{'files':[{'path':'fixture.txt','content':'$PEM'}]}")" "private key"
row "a whole .env attached as context"          2 "$(j "{'files':[{'path':'deploy/.env.staging','content':'PORT=3000'}]}")" ".env.staging is a file that holds keys"
row "a diff touching a .pem file"               2 "$(j "{'diff':'+++ b/certs/server.pem\n+abc\n'}")" "server.pem"
row "AWS documentation placeholder passes"      0 "$(j "{'diff':'+k=\"AKIAIOSFODNN7EXAMPLE\"'}")"
row ".env.example attached passes"              0 "$(j "{'files':[{'path':'.env.example','content':'PORT=3000'}]}")"
row "a diff touching .env with no secret passes" 0 "$(j "{'diff':'+++ b/.env\n+PORT=3000\n'}")"
row "clean diff passes"                          0 "$(j "{'diff':'+++ b/a.py\n+print(1)\n'}")"
row "repo+ref submit has nothing to scan"       0 "$(j "{'meta':{'repo':'o/r','ref':'abc','base_branch':'main'}}")"
row "a removed '-- ' line inside a hunk is scanned" 2 "$(j "{'diff':'--- a/q.sql\n+++ b/q.sql\n@@ -1,2 +1,1 @@\n--- key $AWS\n x\n'}")" "q.sql (a removed line) AWS access key"
row "upload=true still reads an inline payload" 2 "$(j "{'upload':True,'diff':'+k=\"$AWS\"'}")" "AWS access key"
row "upload=true with no payload passes"        0 "$(j "{'upload':True}")"
TOOL=provide_files
row "provide_files carrying a token is refused" 2 "$(j "{'review_id':'r','files':[{'path':'ci.sh','content':'T=$GHP'}]}")" "ci.sh:1 GitHub token"
row "a refused provide_files is told to resend, not to hunt again" 2 "$(j "{'review_id':'r','files':[{'path':'ci.sh','content':'T=$GHP'}]}")" "Call provide_files again"
TOOL=submit_review

# A refused submit must leave no attempt behind: the gate reads a lone attempt
# as "the environment refused the hunt" and warns the merge through.
hook "$(j "{'diff':'+k=\"$AWS\"'}")" >/dev/null; check "a refused submit is not recorded" "$(stamped)" no
hook "$(j "{'diff':'+print(1)'}")" >/dev/null; check "a clean submit is recorded" "$(stamped)" yes
TOOL=provide_files; hook "$(j "{'files':[{'path':'a','content':'x'}]}")" >/dev/null; check "provide_files is never recorded" "$(stamped)" no; TOOL=submit_review
wired=$(python3 - "$G/hooks.json" <<'PY2'
import json, re, sys
pre = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
print(" ".join(k["command"].rsplit("/", 1)[-1] for e in pre
               if re.search(e.get("matcher", ""), "mcp__plugin_bughunter_ohmybug__submit_review") for k in e["hooks"]))
PY2
)
check "submit_review has one PreToolUse hook, the scan" "$wired" "secret-scan.sh"

full=$(hook "$(j "{'diff':'+k=\"$AWS\"'}")")
if printf '%s' "$full" | LC_ALL=C grep -qF "$AWS"; then echo "FAIL the full key reached the message"; fails=$((fails + 1)); else echo "ok   the full key never reaches the message"; fi

# The scan must read and report under any locale. Each of these once broke a
# step (a print that raised, a stdin decoded in the locale codec), and the hook
# then read its own failure as "nothing found". A locale the machine lacks is a
# failure here, not a skip: CI generates them (see ci.yaml).
for lc in en_US.ISO8859-1:iso8859-1 ja_JP.eucJP:euc_jp zh_CN.GBK:gbk; do
  loc=${lc%:*}
  # A missing locale falls back to C/UTF-8 and the row would pass for nothing.
  got=$(LC_ALL=$loc PYTHONUTF8=0 python3 -c 'import codecs, locale; print(codecs.lookup(locale.getpreferredencoding(False)).name)' 2>/dev/null)
  if [ "$got" != "${lc#*:}" ]; then
    echo "FAIL locale $loc is not installed (python reads ${got:-nothing}), so its row cannot run"; fails=$((fails + 1)); continue
  fi
  LC_ALL=$loc LANG=$loc PYTHONUTF8=0 PYTHONIOENCODING= row "a key is refused under $loc, its file named" 2 "$(j "{'files':[{'path':'\u65e5.md','content':'\u65e5\u672c \u4e2d\u6587 k=$AWS'}]}")" ".md:1 AWS access key"
done

# A scan that fails refuses: it never lets through what it did not read.
OHMYBUG_TEST_SCAN_RAISE=1 row "an error inside the scan refuses" 2 "$(j "{'diff':'+print(1)'}")" "could not scan this payload"
OHMYBUG_TEST_SCAN_RAISE=1 hook "$(j "{'diff':'+print(1)'}")" >/dev/null; check "a scan that failed records nothing" "$(stamped)" no
TOOL=provide_files
OHMYBUG_TEST_SCAN_RAISE=1 row "a provide_files that could not be scanned is told to resend" 2 "$(j "{'files':[{'path':'a','content':'x'}]}")" "Call provide_files again"
TOOL=submit_review
row "a payload of an unexpected shape refuses"  2 "$(j "{'files':'not a list'}")" "could not scan"
rc=$(printf 'not json' | bash "$G/secret-scan.sh" >/dev/null 2>&1; echo $?)
check "unreadable input refuses" "$rc" 2

# The user's way out: the scan is off, the call goes through and is recorded.
OHMYBUG_SECRET_SCAN=0 row "OHMYBUG_SECRET_SCAN=0 lets a key through" 0 "$(j "{'diff':'+k=\"$AWS\"'}")"
OHMYBUG_SECRET_SCAN=0 hook "$(j "{'diff':'+k=\"$AWS\"'}")" >/dev/null; check "with the scan off a submit is still recorded" "$(stamped)" yes

[ "$fails" = 0 ] && echo "secret-scan: all rows pass" || { echo "secret-scan: $fails failing"; exit 1; }
