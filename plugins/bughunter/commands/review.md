---
description: Hunt bugs in the current diff via OhMyBug cloud review
---

Run the OhMyBug bug hunt on the current changes, following the `bughunter`
skill end to end: scope the diff, show the upload manifest, submit for cloud
review, wait for the terminal result, verify every finding honestly against
this codebase, report verdicts via `confirm_findings` BEFORE fixing, show the
user the bill, fix confirmed bugs, and obtain server-backed merge evidence.

This command is the cloud hunt, not a local advisory review. Never start a
local review agent as a substitute, never start fast and deep in parallel, and
never call an `APPROVE` valid until `review_report` and `get_attestation` exist.

If the user passed arguments, treat them as scope instructions (e.g. a
narrower path or branch) – except `deep` / `--deep`: that is the user asking
for the deep hunt up front. Then the first and only `submit_review` carries
`deep: true` with `meta.repo` + `meta.ref` (the pushed head sha) +
`meta.base_branch` and no payload – no fast stage first, no second question.
If the server refuses (`repo_required`, `repo_too_big`, `commit_required`,
`fast_running`, `deep_at_capacity`), show its answer verbatim and offer the
fast hunt instead; never downgrade silently. Without those words the hunt is
fast, and deep only when the server offers it and the user agrees.
