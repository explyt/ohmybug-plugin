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
# Both halves of the settings lookup, not just the HOME one: a maintainer who
# granted these MCP tools in PROJECT-local settings would otherwise fail the
# warn-through rows on their own checkout, with a message naming none of that,
# while CI on a clean clone stayed green.
export CLAUDE_PROJECT_DIR=$HOME/project
mkdir -p "$CLAUDE_PROJECT_DIR"
cd "$(git -C "$G" rev-parse --show-toplevel)" || exit 1
fails=0

# Make our own dirty state instead of hoping for one.
#
# EVERY row in this file needs a working diff to speak about: with a clean tree
# the gate correctly stands down ("this gate speaks about the working diff, and
# there isn't one"), so every block row reads as allow and the whole stamp half
# was skipped and counted as a single failure. This file only ever worked because
# someone happened to have edits lying around — that is, it was off precisely
# when the tree is in the state you release from.
# ponytail: the git index is still shared; serialize per checkout if parallel runs become real.
SCRATCH=".ohmybug-gate-test-scratch.$$"
# `git add -N` is what makes the file visible to `git diff`, and it leaves an
# index entry behind — so the cleanup has to undo both, or this test dirties the
# repository it just finished testing.
cleanup_scratch() { rm -f "$SCRATCH"; git reset -q -- "$SCRATCH" 2>/dev/null || true; }
trap 'cleanup_scratch' EXIT
# What the tree looked like before we touched anything. A test that runs against
# the real repository has to leave it exactly as it found it: this file once put
# a tracked file back with `git checkout --`, which is data loss for anyone with
# uncommitted work in it, and CI never noticed because CI's tree is always clean.
TREE_BEFORE=$(git status --porcelain | grep -v "$SCRATCH" || true)
printf 'gate-test scratch %s\n' "$$" > "$SCRATCH"
git add -N "$SCRATCH" 2>/dev/null || true

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

# --- the corpus: not merges, and once blocked anyway --------------------------
# Every row below is the shape of a real command this hook exited 2 on: 20 of
# them in one operator's transcripts (2026-08-15), none a merge. shlex does not
# know what a heredoc is, so an apostrophe in a body — a commit message, a
# ticket comment, a review note — read as an unbalanced quote, and the "cannot
# parse" branch treated that as an accusation. The one before it passed only
# because its heredoc body happened to contain no quote at all: coverage of the
# shape, not of the failure.
# Odd number of apostrophes on purpose: two of them pair up in shlex and the
# row proves nothing. Each of these must be red on the pre-fix hook.
t "cat > /tmp/x.md <<'EOF'
it's here
EOF"                                     0
t "git commit -F - <<'EOF'
fix: Review C's finding
EOF"                                     0
t "python3 - <<'PY'
s = '''don't'''
PY"                                      0
t "gh issue comment 36 --body-file - <<'EOF'
lessons: the pre-check's own layer
EOF"                                     0
t "git merge-base HEAD origin/main"      0  # the bare word is not a merge
t "git log --no-merges"                  0
t "cd /tmp/wt-merge-cache && npm test"   0  # nor is a path that contains it
# The row the fix is actually about: unparsable, MENTIONS a merge, is not one.
# Without it every corpus row above is decided before the unparsed branch runs,
# and deleting that branch keeps the suite green.
t "git commit -F - <<'EOF'
fix: don't merge this yet
EOF"                                     0
# ...and an unparsable command that DOES merge still blocks, opt-out still opts.
t "echo it's time; $V"                   2
t "SKIP_BUGHUNT=1 echo it's time; $V"    0
# The opt-out is a fact about the command, not about the payload around it:
# `description` is written by the model, and honouring it there would hand the
# agent the hatch that exists to keep the decision with a human.
rc=$(python3 -c "import json,sys;print(json.dumps({'cwd':sys.argv[1],'tool_input':{
  'command':\"echo it's time; \"+sys.argv[2],
  'description':'merge it (SKIP_BUGHUNT=1 already checked)'}}))" "$PWD" "$V" \
  | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL opt-out honoured from a model-written description (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
# Nor about where it sits: mentioning it mid-sentence is not opting out.
t "echo about SKIP_BUGHUNT=1 policy; $V" 2

# A newline in the cwd must not shift the verdict out of the field the shell
# reads: the gate then exits 0 on an unhunted merge, silently, which is the one
# outcome this file's header forbids.
NLDIR="$HOME/nl
dir"
mkdir -p "$NLDIR" 2>/dev/null
rc=$(mk "$V" "$NLDIR" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL a newline in cwd shifted the verdict (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$HOME/nl"

# --- the merge rule, in every spelling the tokenizer accepts -------------------
# The rule lives in two places (the python tuple and the unparsed-branch regex);
# rows that only ever use one spelling let the other drift. Every line here is a
# command a person could plausibly type.
V2="glab mr"; V2="$V2 merge 5"
t "$V2"                                  2  # the GitLab half, untested until now
t "gh pr  merge 5"                       2  # two spaces
t "$(printf 'gh pr\tmerge 5')"           2  # a tab
t "gh \"pr\" merge 5"                    2  # quoted word
t "gh pr 'merge' 5"                      2
t "gh pr me''rge 5"                      2  # shlex joins it; a substring test does not
t "npm test
$V"                                      2  # a newline ends a command too
t "env $V"                               2  # wrappers do not hide the head
t "sudo $V"                              2
t "env FOO=bar $V"                       2  # ...nor does a wrapper plus a prefix
t "sudo FOO=bar $V"                      2
t "FOO=bar env $V"                       2
t "gh pr me''rge 5; echo it's here"      2  # unparsable AND quote-split
# ...but a line break inside DATA is not a command break. shlex has no idea it
# is reading a heredoc body, so re-reading raw lines turns a document that
# happens to quote the command into a merge — a false block in the fix whose
# whole purpose is removing them.
t "cat > /tmp/note.md <<EOF
$V
EOF"                                     0
t "echo \"step one
$V
step three\""                            0
# The opt-out is a command position, and a heredoc body line is not one.
t "cat > /tmp/doc.md <<EOF
SKIP_BUGHUNT=1 is the operator hatch
EOF
$V"                                      2
t "cd /tmp && SKIP_BUGHUNT=1 $V"         0  # where a human actually types it
t "cat > /tmp/doc.md <<EOF
policy; SKIP_BUGHUNT=1 is the hatch, don't use it
EOF
$V"                                      2  # apostrophe AFTER the opt-out
t "cat > /tmp/doc.md <<'EOF'
policy; SKIP_BUGHUNT=1 is the hatch
EOF
echo it's done; $V"                      2  # quoted terminator
# A separator INSIDE data is not a command boundary. One apostrophe makes the
# command unparsable, and the opt-out then came from a document the model wrote.
t "cat > /tmp/doc.md <<EOF
it's the hatch; SKIP_BUGHUNT=1 noted
EOF
$V"                                      2
# A multi-line quoted argument is data too — and a global "any token spans
# lines" veto switched the whole line re-read off, hiding the merge after it.
t "git commit -m \"fix: thing

more detail\"
$V"                                      2
# `<<` that is not a heredoc opener: a conflict-marker grep and a here-string.
# Blanking to a terminator that never comes erased the merge after them.
t "grep -rn \"<<<<<<< HEAD\" src/
$V"                                      2
t "jq . <<<\"literal\"
$V"                                      2
# ...and the unparsed fallback reads the heredoc body no more than the parser
# does: this one mentions a merge inside a commit message and merges nothing.
t "git commit -F - <<'EOF'
fix: don't let the gh pr merge gate block doc writes
EOF"                                     0

# --- degraded: python3 missing or broken --------------------------------------
# Without python3 the hook cannot read a command — and stamp-hunt.sh cannot
# record a hunt either, since it is the same interpreter. So a block on such a
# machine could never be lifted by hunting: it is a dead end by construction,
# and a dead end is what teaches people to disarm the gate. Stand down instead,
# and say why. The old code blocked here, and told the agent to fix it with an
# env prefix the agent cannot use.
NOPY=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$NOPY/python3"
chmod +x "$NOPY/python3"
tp() { # command, expected rc, with a python3 that fails
  rc=$(mk "$1" "$PWD" | PATH="$NOPY:$PATH" perl -e 'alarm 10; exec @ARGV' bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
  if [ "$rc" != "$2" ]; then
    printf 'FAIL (no python3) want=%s got=%s : %s\n' "$2" "$rc" "$(printf '%s' "$1" | tr '\n' '~')"
    fails=$((fails + 1))
  fi
}
tp "$V"                                  0  # stands down rather than dead-ending
tp "git merge-base HEAD origin/main"     0
out=$(mk "$V" "$PWD" | PATH="$NOPY:$PATH" bash "$G/pre-pr-gate.sh" 2>&1 >/dev/null)
case "$out" in
  *"python3 is unavailable"*) ;;
  *) printf 'FAIL degraded stand-down did not name the cause: %s\n' "$out"; fails=$((fails + 1)) ;;
esac
rm -rf "$NOPY"


# --- the stamp half -----------------------------------------------------
# The gate is only as honest as its evidence. When the marker was written by
# the skill, a hunt driven straight through the MCP tools left none, and the
# gate blocked work that HAD been hunted (owner report, 2026-08-11) — which is
# how a control teaches people to disarm it. These rows pin the stamp to the
# tool calls themselves.
post() { # tool, done?, review id, envelope -> runs stamp-hunt.sh
  # The payload is the WORKING DIFF's bytes, exactly what a client sends: the
  # whole point of payload-based stamping is that sha256(sent bytes) equals the
  # diff-id a gate computes locally. A file's raw content hashes to something
  # no gate ever computes and turns every marker row into noise.
  #
  # The ENVELOPE is a parameter because it is not ours to choose: the client
  # decides how a tool response reaches a hook, and reading only one spelling of
  # it is what let a clean hunt go unrecorded.
  OMB_DIFF=$(git diff "$(ohmybug_base)" 2>/dev/null) \
  python3 -c "import json,os,sys;
body={'review_id':sys.argv[4],'status':'done' if sys.argv[2]=='1' else 'running'}
parts=[{'type':'text','text':json.dumps(body)}]
resp={'content':parts} if sys.argv[5]=='content' else (
      parts if sys.argv[5]=='list' else (
      body if sys.argv[5]=='raw' else (
      parts[0] if sys.argv[5]=='part' else (
      'ohmybug: upstream said no' if sys.argv[5]=='garbage' else json.dumps(body)))))
print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__'+sys.argv[1],
    'tool_input':{'review_id':sys.argv[4],'diff':os.environ.get('OMB_DIFF','')},
    'tool_response':resp,
    'cwd':sys.argv[3]}))" "$1" "$2" "$PWD" "${3:-rev_x}" "${4:-content}" \
  | bash "$G/stamp-hunt.sh"
}
. "$G/diff-id.sh"
M=$(ohmybug_marker_path)
# Every piece of state a row can leave behind, in one place. The `.pending`
# directory hangs off the HUNT dir, not off the marker path, so the old
# three-path incantation left live pending records between sections — and a
# stale one makes the next section read as "a hunt is running here".
reset_state() { rm -rf "$M" "$M.pending" "$(ohmybug_hunt_dir)" "$(ohmybug_hunt_dir).pending"; }
s() { # label, expected marker content ('' = absent)
  got=$([ -f "$M" ] && cat "$M")
  if [ "$got" != "$2" ]; then
    printf 'FAIL stamp %s: want=%s got=%s\n' "$1" "${2:-<none>}" "${got:-<none>}"
    fails=$((fails + 1))
  fi
}

