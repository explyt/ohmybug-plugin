#!/bin/bash
# Public-repo hygiene, enforced rather than asked for.
#
# This repository is public. Two invariants hold everywhere a reader can see:
#   1. English only — not a single Cyrillic character.
#   2. Nothing internal — no review or receipt ids, no cross-references into a
#      private tracker, no machine or worktree paths, no infrastructure names,
#      no server source paths.
#
# The rule sat in AGENTS.md as prose and was broken anyway: one commit landed
# on main in Russian, a PR carried a Russian title and commit for a week, and a
# dozen issue comments quoted review ids, session names and machine paths.
# Prose nobody executes is not a control. This is the control.
#
# Three surfaces, because the three are checked by nobody else:
#   --files             tracked files (what `git ls-files` lists)
#   --commits A..B      the messages of every commit in the range
#   --text FILE|-       any text — CI feeds it the PR title and body
# And a positive control, --self-test, which runs each check over a fixture
# that MUST fail and one that must pass: a guard that has never been seen to
# bite is a guard nobody can trust.
#
# `perl`, not `grep -P`: the BSD grep on macOS has no -P, and the Cyrillic test
# is a Unicode property, which a byte-range in the C locale gets right only for
# part of the block.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/public-hygiene.sh --files | --commits <range> | --text <file|-> | --self-test
EOF
  exit 2
}

# Markers of the service's insides, as a reader would meet them. Each
# alternative names a CLASS, not a secret: the guard must not itself be the
# leak, so nothing here spells a hostname, a repository or an org.
#   review ids and receipts as the API prints them
#   a cross-reference into the product's own private repository (any org)
#   absolute paths of a developer machine or its temp worktrees
#   the provider's CLI and server-side source files
INTERNAL='rev_[0-9a-f]{8}\b|rcp_[0-9a-f]{6,}|\b[\w.-]+/OhMyBug\b|\bOhMyBug#\d+|/Users/[\w.-]+/|/private/tmp/|/home/[\w.-]+/|\bfly(\.io|ctl| ssh| logs| machine)\b|\b(sprites|pgqueue|submitplan|repoaccess)\.ts\b'

# Print offending lines as `label:line: text`, exit 1 if any. Reads stdin.
scan() { # label
  # Pattern and label travel in the environment, not spliced into the program:
  # the pattern contains `/`, which would end a qr/…/ literal, and a label is
  # a file name a contributor chose.
  HYGIENE_RE="$INTERNAL" HYGIENE_LABEL="$1" perl -CSD -Mutf8 -ne '
    BEGIN { $bad = 0; $re = qr/$ENV{HYGIENE_RE}/; $l = $ENV{HYGIENE_LABEL} }
    if (/\p{Cyrillic}/) { print "$l:$.: cyrillic: $_"; $bad = 1 }
    elsif ($_ =~ $re) { print "$l:$.: internal reference: $_"; $bad = 1 }
    END { exit $bad }'
}

check_files() {
  local rc=0 f
  # The guard's own source names the patterns it hunts; it cannot pass its own
  # denylist and is the one file exempt from it — and from nothing else.
  while IFS= read -r f; do
    [ "$f" = "scripts/public-hygiene.sh" ] && continue
    scan "$f" < "$f" || rc=1
  done < <(git ls-files)
  return $rc
}

check_commits() { # range
  local rc=0 sha
  for sha in $(git rev-list --no-merges "$1"); do
    git log -1 --format='%B' "$sha" | scan "commit ${sha:0:7}" || rc=1
  done
  return $rc
}

check_text() { # file or -
  if [ "$1" = - ]; then scan "text"; else scan "$1" < "$1"; fi
}

self_test() {
  local fails=0 tmp
  tmp=$(mktemp -d)
  # The positive control: each class of offence on its own line, each of which
  # MUST be named. A check that stays green here is not a check.
  printf 'ordinary line\nоткрытый текст на кириллице\n' > "$tmp/cyr"
  printf 'see rev_0123abcd for the trace\n' > "$tmp/rev"
  printf 'filed as some-org/OhMyBug#123\n' > "$tmp/xref"
  printf 'path was /Users/someone/src/x\n' > "$tmp/path"
  printf 'receipt rcp_deadbeef01\n' > "$tmp/rcp"
  local f want
  for f in cyr rev xref path rcp; do
    if check_text "$tmp/$f" >/dev/null 2>&1; then
      printf 'FAIL (positive control %s): the guard did not bite\n' "$f"; fails=$((fails + 1))
    fi
  done
  # ...and the negative: an ordinary English line, a plugin-local issue number
  # (#38), a public third-party cross-reference, a URL, a version — none may fail.
  printf 'English only, see #38, other-org/other-repo#5768, https://example.com/x, version 0.69.0\n' > "$tmp/ok"
  if ! check_text "$tmp/ok" >/dev/null 2>&1; then
    printf 'FAIL (negative control): an innocent line was refused\n'; fails=$((fails + 1))
  fi
  # The commit-range check reads messages, not trees: a Russian subject in a
  # scratch repository must be caught, and an English one passed.
  local repo; repo=$tmp/repo
  git init -q "$repo" && (
    cd "$repo" && git config user.email t@t && git config user.name t
    printf 'a\n' > a && git add a && git commit -qm 'base'
    git branch -qM main
    printf 'b\n' > a && git commit -qam 'починка: сообщение по-русски'
  )
  if (cd "$repo" && check_commits main~1..main >/dev/null 2>&1); then
    printf 'FAIL (positive control commits): a Russian commit subject passed\n'; fails=$((fails + 1))
  fi
  (cd "$repo" && git commit -q --amend -m 'fix: an English subject')
  if ! (cd "$repo" && check_commits main~1..main >/dev/null 2>&1); then
    printf 'FAIL (negative control commits): an English commit subject was refused\n'; fails=$((fails + 1))
  fi
  rm -rf "$tmp"
  if [ "$fails" = 0 ]; then echo "public-hygiene self-test: ok"; else echo "public-hygiene self-test: $fails failing"; exit 1; fi
}

case "${1:-}" in
  --files)     check_files ;;
  --commits)   check_commits "${2:?range}" ;;
  --text)      check_text "${2:?file}" ;;
  --self-test) self_test ;;
  *) usage ;;
esac
