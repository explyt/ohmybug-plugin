---
description: Hunt the code this repository changed recently (one-off scan, no PR needed)
---

Run a one-off OhMyBug scan of this repository, following the "Repository scan"
section of the `bughunter` skill: confirm the repository and the window with
the user in one line, call `scan_repo`, watch it like any hunt, verify every
finding against this codebase, report verdicts via `confirm_findings` BEFORE
fixing, show the user the bill, then offer what to do with what was found.

A scan is not a merge gate: it hunts the code changed in the last days of the
default branch, not a diff, and it records nothing a gate reads. Never present
it as a review of the current branch.

Arguments: a number is the window in days (default 30, at most 90); anything
else that looks like `owner/name` is the repository to scan instead of this
checkout's `origin`. If the server refuses (`repo_required`, `scan_recent`,
`scan_empty`, `scan_too_big`, `scan_disabled`), show its answer verbatim and
stop; never retry with a different window on your own.