reset_state
ID=$(ohmybug_diff_id)
if [ -z "$ID" ]; then
  echo "stamp: the scratch file did not produce a working diff — is origin/HEAD resolvable here?" >&2
  fails=$((fails + 1))
else
  post get_findings 0; s "still running writes nothing" ""
  post submit_review 0; s "submit alone does not authorise" ""
  post get_findings 1; s "done promotes the submitted diff" "$ID"
  t "$V" 0                                    # ...and the gate now lets it through
  # ...in EVERY envelope a client may hand the hook. A clean hunt may have no
  # later confirm call, so this `done` response is what promotes it.
  for shape in list raw string part; do
    reset_state
    post submit_review 0 rev_x "$shape"
    post get_findings 1 rev_x "$shape"; s "done promotes it in the $shape envelope" "$ID"
  done
  # A response handed over as PLAIN PROSE — an error sentence, a proxy's text.
  # Reading a status out of a string means PARSING it, and that parse is the one
  # place in this hook that can raise. A raise here is not "no status": the whole
  # python block runs under `|| exit 0`, so it aborts the hook before the tool
  # name is read. On confirm_findings that is unrecoverable — the call is
  # one-shot, it promotes without asking for a status, and there is no later poll
  # to retry it, so the hunt the user paid for AND confirmed is lost and the gate
  # blocks it as never hunted.
  reset_state
  post submit_review 0 rev_x content
  post confirm_findings 0 rev_x garbage; s "prose in place of JSON does not lose a confirmed hunt" "$ID"
  # Fixes written WHILE the review runs were never hunted. The marker must
  # name the diff that was sent, not whatever the tree looks like when the
  # answer arrives — otherwise the gate blesses code the hunt never saw.
  reset_state
  post submit_review 0
  # The scratch file, never a tracked one. This row used to edit README.md and
  # put it back with `git checkout --`, which DELETES whatever the person running
  # the suite had not committed there — and, more quietly, made the whole stamp
  # half fail on a dirty tree: the restore changed the working diff out from
  # under the id captured above, so every later row compared against a hash the
  # tree no longer had.
  printf 'edited while the review was running\n' >> "$SCRATCH"
  post get_findings 1; s "done stamps the SENT diff, not the current one" "$ID"
  t "$V" 2
  printf 'gate-test scratch %s\n' "$$" > "$SCRATCH"
  rm -rf "$M" "$(ohmybug_hunt_dir)"
  # The other side of the worktree fix (plugin#2): with no pending for this
  # review, confirm must NOT bless whatever tree this session happens to sit
  # in — in a worktree flow that cwd may be a different checkout entirely.
  # The owning session promotes the recorded payload; this one records nothing.
  post confirm_findings 0; s "confirm without a pending stamps nothing" ""
  t "$V" 2
fi

# --- block -> warn: a refused hunt must not dead-end the merge ---------------
# In auto mode the permission classifier refuses these tools by design, and the
# gate's own advice (an env prefix on the merge) is a control-disabling prefix
# the classifier refuses too. That combination has no exit: the merge is blocked
# forever and the plugin gets uninstalled. So a recorded ATTEMPT downgrades the
# block to a warning — and only for the diff that was attempted.
# No tool_response in the payload — that, and not an argument in hooks.json, is
# what tells the script a PreToolUse fired. Wiring both events to the same
# command line is one thing that cannot be half-installed.
pre() { # tool -> what the PreToolUse hook sees, before anyone allows or refuses
  OMB_DIFF=$(git diff "$(ohmybug_base)" 2>/dev/null) \
  python3 -c "import json,os,sys;print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__'+sys.argv[1],
    'tool_input':{'diff':os.environ.get('OMB_DIFF','')},
    'cwd':sys.argv[2]}))" "$1" "$PWD" | bash "$G/stamp-hunt.sh"
}
reset_state
if [ -n "$ID" ]; then
  t "$V" 2                        # never asked at all: still a block
  pre submit_review
  t "$V" 0                        # asked, never finished: warn, let it through
  # stdout, not stderr: on an exit-0 PreToolUse the stdout copy is the one the
  # transcript surfaces, and every other assertion here captures stderr only —
  # so deleting the stdout echo was free.
  out=$(mk "$V" "$PWD" | bash "$G/pre-pr-gate.sh" 2>/dev/null)
  case "$out" in
    *"no findings came back"*) ;;
    *) printf 'FAIL the warn-through said nothing on stdout: %s\n' "$out"
       fails=$((fails + 1)) ;;
  esac
  out=$(mk "$V" "$PWD" | bash "$G/pre-pr-gate.sh" 2>&1 >/dev/null)
  case "$out" in
    *"no findings came back"*) ;;
    *) printf 'FAIL warn message did not say what the record actually proves: %s\n' "$out"
       fails=$((fails + 1)) ;;
  esac
  # ...and the downgrade only applies where the hunt could not have run. With an
  # allow rule in the user's own settings the tools work, so an unfinished hunt
  # means the hunt is the thing to finish — otherwise the warn is a switch the
  # agent flips for itself by making one call it can be sure will fail.
  mkdir -p "$HOME/.claude" "$CLAUDE_PROJECT_DIR/.claude"
  RULE='{"permissions":{"allow":["mcp__plugin_bughunter_ohmybug__submit_review"]}}'
  printf '%s\n' "$RULE" > "$HOME/.claude/settings.json"
  t "$V" 2
  rm -f "$HOME/.claude/settings.json"
  t "$V" 0
  # The project half of the lookup is where /permissions writes by default, so a
  # team that granted these tools repo-wide must get the block, not the warning.
  # Sandboxing that path without asserting it only sterilised the branch.
  printf '%s\n' "$RULE" > "$CLAUDE_PROJECT_DIR/.claude/settings.json"
  t "$V" 2
  rm -f "$CLAUDE_PROJECT_DIR/.claude/settings.json"
  # A DENY is not an allow. Reading the settings as text (or scanning the whole
  # permissions object) would read a deliberate refusal as permission, and the
  # gate would then block forever on a hunt nobody in that session can run.
  printf '{"permissions":{"deny":["mcp__plugin_bughunter_ohmybug__submit_review"]}}\n' > "$HOME/.claude/settings.json"
  t "$V" 0
  rm -f "$HOME/.claude/settings.json"
  t "$V" 0
  # The warning covers the diff that was attempted, not whatever came after it.
  printf 'written after the attempt\n' >> "$SCRATCH"
  t "$V" 2
  printf 'gate-test scratch %s\n' "$$" > "$SCRATCH"
  reset_state

  # An attempt is an OFFER OF A DIFF. A get_findings poll offers nothing — it
  # names a review id — so if it could record one, a single call with an invented
  # id would disarm the gate, and every poll would bless whatever the tree looked
  # like at that moment (including fixes written while the review ran).
  pre get_findings
  t "$V" 2
  reset_state

  # Attempts expire. Otherwise one refused call authorises every future merge of
  # these bytes on this machine, and a revert that recreates them inherits it.
  pre submit_review
  find "$(ohmybug_hunt_dir)" -name 'attempt:*' -exec touch -t 202001010000 {} \; 2>/dev/null
  t "$V" 2
  reset_state

  # A PostToolUse proves the call was PERMITTED, so the attempt it left behind
  # is spent. Without that, a permitted review that later fails decayed into
  # "the environment refused the hunt" — and waved the merge through.
  pre submit_review
  post submit_review 0
  python3 -c "import json,sys;print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__get_findings',
    'tool_input':{'review_id':'rev_x'},
    'tool_response':{'content':[{'type':'text','text':json.dumps(
       {'review_id':'rev_x','status':'failed'})}]},
    'cwd':sys.argv[1]}))" "$PWD" | bash "$G/stamp-hunt.sh"
  t "$V" 2
  reset_state

  # A done review whose FINDINGS merely quote the word failed is still a done
  # review. Grepping the flattened response for it threw the hunt away — and
  # hunting this repository produces exactly that prose.
  # The raw-object response shape, which is the one that carries the prose at a
  # single level of escaping — exactly what a hunt of this repository returns.
  post submit_review 0
  python3 -c "import json,sys;print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__get_findings',
    'tool_input':{'review_id':'rev_x'},
    'tool_response':{'review_id':'rev_x','status':'done','findings':[
       {'failure_scenario':'a response whose text contains \"status\": \"failed\" anywhere'}]},
    'cwd':sys.argv[1]}))" "$PWD" | bash "$G/stamp-hunt.sh"
  t "$V" 0
  reset_state

  # The positional field protocol carries three free-text fields before the two
  # flags, and review_id is model-authored: one newline in it made a PostToolUse
  # read as a PreToolUse, so the finished review could never promote.
  OMB_DIFF=$(git diff "$(ohmybug_base)" 2>/dev/null) \
  python3 -c "import json,os,sys;print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__submit_review',
    'tool_input':{'review_id':'rev_nl\n1','diff':os.environ.get('OMB_DIFF','')},
    'tool_response':{'review_id':'rev_nl','status':'running'},
    'cwd':sys.argv[1]}))" "$PWD" | bash "$G/stamp-hunt.sh"
  [ -n "$(ls -A "$(ohmybug_hunt_dir).pending" 2>/dev/null)" ] || {
    printf 'FAIL a newline in review_id shifted the fields: no pending record\n'
    fails=$((fails + 1)); }
  reset_state

  # A review that ends `failed` is over, and its pending record must not keep
  # saying "a hunt is RUNNING" — that is a permanent block whose instruction
  # (poll until done) can never come true.
  post submit_review 0
  python3 -c "import json,sys;print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__get_findings',
    'tool_input':{'review_id':'rev_x'},
    'tool_response':{'content':[{'type':'text','text':json.dumps(
       {'review_id':'rev_x','status':'failed'})}]},
    'cwd':sys.argv[1]}))" "$PWD" | bash "$G/stamp-hunt.sh"
  out=$(mk "$V" "$PWD" | bash "$G/pre-pr-gate.sh" 2>&1 >/dev/null)
  case "$out" in
    *RUNNING*) printf 'FAIL a failed review still reads as a running hunt\n'; fails=$((fails + 1)) ;;
  esac
  reset_state

  # A submit that WAS allowed and is still running is not a refusal. Merging on
  # its attempt record would mean merging ahead of the findings it will return.
  post submit_review 0
  t "$V" 2
  out=$(mk "$V" "$PWD" | bash "$G/pre-pr-gate.sh" 2>&1 >/dev/null)
  case "$out" in
    *"RUNNING"*) ;;
    *) printf 'FAIL in-flight hunt not named as running: %s\n' "$out"; fails=$((fails + 1)) ;;
  esac
  # ...and when it finishes, the offer is spent: no "requested but never
  # finished" about a review that finished, and no warn-through for later edits.
  post get_findings 1
  t "$V" 0
  printf 'written after the finished hunt\n' >> "$SCRATCH"
  t "$V" 2
  printf 'gate-test scratch %s\n' "$$" > "$SCRATCH"
  reset_state

  # The no-payload flow: identity is the commit, and `meta.ref` is written by the
  # model. Record it only when it names the commit this tree is actually on, and
  # honour it only while nothing is uncommitted on top of that commit — the same
  # condition the finished-hunt path applies to the same identity.
  npre() { # meta.ref value -> PreToolUse submit_review carrying no diff
    python3 -c "import json,sys;print(json.dumps({
      'tool_name':'mcp__plugin_bughunter_ohmybug__submit_review',
      'tool_input':{'diff':'','meta':{'repo':'x/y','ref':sys.argv[1]}},
      'cwd':sys.argv[2]}))" "$1" "$PWD" | bash "$G/stamp-hunt.sh"
  }
  HEAD_NOW=$(git rev-parse HEAD)
  # The offer is filed under the RESOLVED sha, so it has to be cleared under the
  # resolved sha too: clearing under the raw ref removed nothing, and the stale
  # attempt then told the gate the environment had refused a hunt it permitted.
  reset_state
  npre "$(git rev-parse --short HEAD)"
  python3 -c "import json,sys;print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__submit_review',
    'tool_input':{'review_id':'rev_ref','diff':'','meta':{'repo':'x/y','ref':sys.argv[1]}},
    'tool_response':{'review_id':'rev_ref','status':'running'},
    'cwd':sys.argv[2]}))" "$(git rev-parse --short HEAD)" "$PWD" | bash "$G/stamp-hunt.sh"
  ohmybug_attempted "ref:$HEAD_NOW" && {
    printf 'FAIL a permitted submit left its attempt record standing\n'; fails=$((fails + 1)); }
  reset_state
  npre "some-branch-name"
  # Assert on the key the bogus ref would have written, not on HEAD's key: a
  # lookup for HEAD is false either way, so it passes while recording anything.
  ohmybug_attempted "ref:some-branch-name" && { printf 'FAIL a ref that is not this commit still recorded an attempt\n'; fails=$((fails + 1)); }
  npre "$HEAD_NOW"
  ohmybug_attempted "ref:$HEAD_NOW" || { printf 'FAIL the no-payload attempt was not recorded\n'; fails=$((fails + 1)); }
  # ...and so is any spelling of it. The preferred flow sends meta.ref, and a
  # model that sends the branch name or a short sha is offering the same commit;
  # matching the full sha as a STRING made that offer vanish, leaving the merge
  # blocked with nothing the session could do about it.
  reset_state
  npre "$(git rev-parse --short HEAD)"
  ohmybug_attempted "ref:$HEAD_NOW" || { printf 'FAIL a short sha for this very commit recorded nothing\n'; fails=$((fails + 1)); }
  t "$V" 2   # the tree is dirty, so a commit-keyed attempt says nothing about it
  reset_state
