---
description: Hunt bugs in the current diff via OhMyBug cloud review
---

Run the OhMyBug bug hunt on the current changes, following the `bughunter`
skill end to end: scope the diff, show the upload manifest, submit for cloud
review, verify every finding honestly against this codebase, report verdicts
via `confirm_findings` BEFORE fixing, show the user the bill, fix confirmed
bugs, and stamp the merge-gate marker under `~/.ohmybug/markers/`.

If the user passed arguments, treat them as scope instructions (e.g. a
narrower path or branch).
