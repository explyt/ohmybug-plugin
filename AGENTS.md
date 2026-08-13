# ohmybug-plugin — process for agents (all runtimes)

This file is the source of truth for how work happens here, for every agent:
Claude Code, Codex, anything else, and humans. Substantive rules change only
in this file; if a runtime-specific doc exists, it is a thin pointer back
here. Do not let them drift.

**This repository is PUBLIC.** Every commit, comment, issue, PR and release
note is visible to the world, forever. Read the Publicity section before
writing anything.

## What this is

The OhMyBug plugin for Claude Code: the `bughunter` skill and commands, the
merge-gate hooks (`plugins/bughunter/hooks/`), and the marketplace manifest.
Distributed straight from this repository — whatever lands on `main` is what
users install.

## The loop

```
git checkout -b <fix|docs|feat>/<slug> origin/main   # never work on main
   … change + the checks below, ALL of them …
git push -u origin <branch>
gh pr create                                          # PR always; direct push to main is forbidden
   … CI green (Verify hooks) → squash-merge → delete branch …
```

- Green CI plus a clean review is merge authority — merge your own PR, do
  not wait to be asked.
- Blocked on something you do not control? Say exactly what you need in the
  PR thread, commit your WIP to the branch (work must never be lost), and
  move on.

## Verification — before you say "done"

Run all of it; the suite is fast:

```
bash -n <every shell file you touched>
bash scripts/version.sh --self-test
bash plugins/bughunter/hooks/gate-test.sh    # the FULL suite — this is the one that catches real regressions
```

- `gate-test.sh` exercises the cross-file scenarios (worktree flows,
  no-payload submits, recorder stand-down). Weak checks passing while this
  suite is unrun has already shipped a fix with five hidden failures.
- **If your sandbox cannot run the full suite, the change is UNVERIFIED —
  report it exactly that way.** "bash -n passes" is not verification, and
  claiming it is is worse than saying "not verified: sandbox".
- Guards get a durable test: if deleting your guard keeps every check green,
  you are not done. Mutation is 30 seconds — break it, watch the red, revert.
- Touched anything under `plugins/`? Run `bash scripts/version.sh --write`
  in the branch: the version is derived, and the manifest must move or the
  marketplace never updates anyone.

## Publicity — hard rules

- **English only** in everything committed or posted here: code, comments,
  docs, commit messages, issues, PRs, release notes.
- **No internal details.** No private hostnames or paths, no customer data,
  no infra numbers, no links or references to private-tracker items in
  commits, PRs or issues here.
- **Team work items do not live here.** Public issues are for external
  users. Internal bugs and tasks go to the company tracker:
  `gh issue create --repo exply-dev/OhMyBug …` — always pass `--repo`
  explicitly, because `gh` defaults to this clone's public remote.
- **No AI trailers.** Never `Co-Authored-By` or any AI-vendor identity in
  commits; check `git config --get user.email` before committing.