fi

# --- which event fired is key PRESENCE, not truthiness ------------------------
# An errored or empty response is still a PostToolUse. Reading it as "no
# response" would file a live submit as a mere attempt: the pending record is
# never written, so the finished review never promotes, and a hunt the user paid
# for ends up reported as "requested, never finished".
reset_state
OMB_DIFF=$(git diff "$(ohmybug_base)" 2>/dev/null) \
python3 -c "import json,os,sys;print(json.dumps({
  'tool_name':'mcp__plugin_bughunter_ohmybug__submit_review',
  'tool_input':{'review_id':'rev_empty','diff':os.environ.get('OMB_DIFF','')},
  'tool_response':{},
  'cwd':sys.argv[1]}))" "$PWD" | bash "$G/stamp-hunt.sh"
[ -s "$(ohmybug_hunt_dir).pending/rev_empty" ] || {
  printf 'FAIL an empty tool_response was read as PreToolUse: no pending record written\n'
  fails=$((fails + 1)); }
reset_state

# --- the block text speaks to one addressee per line --------------------------
# The old single paragraph told the AGENT to prefix the merge with an env var it
# cannot use; it tried, failed, and carried the prefix onto unrelated commands.
if [ -n "$ID" ]; then
  out=$(mk "$V" "$PWD" | bash "$G/pre-pr-gate.sh" 2>&1 >/dev/null)
  case "$out" in
    *"(operator): to merge without a hunt"*) ;;
    *) printf 'FAIL block text gives the human no way out: %s\n' "$out"
       fails=$((fails + 1)) ;;
  esac
  case "$out" in
    *"never carry a prefix onto another command"*) ;;
    *) printf 'FAIL block text does not forbid prefix carry-over: %s\n' "$out"
       fails=$((fails + 1)) ;;
  esac
fi

