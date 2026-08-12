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

rm -rf "$M" "$M.pending" "$(ohmybug_hunt_dir)"
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
  rm -rf "$M" "$M.pending" "$(ohmybug_hunt_dir)"
  post submit_review 0
  echo "# stamp-test-race $$" >> README.md
  post get_findings 1; s "done stamps the SENT diff, not the current one" "$ID"
  t "$V" 2
  git checkout -- README.md 2>/dev/null || true
  rm -rf "$M" "$(ohmybug_hunt_dir)"
  post confirm_findings 0; s "confirm stamps even with no pending" "$ID"
  # The whole point of hashing the diff: fixes written after the hunt must
  # re-block, or the gate authorises code nobody reviewed.
  echo "# stamp-test $$" >> README.md
  t "$V" 2
  git checkout -- README.md 2>/dev/null || sed -i '' -e "/# stamp-test $$/d" README.md
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
rm -rf "$M" "$M.pending" "$(ohmybug_hunt_dir)"
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
rm -rf "$M" "$M.pending" "$(ohmybug_hunt_dir)"
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

rm -rf "$HOME"
if [ "$fails" = 0 ]; then echo "gate+stamp: ok"; else echo "gate+stamp: $fails failing"; exit 1; fi
