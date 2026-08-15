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
SCRATCH=".ohmybug-gate-test-scratch"
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
post() { # tool, done?, -> runs stamp-hunt.sh
  # The payload is the WORKING DIFF's bytes, exactly what a client sends: the
  # whole point of payload-based stamping is that sha256(sent bytes) equals the
  # diff-id a gate computes locally. A file's raw content hashes to something
  # no gate ever computes and turns every marker row into noise.
  OMB_DIFF=$(git diff "$(ohmybug_base)" 2>/dev/null) \
  python3 -c "import json,os,sys;print(json.dumps({
    'tool_name':'mcp__plugin_bughunter_ohmybug__'+sys.argv[1],
    'tool_input':{'review_id':sys.argv[4],'diff':os.environ.get('OMB_DIFF','')},
    'tool_response':{'content':[{'type':'text','text':json.dumps(
       {'review_id':sys.argv[4],'status':'done' if sys.argv[2]=='1' else 'running'})}]},
    'cwd':sys.argv[3]}))" "$1" "$2" "$PWD" "${3:-rev_x}" | bash "$G/stamp-hunt.sh"
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
  mkdir -p "$HOME/.claude"
  printf '{"permissions":{"allow":["mcp__plugin_bughunter_ohmybug__submit_review"]}}\n' > "$HOME/.claude/settings.json"
  t "$V" 2
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
  npre "some-branch-name"
  # Assert on the key the bogus ref would have written, not on HEAD's key: a
  # lookup for HEAD is false either way, so it passes while recording anything.
  ohmybug_attempted "ref:some-branch-name" && { printf 'FAIL a ref that is not this commit still recorded an attempt\n'; fails=$((fails + 1)); }
  npre "$HEAD_NOW"
  ohmybug_attempted "ref:$HEAD_NOW" || { printf 'FAIL the no-payload attempt was not recorded\n'; fails=$((fails + 1)); }
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
  wpost submit_review 0 "$PWD" "$WT_DIFF"
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