# --- what a hunt can speak about ----------------------------------------------
# The gate keyed on a hash of the WHOLE diff, so a README edit after the hunt
# read as unhunted code: another review, another 15 minutes, to look at prose
# nobody asked the reviewers about. And a docs-only branch could not land at all
# without paying for a hunt of it.
if [ -n "$ID" ]; then
  reset_state
  post submit_review 0
  post get_findings 1
  t "$V" 0                                   # hunted, as before
  # Prose, tests and skills after the hunt: still hunted.
  DOCFILE=".ohmybug-gate-test-scratch.md"
  TESTFILE="test/.ohmybug-gate-test-scratch.js"
  mkdir -p test
  printf 'a README edit after the hunt\n' > "$DOCFILE"
  printf 'it("still counts as a test", () => {})\n' > "$TESTFILE"
  git add -N "$DOCFILE" "$TESTFILE" 2>/dev/null
  t "$V" 0
  out=$(mk "$V" "$PWD" | bash "$G/pre-pr-gate.sh" 2>&1 >/dev/null)
  case "$out" in
    *"documentation, tests or skills"*) ;;
    *) printf 'FAIL the docs-only pass did not say why: %s\n' "$out"; fails=$((fails + 1)) ;;
  esac
  # ...but one line of real code is a different diff again.
  printf 'code written after the hunt\n' >> "$SCRATCH"
  t "$V" 2
  printf 'gate-test scratch %s\n' "$$" > "$SCRATCH"
  # A file that merely has "docs" or "test" inside its NAME is code.
  CODEFILE="src/docs-loader.js"
  mkdir -p src
  printf 'export const load = () => 1\n' > "$CODEFILE"
  git add -N "$CODEFILE" 2>/dev/null
  t "$V" 2
  # `rmdir`, never `rm -rf`: this runs in the maintainer's real checkout, and a
  # top-level src/ that was already there is not this suite's to delete. Same
  # rule the header states after this file once destroyed uncommitted work.
  git reset -q -- "$CODEFILE" 2>/dev/null; rm -f "$CODEFILE"; rmdir src 2>/dev/null
  # The strict mode is still there for a repo whose prose IS behaviour.
  rc=$(mk "$V" "$PWD" | OHMYBUG_HUNT_ALL=1 bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
  [ "$rc" = 2 ] || { printf 'FAIL OHMYBUG_HUNT_ALL did not restore the strict gate (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
  git reset -q -- "$DOCFILE" "$TESTFILE" 2>/dev/null
  rm -f "$DOCFILE" "$TESTFILE"; rmdir test 2>/dev/null
  reset_state
fi

# A branch that changes nothing but prose has nothing for a hunt to look at, so
# it must land without one — that case used to cost a review.
#
# In a throwaway repository, not this one: the suite runs inside a checkout that
# already carries the maintainer's own edits, so "the only change is a .md" is
# not something this working tree can honestly demonstrate.
DOCREPO=$(mktemp -d)/repo
mkdir -p "$DOCREPO" && (
  cd "$DOCREPO" || exit 1
  git init -q .
  git config user.email t@t; git config user.name t
  printf 'base\n' > code.js && git add code.js
  git commit -qm base
  git branch -qM main
  git remote add origin .
  git update-ref refs/remotes/origin/main HEAD
  printf 'a documentation change, and nothing else\n' > README.md
  git add -N README.md
)
rc=$(mk "$V" "$DOCREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL a docs-only branch still needed a hunt (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
out=$(mk "$V" "$DOCREPO" | bash "$G/pre-pr-gate.sh" 2>&1 >/dev/null)
case "$out" in
  *"nothing to hunt"*) ;;
  *) printf 'FAIL a docs-only diff was not named as such: %s\n' "$out"; fails=$((fails + 1)) ;;
esac
# ...and one line of code in the same branch brings the gate straight back.
printf 'export const two = 2\n' >> "$DOCREPO/code.js"
rc=$(mk "$V" "$DOCREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL code alongside the docs did not re-arm the gate (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$DOCREPO")"

# The same question, asked from a subdirectory. `git diff -- .` resolves against
# the CURRENT directory, so the significant diff came out empty in any package
# below the root — and empty is the answer that ALLOWS the merge. The gate cds
# into the session cwd before it asks, and an agent session sits wherever the
# last `cd` left it.
SUBREPO=$(mktemp -d)/repo
mkdir -p "$SUBREPO" && (
  cd "$SUBREPO" || exit 1
  git init -q .
  git config user.email t@t; git config user.name t
  mkdir -p api service
  printf 'base\n' > api/code.js
  printf 'base\n' > service/code.js
  git add api service && git commit -qm base
  git branch -qM main
  git remote add origin .
  git update-ref refs/remotes/origin/main HEAD
  # Unhunted code, in a package the merge command is NOT standing in.
  printf 'export const risky = 1\n' >> service/code.js
)
rc=$(mk "$V" "$SUBREPO/api" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL merging from a subdirectory hid unhunted code (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$SUBREPO")"

# A test that IS a control is not skippable, though a test OF behaviour is.
#
# Measured case (exply-dev/OhMyBug#451): a hunt found that the verdict
# enumeration test promised to cover every branch and counted its own array
# instead. The fix for that finding lives in that test file — and `sig:` skipped
# it, so the gate answered "hunt: current" for bytes no hunt had seen. The cheap
# path was blind to exactly the class of fix a reviewer asks for after finding a
# hollow control.
CTLREPO=$(mktemp -d)/repo
mkdir -p "$CTLREPO" && (
  cd "$CTLREPO" || exit 1
  git init -q .
  git config user.email t@t; git config user.name t
  mkdir -p api/test
  printf 'base\n' > api/code.js
  printf 'ordinary\n' > api/test/behaviour.test.ts
  printf 'control\n' > api/test/verdict.test.ts
  git add api && git commit -qm base
  git branch -qM main
  git remote add origin .
  git update-ref refs/remotes/origin/main HEAD
  # The control itself, edited.
  printf 'control changed\n' > api/test/verdict.test.ts
)
rc=$(mk "$V" "$CTLREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL a change to a control test skipped review (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
# ...and the other direction, which is the expensive one to get wrong: an
# ordinary test must still cost nothing. A gate that demands a paid hunt for
# every test edit is a gate people learn to walk around.
(cd "$CTLREPO" && git checkout -q -- api/test/verdict.test.ts && printf 'ordinary changed\n' > api/test/behaviour.test.ts)
rc=$(mk "$V" "$CTLREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL an ordinary test edit demanded a paid hunt (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$CTLREPO")"

# `.claude/` is prose-shaped and deliberately in scope: its settings decide
# whether this gate stands down at all, and its hooks are commands that run.
CLREPO=$(mktemp -d)/repo
mkdir -p "$CLREPO" && (
  cd "$CLREPO" || exit 1
  git init -q .
  git config user.email t@t; git config user.name t
  printf 'base\n' > code.js
  mkdir -p .claude
  printf '{"permissions":{"allow":["mcp__plugin_bughunter_ohmybug__submit_review"]}}\n' > .claude/settings.json
  git add code.js .claude && git commit -qm base
  git branch -qM main
  git remote add origin .
  git update-ref refs/remotes/origin/main HEAD
  # The only change: the rule that decides whether the gate can stand down.
  printf '{"permissions":{}}\n' > .claude/settings.json
)
rc=$(mk "$V" "$CLREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL a change to the gate own permission input skipped review (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$CLREPO")"

# ...and a test tree that is not at the repository root is still a test tree.
NESTREPO=$(mktemp -d)/repo
mkdir -p "$NESTREPO" && (
  cd "$NESTREPO" || exit 1
  git init -q .
  git config user.email t@t; git config user.name t
  mkdir -p packages/api/tests
  printf 'base\n' > packages/api/code.js
  git add packages && git commit -qm base
  git branch -qM main
  git remote add origin .
  git update-ref refs/remotes/origin/main HEAD
  printf 'def test_auth(): pass\n' > packages/api/tests/test_auth.py
  git add -N packages/api/tests/test_auth.py
)
rc=$(mk "$V" "$NESTREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL a nested tests/ directory demanded a paid hunt (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$NESTREPO")"
reset_state

# --- the pending record names the CALL, not the directory the hook stood in ---
# submit_review used to file three ids: the bytes actually sent, plus the
# working diff and its significant sibling hashed from the hook's cwd — a
# client-supplied field. The promote loop copies every line into the set that
# authorises a merge, so a submit of ONE dirty file blessed the others beside
# it, and a submit reported from a session standing in another repository
# blessed whatever that directory held. Every row builds its own throwaway
# repository: the main fixture is deliberately dirty, so "three files dirty,
# one sent" and "clean tree" cannot be shown honestly there. post() is no use
# either — it hardwires the payload to the WHOLE working diff, which is
# exactly the equality these rows must be free to break.
mkrepo() { # dir -> one commit on main, origin/main at HEAD, clean tree
  mkdir -p "$1" && (
    cd "$1" || exit 1
    git init -q .
    git config user.email t@t; git config user.name t
    # The path goes into the blob so no two of these repositories ever share
    # a commit sha: a shared sha would let a ref of one resolve in the other,
    # and the cross-repo rows would then prove nothing.
    printf 'base %s\n' "$1" > a.ts
    printf 'base\n' > b.ts
    printf 'base\n' > c.ts
    git add a.ts b.ts c.ts && git commit -qm base
    git branch -qM main
    git remote add origin .
    git update-ref refs/remotes/origin/main HEAD
  )
}
ppost() { # tool, status, cwd, diff-text (or @path: file read verbatim), review-id, [meta-ref]
  # The @path spelling exists because $( ) eats a trailing newline, and one row
  # must send the verbatim bytes of `git diff` — newline included.
  python3 -c "import json,sys
d = sys.argv[4]
d = open(d[1:]).read() if d.startswith('@') else d
print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__'+sys.argv[1],
    'tool_input':{'review_id':sys.argv[5],'diff':d,
      'meta':({'repo':'x/y','ref':sys.argv[6]} if len(sys.argv)>6 else {})},
    'tool_response':{'content':[{'type':'text','text':json.dumps(
       {'review_id':sys.argv[5],'status':sys.argv[2]})}]},
    'cwd':sys.argv[3]}))" "$@" | bash "$G/stamp-hunt.sh"
}

# A payload of one named file — the shape the skill itself prescribes for
# hunting only the unseen fix — must not bless the two dirty files beside it.
# The oracle is what this fixture chose to SEND, never a re-run of the id
# helper the hook itself uses.
PREPO=$(mktemp -d)/repo
mkrepo "$PREPO"
printf 'dirty\n' >> "$PREPO/a.ts"
printf 'dirty\n' >> "$PREPO/b.ts"
printf 'dirty\n' >> "$PREPO/c.ts"
PART_DIFF=$(git -C "$PREPO" diff "$(cd "$PREPO" && ohmybug_base)" -- a.ts)
[ -n "$PART_DIFF" ] || { printf 'FAIL partial-payload fixture: no diff for a.ts\n'; fails=$((fails + 1)); }
ppost submit_review running "$PREPO" "$PART_DIFF" rev_part >/dev/null 2>&1
ppost get_findings done "$PREPO" "$PART_DIFF" rev_part
rc=$(mk "$V" "$PREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL a one-file payload blessed the whole dirty tree (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
# ...and the way OUT of that block is a hunt of the FULL diff. The subset
# hunt's record stays dead weight by design — the reviewers never saw the
# sibling files — so the incremental flow ends in one more full-diff review,
# never in a merge. A decision, not an accident: this row is the contract.
FULL_DIFF=$(git -C "$PREPO" diff "$(cd "$PREPO" && ohmybug_base)")
ppost submit_review running "$PREPO" "$FULL_DIFF" rev_part2
ppost get_findings done "$PREPO" "$FULL_DIFF" rev_part2
rc=$(mk "$V" "$PREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL a full-diff re-hunt did not lift the partial-payload block (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$PREPO")"

# A submit that carried NO bytes says nothing about this tree: the no-payload
# flow's identity is its ref, and the dirty file beside it was never offered
# to anybody.
ZREPO=$(mktemp -d)/repo
mkrepo "$ZREPO"
printf 'dirty\n' >> "$ZREPO/a.ts"
ppost submit_review running "$ZREPO" "" rev_zero "$(git -C "$ZREPO" rev-parse HEAD)"
ppost get_findings done "$ZREPO" "" rev_zero "$(git -C "$ZREPO" rev-parse HEAD)"
rc=$(mk "$V" "$ZREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL a zero-payload submit blessed the dirty tree it stood in (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$ZREPO")"

# A hunt of repository B, reported from a session whose cwd is repository A,
# must leave no mark on A. Both sides are asserted from INSIDE A — the id
# helpers key on cwd, so asking from anywhere else answers about the wrong
# repository and goes green on nothing. And a ref naming a commit A is not AT
# (an ancestor) must vanish too: the resolved-equals-HEAD rule the PreToolUse
# branch already applies. That assertion is the one that stays red if the
# HEAD-equality half of the guard is ever dropped.
AREPO=$(mktemp -d)/repo
BREPO=$(mktemp -d)/repo
mkrepo "$AREPO"
mkrepo "$BREPO"
ANC=$(git -C "$AREPO" rev-parse HEAD)
(
  cd "$AREPO" || exit 1
  printf 'second\n' >> b.ts
  git add b.ts && git commit -qm second
  git update-ref refs/remotes/origin/main HEAD
)
printf 'never reviewed\n' >> "$AREPO/a.ts"
# The one diagnostic that explains an unrecordable hunt must actually fire:
# a silent non-recording is indistinguishable from a hunt that never ran.
out=$(ppost submit_review running "$AREPO" "" rev_cross "$(git -C "$BREPO" rev-parse HEAD)" 2>&1 >/dev/null); rc=$?
case "$out" in
  *"cannot be recorded"*) ;;
  *) printf 'FAIL a foreign-ref submit did not say it recorded nothing: %s\n' "$out"; fails=$((fails + 1)) ;;
esac
# ...and says it where the AGENT reads it. At exit 0 a PostToolUse hook's output
# reaches the transcript and not the model, so this diagnostic existed for a
# year and was never once seen by the party that could act on it.
[ "$rc" = 2 ] || { printf 'FAIL the unrecordable submit told only the transcript (rc=%s)\n' "$rc"
                   fails=$((fails + 1)); }
ppost get_findings done "$AREPO" "" rev_cross "$(git -C "$BREPO" rev-parse HEAD)"
ppost submit_review running "$AREPO" "" rev_anc "$ANC" >/dev/null 2>&1
ppost get_findings done "$AREPO" "" rev_anc "$ANC"
AID=$(cd "$AREPO" && ohmybug_diff_id)
[ -n "$AID" ] || { printf 'FAIL cross-repo fixture: repo A produced no working diff\n'; fails=$((fails + 1)); }
(cd "$AREPO" && ohmybug_hunted "$AID") && { printf 'FAIL a hunt of another repository authorised this one\n'; fails=$((fails + 1)); }
(cd "$AREPO" && ohmybug_hunted "ref:$ANC") && { printf 'FAIL a commit this checkout is not AT was promoted\n'; fails=$((fails + 1)); }
rc=$(mk "$V" "$AREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL cross-repo: the gate allowed the unreviewed tree (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$AREPO")" "$(dirname "$BREPO")"

# meta.ref arrives in whatever spelling the model typed — and a SYMBOLIC
# spelling must never become an authorising record. The server resolves the
# NAME against the remote while this hook would resolve it against this
# clone: one unpushed commit apart, and the record authorises bytes no
# reviewer ever saw. Only a sha spelling — the one that pins the same commit
# everywhere — records; `HEAD` is the sharpest wrong spelling, since it
# always equals this checkout's tip while telling the server nothing.
RREPO=$(mktemp -d)/repo
mkrepo "$RREPO"
RHEAD=$(git -C "$RREPO" rev-parse HEAD)
ppost submit_review running "$RREPO" "" rev_branch main >/dev/null 2>&1
ppost get_findings done "$RREPO" "" rev_branch main
(cd "$RREPO" && ohmybug_hunted "ref:$RHEAD") && {
  printf 'FAIL a branch-name ref was locally resolved into an authorising record\n'; fails=$((fails + 1)); }
ppost submit_review running "$RREPO" "" rev_head HEAD >/dev/null 2>&1
ppost get_findings done "$RREPO" "" rev_head HEAD
(cd "$RREPO" && ohmybug_hunted "ref:$RHEAD") && {
  printf 'FAIL a HEAD-spelled ref was locally resolved into an authorising record\n'; fails=$((fails + 1)); }
# The offer record (PreToolUse) obeys the same spelling rule — the two
# branches share one helper, and this is the row that pins the Pre twin.
python3 -c "import json,sys;print(json.dumps({
  'tool_name':'mcp__plugin_bughunter_ohmybug__submit_review',
  'tool_input':{'diff':'','meta':{'repo':'x/y','ref':'main'}},
  'cwd':sys.argv[1]}))" "$RREPO" | bash "$G/stamp-hunt.sh"
(cd "$RREPO" && ohmybug_attempted "ref:$RHEAD") && {
  printf 'FAIL a branch-name ref recorded an offer under the resolved sha\n'; fails=$((fails + 1)); }
# ...while the sha spelling of the very same commit records fine.
ppost submit_review running "$RREPO" "" rev_sha "$RHEAD"
ppost get_findings done "$RREPO" "" rev_sha "$RHEAD"
(cd "$RREPO" && ohmybug_hunted "ref:$RHEAD") || {
  printf 'FAIL a full-sha ref did not record\n'; fails=$((fails + 1)); }
rm -rf "$(dirname "$RREPO")"

# A payload plus a HEAD sha in meta.ref must not bless the commit: with bytes
# in the call the server reviewed THOSE bytes, whatever meta.ref claims. On a
# committed, clean tree the ref record is exactly what the gate would honour —
# one junk diff away from a free pass. The ref is the call's identity only
# when the call carried no bytes; and a payload that matched nothing must say
# so at submit time, not surface at merge time as "never hunted".
QREPO=$(mktemp -d)/repo
mkrepo "$QREPO"
(
  cd "$QREPO" || exit 1
  printf 'committed work\n' >> a.ts
  git add a.ts && git commit -qm work
)
QHEAD=$(git -C "$QREPO" rev-parse HEAD)
out=$(ppost submit_review running "$QREPO" "junk bytes, not this tree" rev_pref "$QHEAD" 2>/dev/null)
case "$out" in
  *"will not recognise this tree as hunted"*) ;;
  *) printf 'FAIL a payload that matches nothing was filed silently on stdout: %s\n' "$out"; fails=$((fails + 1)) ;;
esac
ppost get_findings done "$QREPO" "" rev_pref
rc=$(mk "$V" "$QREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL a junk payload plus a HEAD sha blessed the commit (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$QREPO")"

# The no-payload hunt is often driven from a session standing in the MAIN
# checkout while the reviewed commit and the merge live in a worktree — the
# ref-identity twin of the payload worktree rows below. A sha-spelled ref
# naming a sibling worktree's HEAD is a commit this repository IS standing
# on; requiring the recording cwd's OWN head re-broke this flow (a paid,
# finished hunt recorded nowhere, then a hard block on reviewed work). This
# row also walks the gate's ref-honouring ALLOW path end to end — it goes red
# if that allow block is ever deleted.
WREPO=$(mktemp -d)/repo
mkrepo "$WREPO"
if git -C "$WREPO" worktree add -q -b feature "$WREPO.wt" HEAD 2>/dev/null; then
  printf 'committed work\n' >> "$WREPO.wt/a.ts"
  git -C "$WREPO.wt" add a.ts 2>/dev/null
  git -C "$WREPO.wt" -c user.email=t@t -c user.name=t commit -qm work 2>/dev/null
  WTSHA=$(git -C "$WREPO.wt" rev-parse HEAD)
  # The offer first: the PreToolUse twin obeys the same worktree rule, and a
  # refused submit in this flow must leave the warn-through a key to find.
  python3 -c "import json,sys;print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__submit_review',
    'tool_input':{'diff':'','meta':{'repo':'x/y','ref':sys.argv[1]}},
    'cwd':sys.argv[2]}))" "$WTSHA" "$WREPO" | bash "$G/stamp-hunt.sh"
  (cd "$WREPO" && ohmybug_attempted "ref:$WTSHA") || {
    printf 'FAIL an offer of a sibling worktree HEAD recorded nothing\n'; fails=$((fails + 1)); }
  ppost submit_review running "$WREPO" "" rev_wtref "$WTSHA"
  ppost get_findings done "$WREPO" "" rev_wtref "$WTSHA"
  rc=$(mk "$V" "$WREPO.wt" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
  [ "$rc" = 0 ] || { printf 'FAIL a no-payload hunt recorded from the main checkout is invisible to the worktree merge (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
  git -C "$WREPO" worktree remove --force "$WREPO.wt" 2>/dev/null
else
  printf 'FAIL could not create a worktree for the cross-checkout ref row\n'; fails=$((fails + 1))
fi
rm -rf "$(dirname "$WREPO")"

# The warn-through must also be reachable through the ref identity: an offer
# of this commit that the environment refused, on a clean tree at that commit,
# downgrades the block to a loud allow — the gate's other ref-keyed branch,
# which no row above walks end to end. This is the row that goes red if that
# attempt branch is ever deleted.
VREPO=$(mktemp -d)/repo
mkrepo "$VREPO"
(
  cd "$VREPO" || exit 1
  printf 'committed work\n' >> a.ts
  git add a.ts && git commit -qm work
)
python3 -c "import json,sys;print(json.dumps({
  'tool_name':'mcp__plugin_bughunter_ohmybug__submit_review',
  'tool_input':{'diff':'','meta':{'repo':'x/y','ref':sys.argv[1]}},
  'cwd':sys.argv[2]}))" "$(git -C "$VREPO" rev-parse HEAD)" "$VREPO" | bash "$G/stamp-hunt.sh"
rc=$(mk "$V" "$VREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL a refused ref-keyed offer did not warn the merge through (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
out=$(mk "$V" "$VREPO" | bash "$G/pre-pr-gate.sh" 2>/dev/null)
case "$out" in
  *"no findings came back"*) ;;
  *) printf 'FAIL the ref-keyed warn-through said nothing on stdout: %s\n' "$out"; fails=$((fails + 1)) ;;
esac
rm -rf "$(dirname "$VREPO")"

# A rung-1 hunt (no payload, no upload, meta.ref = the head sha) is the
# skill's normal path, and prose edited after it is still just prose: the
# recording cwd standing clean AT the reviewed commit proves the working diff
# IS the diff the server fetched, so the sig: allowance survives the
# ref-keyed flow instead of demanding a paid re-hunt of a README.
SREPO=$(mktemp -d)/repo
mkrepo "$SREPO"
(
  cd "$SREPO" || exit 1
  printf 'committed work\n' >> a.ts
  git add a.ts && git commit -qm work
)
SHEAD=$(git -C "$SREPO" rev-parse HEAD)
ppost submit_review running "$SREPO" "" rev_rung1 "$SHEAD"
ppost get_findings done "$SREPO" "" rev_rung1 "$SHEAD"
rc=$(mk "$V" "$SREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL the rung-1 record did not allow at the reviewed commit (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
printf 'a README edit after the hunt\n' > "$SREPO/README.md"
git -C "$SREPO" add -N README.md 2>/dev/null
rc=$(mk "$V" "$SREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL prose after a ref-keyed hunt demanded a re-hunt (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
git -C "$SREPO" add README.md 2>/dev/null
git -C "$SREPO" -c user.email=t@t -c user.name=t commit -qm docs 2>/dev/null
rc=$(mk "$V" "$SREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL committed prose after a ref-keyed hunt demanded a re-hunt (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
printf 'export const two = 2\n' >> "$SREPO/a.ts"
rc=$(mk "$V" "$SREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL code after a ref-keyed hunt did not re-arm the gate (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$SREPO")"

# An out-of-band upload (upload:true, empty diff) never passes through this
# hook, so it can prove nothing about the tree: no tree ids, and with
# uncommitted work the ref: line is never honoured either. The gate blocking
# is the documented boundary; the defect was crossing it SILENTLY, at merge
# time, after the review had been paid for — the submit must say so.
UREPO=$(mktemp -d)/repo
mkrepo "$UREPO"
printf 'big unpushed work\n' >> "$UREPO/a.ts"
out=$(python3 -c "import json,sys;print(json.dumps({
  'tool_name':'mcp__plugin_bughunter_ohmybug__submit_review',
  'tool_input':{'review_id':'rev_up','diff':'','upload':True,
    'meta':{'repo':'x/y','ref':sys.argv[1]}},
  'tool_response':{'content':[{'type':'text','text':json.dumps(
     {'review_id':'rev_up','status':'running'})}]},
  'cwd':sys.argv[2]}))" "$(git -C "$UREPO" rev-parse HEAD)" "$UREPO" | bash "$G/stamp-hunt.sh" 2>/dev/null); rc=$?
case "$out" in
  *"cannot verify them against this tree"*) ;;
  *) printf 'FAIL an out-of-band upload from a dirty tree was filed silently: %s\n' "$out"; fails=$((fails + 1)) ;;
esac
[ "$rc" = 2 ] || { printf 'FAIL the out-of-band warning told only the transcript (rc=%s)\n' "$rc"
                   fails=$((fails + 1)); }
ppost get_findings done "$UREPO" "" rev_up
rc=$(mk "$V" "$UREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL out-of-band bytes credited the dirty tree (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
# ...and a CLEAN checkout does not launder the upload into tree ids either:
# the sig: allowance belongs only to hunts whose bytes the server provably
# saw (its own fetch of repo@ref), so prose after an uploaded hunt re-arms
# the gate where the rung-1 row above stays allowed.
git -C "$UREPO" add a.ts 2>/dev/null
git -C "$UREPO" -c user.email=t@t -c user.name=t commit -qm work 2>/dev/null
python3 -c "import json,sys;print(json.dumps({
  'tool_name':'mcp__plugin_bughunter_ohmybug__submit_review',
  'tool_input':{'review_id':'rev_up2','diff':'','upload':True,
    'meta':{'repo':'x/y','ref':sys.argv[1]}},
  'tool_response':{'content':[{'type':'text','text':json.dumps(
     {'review_id':'rev_up2','status':'running'})}]},
  'cwd':sys.argv[2]}))" "$(git -C "$UREPO" rev-parse HEAD)" "$UREPO" | bash "$G/stamp-hunt.sh" >/dev/null 2>&1
ppost get_findings done "$UREPO" "" rev_up2
rc=$(mk "$V" "$UREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL a clean-tree uploaded hunt was not honoured through its ref (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
printf 'a README edit after the uploaded hunt\n' > "$UREPO/README.md"
git -C "$UREPO" add -N README.md 2>/dev/null
rc=$(mk "$V" "$UREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] || { printf 'FAIL an upload laundered tree ids through a clean checkout (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$UREPO")"

# A promotion that finds no pending record is TWO different facts, and the hook
# cannot tell them apart: another session owns the submit (fine, it will record
# it), or the submitting session is standing in a different checkout, in which
# case the hunt is paid for, the promotion no-ops, and the gate blocks a diff
# that was reviewed. That happened, and it was caught by hand at merge time
# (owner report, 2026-08-22). The agent can tell them apart — if it is told.
reset_state
out=$(ppost get_findings done "$PWD" "" rev_ghostpromote 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] || { printf 'FAIL a promotion that found no record was silent (rc=%s)\n' "$rc"
                   fails=$((fails + 1)); }
case "$out" in
  *"no rev-id record for rev_ghostpromote"*"$PWD"*) ;;
  *) printf 'FAIL the promote miss named neither the review nor the directory: %s\n' "$out"
     fails=$((fails + 1)) ;;
esac
# ...and it must NOT conclude anything about the gate. The gate has four keys and
# this branch knows about none of them; three client sessions read the old
# sentence as a verdict on the gate and reported their hunts uncounted while
# `ref:<sha>` records for those hunts sat on disk, and one was about to ask for
# SKIP_BUGHUNT (#439). A true fact with a false conclusion attached is what
# disarms a control.
case "$out" in
  *"gate will not see this hunt"*|*"gate will not recognise"*)
    printf 'FAIL the promote miss still passes a verdict on the merge gate: %s\n' "$out"
    fails=$((fails + 1)) ;;
esac
case "$out" in
  *"four keys"*) ;;
  *) printf 'FAIL the promote miss does not say what the gate actually reads: %s\n' "$out"
     fails=$((fails + 1)) ;;
esac
reset_state

# The honest full payload, in the OTHER spelling: a client that pipes
# `git diff` verbatim sends the trailing newline that command substitution
# strips. Same diff, second hash — a one-spelling equality test false-blocks
# exactly the flow this stamp exists to serve. The payload goes through
# ppost's @file spelling, because $( ) would eat the newline and the row
# would pass for the wrong reason.
EREPO=$(mktemp -d)/repo
mkrepo "$EREPO"
printf 'honest change\n' >> "$EREPO/a.ts"
git -C "$EREPO" diff "$(cd "$EREPO" && ohmybug_base)" > "$EREPO.rawdiff"
ppost submit_review running "$EREPO" "@$EREPO.rawdiff" rev_raw
ppost get_findings done "$EREPO" "@$EREPO.rawdiff" rev_raw
rc=$(mk "$V" "$EREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL a verbatim git diff payload read as foreign to its own tree (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
# ...and prose on top of that hunt is still just prose.
printf 'a README edit after the hunt\n' > "$EREPO/README.md"
git -C "$EREPO" add -N README.md 2>/dev/null
rc=$(mk "$V" "$EREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL prose after a raw-payload hunt demanded a re-hunt (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
rm -rf "$(dirname "$EREPO")"

# A clean checkout is the most natural place to merge somebody else's PR, and
# the one place this gate can see nothing. Allowing is right; the defect was
# allowing SILENTLY — an exit-0 PreToolUse with no output is byte-identical to
# "hunted, allowed". The loaded half of this row is the two message
# assertions: the rc alone stays green across the very regression it guards.
FREPO=$(mktemp -d)/repo
mkrepo "$FREPO"
rc=$(mk "$V" "$FREPO" | bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] || { printf 'FAIL clean tree: the stand-down must still allow (rc=%s)\n' "$rc"; fails=$((fails + 1)); }
out=$(mk "$V" "$FREPO" | bash "$G/pre-pr-gate.sh" 2>&1 >/dev/null)
case "$out" in
  *"no changes against its base"*) ;;
  *) printf 'FAIL the clean-tree stand-down said nothing on stderr: %s\n' "$out"; fails=$((fails + 1)) ;;
esac
out=$(mk "$V" "$FREPO" | bash "$G/pre-pr-gate.sh" 2>/dev/null)
case "$out" in
  *"no changes against its base"*) ;;
  *) printf 'FAIL the clean-tree stand-down said nothing on stdout: %s\n' "$out"; fails=$((fails + 1)) ;;
esac
STAMP_BASE=$(git -C "$FREPO" rev-parse HEAD)
stamp_out=$(cd "$FREPO" && bash "$G/diff-id.sh" stamp 2>&1 || true)
case "$stamp_out" in
  *"$FREPO"*"$STAMP_BASE"*) ;;
  *) printf 'FAIL clean stamp omitted its checkout/base: %s\n' "$stamp_out"; fails=$((fails + 1)) ;;
esac
# ...and it speaks only about merges: other commands on the same clean tree
# stay silent, or every Bash call in a fresh checkout narrates itself.
for NM in "gh pr view 5" "npm test" "git log --no-merges"; do
  got=$(mk "$NM" "$FREPO" | bash "$G/pre-pr-gate.sh" 2>&1; echo "rc=$?")
  [ "$got" = "rc=0" ] || { printf 'FAIL a non-merge command spoke on a clean tree: %s -> %s\n' "$NM" "$got"; fails=$((fails + 1)); }
done
rm -rf "$(dirname "$FREPO")"
reset_state

# --- the worktree rows -------------------------------------------------------
# The failure the owner hit on 2026-08-12, third occurrence of this class: the
# work lives in a git worktree, the hunt is driven from a session whose cwd is
# the MAIN checkout, and the merge runs in the worktree. Two ways that used to
# break, both fixed by taking the id from the bytes we SENT and keying the record
# on the repository rather than the working tree:
#
#   1. the stamp derived the id from `git diff` in ITS cwd — the main checkout,
#      which is clean, so the id came out empty and nothing was recorded at all,
#      silently;
#   2. even a correct record was filed under the worktree's own git-dir, a
#      different file from the one the gate read.
WT=$(mktemp -d)/wt
if git worktree add -q --detach "$WT" HEAD 2>/dev/null; then
  # A real change, committed in the worktree, so its diff-vs-base is non-empty
  # while the main checkout stays clean.
  printf 'worktree change %s\n' "$$" > "$WT/.ohmybug-wt-scratch"
  git -C "$WT" add .ohmybug-wt-scratch 2>/dev/null
  git -C "$WT" -c user.email=t@t -c user.name=t commit -qm 'worktree scratch' 2>/dev/null

  WT_DIFF=$(git -C "$WT" diff "$(git -C "$WT" merge-base HEAD origin/main 2>/dev/null || git -C "$WT" rev-parse HEAD~1)")
  rm -rf "$(cd "$WT" && ohmybug_hunt_dir)" "$(ohmybug_hunt_dir)"

  # submit_review carrying the worktree's diff, reported with the MAIN checkout
  # as cwd — the exact shape that recorded nothing.
  wpost() { # tool, done?, cwd, diff-text
    python3 -c "import json,sys;print(json.dumps({
      'tool_name':'mcp__plugin_bughunter_ohmybug__'+sys.argv[1],
      'tool_input':{'diff':sys.argv[4]},
      'tool_response':{'content':[{'type':'text','text':json.dumps(
         {'review_id':'rev_wt','status':'done' if sys.argv[2]=='1' else 'running'})}]},
      'cwd':sys.argv[3]}))" "$1" "$2" "$3" "$4" | bash "$G/stamp-hunt.sh"
  }
  wpost submit_review 0 "$PWD" "$WT_DIFF" >/dev/null 2>&1
  wpost get_findings 1 "$PWD" "$WT_DIFF"

  # ...and the merge happens in the worktree. Before the fix: 2.
  rc=$(mk "$V" "$WT" | perl -e 'alarm 10; exec @ARGV' bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
  if [ "$rc" != 0 ]; then
    printf 'FAIL worktree: hunt recorded from the main checkout is invisible in the worktree (rc=%s)\n' "$rc"
    fails=$((fails + 1))
  fi

  # And an edit made in the worktree AFTER that hunt must block again.
  printf 'unhunted %s\n' "$$" >> "$WT/.ohmybug-wt-scratch"
  rc=$(mk "$V" "$WT" | perl -e 'alarm 10; exec @ARGV' bash "$G/pre-pr-gate.sh" >/dev/null 2>&1; echo $?)
  if [ "$rc" != 2 ]; then
    printf 'FAIL worktree: an edit written after the hunt was allowed through (rc=%s)\n' "$rc"
    fails=$((fails + 1))
  fi

  git worktree remove --force "$WT" 2>/dev/null
  git worktree prune 2>/dev/null
else
  echo "worktree rows skipped: could not create a worktree here" >&2
  fails=$((fails + 1))
fi

# --- the no-payload path -----------------------------------------------------
# The DEFAULT submit sends no diff at all — the server fetches it for repo@ref —
# so there the commit is the only identity available, and a hunt that records
# nothing is a gate that blocks reviewed work.
#
# Asserted on the record itself rather than through the gate: the gate's answer
# here also depends on whether the tree is clean, and mixing the two would leave
# a green row that proves neither.
reset_state
NP_SHA=$(git rev-parse HEAD)
npost() { # tool, status
  python3 -c "import json,sys;print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__'+sys.argv[1],
    'tool_input':{'diff':'','meta':{'repo':'x/y','ref':sys.argv[3]}},
    'tool_response':{'content':[{'type':'text','text':json.dumps(
       {'review_id':'rev_np','status':sys.argv[2]})}]},
    'cwd':sys.argv[4]}))" "$1" "$2" "$NP_SHA" "$PWD" | bash "$G/stamp-hunt.sh"
}
npost submit_review running
if ohmybug_hunted "ref:$NP_SHA"; then
  printf 'FAIL no-payload: submit alone authorised the commit\n'; fails=$((fails + 1))
fi
npost get_findings done
if ! ohmybug_hunted "ref:$NP_SHA"; then
  printf 'FAIL no-payload: a finished review left the commit unrecorded\n'; fails=$((fails + 1))
fi

# --- no recorder, no accusation ----------------------------------------------
# 0.8.1 shipped the gate without stamp-hunt.sh, so on those installs the gate
# cannot know anything — and it blocked a diff that had been hunted four times
# (owner report, twice). "Cannot tell" must not read as "you did not hunt".
BK=$(mktemp -d)
cp "$G/pre-pr-gate.sh" "$G/diff-id.sh" "$BK/"
# No evidence of ANY hunt is this row's premise, so clear the hunt set too — not
# only the legacy single-slot marker.
reset_state
if [ -n "$ID" ]; then
  # With the recorder present and no marker: blocks (exit 2), as before.
  t "$V" 2
  # Same state, recorder missing: stands down.
  hidden="$G/stamp-hunt.sh.hidden-for-test"
  mv "$G/stamp-hunt.sh" "$hidden"
  t "$V" 0
  out=$(mk "$V" "$PWD" | bash "$G/pre-pr-gate.sh" 2>&1 >/dev/null)
  case "$out" in
    *"predates the hunt recorder"*) ;;
    *) printf 'FAIL stand-down message did not name the cause: %s\n' "$out"; fails=$((fails + 1)) ;;
  esac
  mv "$hidden" "$G/stamp-hunt.sh"
fi
rm -rf "$BK"

# --- the first-run notice speaks once, and not to someone who already decided -
# A plugin that repeats advice you have taken is a plugin you turn off, and the
# advice here is about the user's own permission settings — the one place this
# plugin must never write.
FR=$(mktemp -d)
say() { OMB_STATE_DIR="$FR/state" HOME="$FR" bash "$G/first-run.sh"; }
[ -n "$(say)" ] || { printf 'FAIL first-run: said nothing on a fresh install\n'; fails=$((fails + 1)); }
[ -z "$(say)" ] || { printf 'FAIL first-run: said it twice\n'; fails=$((fails + 1)); }
rm -rf "$FR/state"
mkdir -p "$FR/.claude"
printf '{"permissions":{"deny":["mcp__plugin_bughunter_ohmybug__submit_review"]}}\n' > "$FR/.claude/settings.json"
[ -z "$(say)" ] || { printf 'FAIL first-run: nagged a user who had already decided\n'; fails=$((fails + 1)); }
rm -rf "$FR"

# --- the one model-authored string that becomes a path ------------------------
# `review_id` is written by the model and lands in `$PENDING_DIR/$REVIEW`, and
# this file both WRITES and (on a failed review) DELETES that path. The
# sanitiser is the only thing keeping either inside ~/.ohmybug, and it had no
# row: every id in this suite is already alphanumeric, so deleting the line kept
# the suite green.
# The one model-authored string that becomes a path. `review_id` lands in
# $PENDING_DIR/$REVIEW, and this file both writes and (on a failed review)
# deletes that path, so the sanitiser is the only thing keeping either inside
# ~/.ohmybug. One level of escape proves it; counting six `..` and hoping the
# directories above happen to exist makes the row pass for the wrong reason.
reset_state
post submit_review 0 '../escaped'
# One level up from the PENDING directory is `.../hunts/`, not the hunt dir
# itself — `<key>.pending` is a sibling of `<key>`, not a child. Checking the
# wrong parent is how this row first passed against a deleted sanitiser.
[ -e "$(dirname "$(ohmybug_hunt_dir)")/escaped" ] && {
  printf 'FAIL a model-authored review_id walked out of the pending directory\n'
  fails=$((fails + 1)); }
reset_state

# --- the unread hunt ----------------------------------------------------------
# A hunt was submitted, the agent polled once, saw `running`, ended its turn and
# waited to be prodded; both reviews had been done for forty minutes when the
# user finally asked (owner report, 2026-08-21). These rows pin the end of a
# turn to the same pending record the gate reads.
nudge() { # stop_hook_active -> rc
  python3 -c "import json,sys;print(json.dumps({'hook_event_name':'Stop',
    'stop_hook_active':sys.argv[1]=='1','cwd':sys.argv[2]}))" "$1" "$PWD" \
    | perl -e 'alarm 10; exec @ARGV' bash "$G/pending-nudge.sh" >/dev/null 2>&1
  echo $?
}
n() { # label, stop_hook_active, expected rc
  rc=$(nudge "$2")
  [ "$rc" = 142 ] && rc=HUNG
  if [ "$rc" != "$3" ]; then
    printf 'FAIL nudge %s: want=%s got=%s\n' "$1" "$3" "$rc"
    fails=$((fails + 1))
  fi
}

reset_state
n 'nothing pending, nothing to say'            0 0
post submit_review 0 rev_nudge content
n 'an unread hunt blocks the end of the turn'  0 2
# Without this the reminder becomes a session that cannot end: remove the
# stop_hook_active guard and this row is the one that reddens.
n 'and never twice in a row'                   1 0
post get_findings 1 rev_nudge content
n 'a read hunt is silent'                      0 0

# Six unread hunts, five named: the cap is fine, hiding the remainder is not.
# The next Stop is suppressed by the anti-loop guard, so this message is the only
# one that will ever mention the sixth (found in review of this hook).
reset_state
for i in 1 2 3 4 5 6; do post submit_review 0 "rev_many$i" content; done
n 'six unread hunts still hold the turn'        0 2
said=$(python3 -c "import json;print(json.dumps({'hook_event_name':'Stop',
  'stop_hook_active':False,'cwd':'$PWD'}))" | bash "$G/pending-nudge.sh" 2>&1 >/dev/null)
# The whole rendered list, verbatim, and not a substring per id. The count comes
# from TOTAL rather than from what `head` kept, so asserting only "and 1 more"
# left `head -n 5` free to become `head -n 1` — one hunt of six named while the
# message claims one is hidden, a worse lie than the truncation it replaced, and
# the suite stayed green on it. Matching each id loosely was no better: it also
# passes on `./rev_many1`, which is not the string get_findings takes. Both
# mutations were live at once (found in review of this hook).
case $said in
  *'read: rev_many1 rev_many2 rev_many3 rev_many4 rev_many5 (and 1 more'*) ;;
  *) printf 'FAIL nudge names the wrong hunts: %s\n' "$said"
     fails=$((fails + 1)) ;;
esac

# --- whose hunt is it -------------------------------------------------------
# Ten foreign runs woke non-owners in one shift, one of them seven times, and a
# session in the middle of that was preparing to merge on "I am waiting for a
# clean hunt" that was never its hunt (#444). The record now carries who wrote
# it, so these rows pin the three states apart: mine, nobody's, somebody else's.
sess() { # tool, done?, review id, session id -> runs stamp-hunt.sh with a session
  OMB_DIFF=$(git diff "$(ohmybug_base)" 2>/dev/null) \
  python3 -c "import json,os,sys;
body={'review_id':sys.argv[3],'status':'done' if sys.argv[2]=='1' else 'running'}
print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__'+sys.argv[1],
    'tool_input':{'review_id':sys.argv[3],'diff':os.environ.get('OMB_DIFF','')},
    'tool_response':{'content':[{'type':'text','text':json.dumps(body)}]},
    'session_id':sys.argv[4],
    'cwd':sys.argv[5]}))" "$1" "$2" "$3" "$4" "$PWD" \
  | bash "$G/stamp-hunt.sh"
}
nsess() { # stop_hook_active, session id -> rc, and the message on stdout
  python3 -c "import json,sys;print(json.dumps({'hook_event_name':'Stop',
    'stop_hook_active':sys.argv[1]=='1','session_id':sys.argv[2],'cwd':sys.argv[3]}))" \
    "$1" "$2" "$PWD" \
    | perl -e 'alarm 10; exec @ARGV' bash "$G/pending-nudge.sh" 2>&1 >/dev/null
}
nsrc() { # stop_hook_active, session id -> rc only
  python3 -c "import json,sys;print(json.dumps({'hook_event_name':'Stop',
    'stop_hook_active':sys.argv[1]=='1','session_id':sys.argv[2],'cwd':sys.argv[3]}))" \
    "$1" "$2" "$PWD" \
    | perl -e 'alarm 10; exec @ARGV' bash "$G/pending-nudge.sh" >/dev/null 2>&1
  echo $?
}

reset_state
sess submit_review 0 rev_mine A1
sess submit_review 0 rev_theirs B2
rc=$(nsrc 0 A1)
[ "$rc" = 2 ] || { printf 'FAIL nudge: my own unread hunt did not hold the turn (rc=%s)\n' "$rc"
                   fails=$((fails + 1)); }
mysaid=$(nsess 0 A1)
case $mysaid in
  *rev_mine*) ;;
  *) printf 'FAIL nudge: my own hunt was not named: %s\n' "$mysaid"; fails=$((fails + 1)) ;;
esac
# The whole point: the id belonging to another session is NOT named, and there is
# no instruction attached to it. Naming ids a session cannot promote is what
# taught agents to skip this line.
case $mysaid in
  *rev_theirs*) printf 'FAIL nudge: another session hunt was named to me: %s\n' "$mysaid"
                fails=$((fails + 1)) ;;
esac
case $mysaid in
  *'1 unread hunt(s) here belong to other sessions'*) ;;
  *) printf 'FAIL nudge: the foreign count went missing: %s\n' "$mysaid"; fails=$((fails + 1)) ;;
esac
# Nothing of C3's own is pending, so the turn is NOT held — but it is told, once,
# without ids and without a call to make.
rc=$(nsrc 0 C3)
[ "$rc" = 0 ] || { printf 'FAIL nudge: a session with nothing of its own was blocked (rc=%s)\n' "$rc"
                   fails=$((fails + 1)); }
csaid=$(nsess 0 C3)
case $csaid in
  *'belong to other sessions on this machine'*) ;;
  *) printf 'FAIL nudge: a foreign-only pending set said nothing: %s\n' "$csaid"
     fails=$((fails + 1)) ;;
esac
case $csaid in
  *rev_mine*|*rev_theirs*) printf 'FAIL nudge: foreign ids were named anyway: %s\n' "$csaid"
                           fails=$((fails + 1)) ;;
esac
# A record with NO session line is UNKNOWN, never foreign: the client may not
# send the field, and the id's stability across compaction and --resume is not
# documented anywhere. Dropping it would trade a nudge that woke the wrong
# session for a nudge that never comes — silence about a hunt somebody paid for,
# which is the worse of the two failures.
reset_state
post submit_review 0 rev_nosession content
rc=$(nsrc 0 D4)
[ "$rc" = 2 ] || { printf 'FAIL nudge: a record with no owner was dropped instead of shown (rc=%s)\n' "$rc"
                   fails=$((fails + 1)); }

# Fail-open is the load-bearing property of a hook that runs at the end of every
# turn: fail closed and no turn can end at all, and nothing the agent does can
# lift it. Every row above hands it valid JSON, from a real repository, with
# python3 on PATH — so a fail-closed mutation in any of these three branches
# shipped green (found in review of this hook). Each row keeps a LIVE pending
# record, so only the branch under test can be what stands the hook down.
reset_state
post submit_review 0 rev_open content
nrc() { # stdin -> rc, with an optional PATH prefix in $1. cwd travels in the
        # PAYLOAD (see sj), not here: a comment promising a parameter the body
        # never reads is how the next row silently runs against the wrong tree.
  rc=$(PATH="${1:-}$PATH" perl -e 'alarm 10; exec @ARGV' \
       bash "$G/pending-nudge.sh" >/dev/null 2>&1; echo $?)
  [ "$rc" = 142 ] && rc=HUNG
  printf '%s' "$rc"
}
no() { # label, expected rc, actual rc
  [ "$3" = "$2" ] || { printf 'FAIL nudge %s: want=%s got=%s\n' "$1" "$2" "$3"
                       fails=$((fails + 1)); }
}
sj() { # cwd -> one Stop payload, on one line: a payload split over two lines
       # inside a nested command substitution reached python3 mangled.
  python3 -c "import json,sys;print(json.dumps({'hook_event_name':'Stop',
'stop_hook_active':False,'cwd':sys.argv[1]}))" "$1"
}
no 'unreadable input stands down' 0 "$(printf 'not json at all' | nrc)"

NOPY2=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$NOPY2/python3"; chmod +x "$NOPY2/python3"
no 'no python3 stands down' 0 "$(sj "$PWD" | nrc "$NOPY2:")"
rm -rf "$NOPY2"

OUTSIDE=$(mktemp -d)
no 'no repository stands down' 0 "$(sj "$OUTSIDE" | nrc)"
rmdir "$OUTSIDE"
reset_state

# The TTL's own default, at an age no other row occupies. Every record above is
# either seconds old or stamped in the year 2000, so `-mmin -180` could shrink to
# `-mmin -1` and ship green — landing exactly on the incident in this hook's
# header, where the hunts had been sitting for forty minutes (found in review of
# this hook).
reset_state
post submit_review 0 rev_aged content
touch -t "$(python3 -c 'import time;print(time.strftime("%Y%m%d%H%M",
  time.localtime(time.time() - 90 * 60)))')" \
  "$(ohmybug_hunt_dir).pending/rev_aged" 2>/dev/null
n 'a 90-minute-old hunt is still unread'         0 2

# stamp-hunt.sh writes its pending record through `$PENDING.tmp`, and a hook
# killed inside that block leaves the scratch name behind. Named at the agent it
# is a review id get_findings can never resolve, so nothing can clear the record
# and the turn is held again every turn until the TTL runs out.
reset_state
mkdir -p "$(ohmybug_hunt_dir).pending"
: > "$(ohmybug_hunt_dir).pending/rev_ghost.tmp"
n 'a write-ahead scratch file is not a pending hunt' 0 0

reset_state
# A record left by a review that died, or by a session that walked away, is not
# a live hunt — and a nag nobody can satisfy is how a control gets disarmed.
post submit_review 0 rev_stale content
touch -t 200001010000 "$(ohmybug_hunt_dir).pending/rev_stale" 2>/dev/null
n 'a stale pending record does not nag forever' 0 0
reset_state

# --- the wiring ---------------------------------------------------------------
# Everything above pipes payloads into the scripts by hand, so the file that
# decides WHICH events reach them was free to be wrong, half-written or absent —
# reverting it wholesale (i.e. shipping none of this) left the suite green. The
# events matter one way each: submit_review must reach BOTH (PreToolUse records
# the offer, PostToolUse the pending record), and get_findings must reach only
# PostToolUse, or a poll would count as an offer.
python3 - "$G/hooks.json" <<'PY' || fails=$((fails + 1))
import json, re, sys
h = json.load(open(sys.argv[1]))["hooks"]
def fires(event, tool):
    return any(re.search(e.get("matcher", ""), "mcp__plugin_bughunter_ohmybug__" + tool)
               for e in h.get(event, []))
want = {("PreToolUse", "submit_review"): True,
        ("PreToolUse", "get_findings"): False,
        ("PreToolUse", "confirm_findings"): False,
        ("PostToolUse", "submit_review"): True,
        ("PostToolUse", "get_findings"): True,
        ("PostToolUse", "confirm_findings"): True}
bad = [f"{e}/{t}: want {w}, got {fires(e, t)}" for (e, t), w in want.items() if fires(e, t) != w]
# Stop carries no matcher, so the only thing to assert is that it is wired at
# all and to the right script: reverting that one line would otherwise leave
# every row above green while no turn is ever held again.
if not any("pending-nudge.sh" in k.get("command", "")
           for e in h.get("Stop", []) for k in e.get("hooks", [])):
    bad.append("Stop: pending-nudge.sh not wired")
if bad:
    print("FAIL hooks.json wiring: " + "; ".join(bad))
    sys.exit(1)
PY

cleanup_scratch
if [ "$(git status --porcelain | grep -v "$SCRATCH" || true)" != "$TREE_BEFORE" ]; then
  printf 'FAIL the suite changed the working tree it was run in:\n%s\n' "$(git status --porcelain)"
  fails=$((fails + 1))
fi

rm -rf "$HOME"
if [ "$fails" = 0 ]; then echo "gate+stamp: ok"; else echo "gate+stamp: $fails failing"; exit 1; fi
