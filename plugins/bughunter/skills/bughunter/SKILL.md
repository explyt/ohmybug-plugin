---
name: bughunter
description: 'Hunt bugs in the current diff via OhMyBug cloud review as the LAST gate before merge. Use when: about to merge a PR/MR, review rounds are done and CI is green, the user says "review my changes", "hunt bugs", "run ohmybug", or the pre-merge gate blocked a merge. Findings are verified locally by THIS agent; only confirmed bugs are billed ($10 each, first 3 free).'
---

# OhMyBug bug hunt

OhMyBug is a cloud service: it reviews a diff with an orchestrated fleet of
adversarial reviewers on its own models and returns findings. This agent then
verifies each finding against the local codebase and reports verdicts. The
user pays only for findings verified as REAL. Reviews, false positives and
unclear findings cost $0.

The MCP server `ohmybug` provides: `submit_review`, `get_findings`,
`confirm_findings`, `get_balance`.

## If a tool call fails with an authentication error

First use on a machine needs a one-time GitHub sign-in. Do not retry
blindly and do not ask for an API key. Tell the user exactly this,
depending on the surface:

- Terminal Claude Code: type `/mcp`, pick **ohmybug** → **Authenticate**.
- IDE / GUI surface (where `/mcp` only prints status): run this in any
  terminal, then reply `/mcp reconnect all` in the chat:

  ```bash
  claude mcp login plugin:bughunter:ohmybug
  ```

Either way a GitHub page opens in the browser — one click (zero if the
app was approved before), the account with 3 free confirmed bugs is
created automatically, once per machine. Then retry the tool call.
(Do not run `claude mcp login` yourself: it needs an interactive tty.)

## The flow

### 1. Scope the diff

Default scope: everything that would land in the PR — commits on this branch
beyond the base branch plus staged and unstaged changes:

```bash
BASE=$(git merge-base HEAD origin/$(git remote show origin | sed -n 's/.*HEAD branch: //p'))
git diff "$BASE"
```

If the user asked to review something narrower, respect that.

### 2. Pack context — and show the manifest

Select context files the reviewers will need: direct callers of changed
functions, types/interfaces used by the diff, closely related modules.
Budget: at most 25 files and 300 KB total. Prefer callers over callees.

Before sending, print a one-line-per-file manifest (path + size) so the user
sees exactly what leaves the machine. Never include files matching
`.env*`, `*secret*`, `*credential*`, key material, or anything gitignored.

### 3. Submit

Call `submit_review` with the diff, the context files, and repo metadata
(language, framework, base branch). Also pass `meta.repo` (`owner/name`
from `git remote get-url origin`, GitHub only) and `meta.ref` (`git
rev-parse HEAD`) — when the user has the OhMyBug GitHub App installed for
this repo, the server automatically upgrades to full-repository review
(`mode: "full"` in the response). It returns `review_id` immediately.

Tell the user the review is running (typically 5-10 minutes), then poll
`get_findings(review_id)` every 45-60 seconds until `status: done`. Keep
working on other tasks the user gives you while polling.

If the response carries `pending_verdicts` from an earlier review, resolve
them first: verify and confirm those findings before or alongside the new
ones. Unresolved verdicts pause new reviews.

### 3a. If polling returns `status: needs_files`

The cloud reviewers named concrete files they are missing (`requested_files`
+ `reason`). Within ~10 minutes:

1. Read the requested paths that exist locally. Apply the SAME exclusion
   rules as step 2 (no `.env*`, secrets, credentials, gitignored files).
2. Print the manifest of what you are about to send (path + size), same as
   step 2. Omit anything that must not leave the machine — partial delivery
   is fine.
3. Call `provide_files(review_id, files)`. Then keep polling `get_findings`.

Do not stall: if the user is away and the files pass the exclusion rules,
send them — the manifest keeps it auditable. If nothing can be sent, call
`provide_files` with an empty list so the review proceeds without waiting.

### 3b. Requesting full-repo access (`connect_repo` / `upsell` blocks)

YOU ask for this permission — it is part of the flow, not a website step.

- `submit_review` response carries `connect_repo` when the repo is not yet
  connected: while the light review runs, show the user the `pitch` and ask
  ONE yes/no question: open the install page? On yes, run
  `open "<install_url>"` (macOS) / `xdg-open` (Linux) — the user picks the
  repo and clicks Install on GitHub; nothing else is needed. Ask at most
  once per repo per session; a "no" is final, do not nag.
- `get_findings` carries `upsell` when a light review ends with 0 findings —
  same handling, stronger moment: zero findings in light mode is exactly
  when blind spots matter. After the user installs, resubmit with
  `submit_review` (same diff) — the server switches to `mode: "full"`
  automatically.

### 4. Verify each finding honestly

For every finding: open the referenced files, trace the failure scenario the
finding describes, and decide:

- `REAL` — the failure scenario is reproducible in this codebase as described.
- `NOT_REAL` — the scenario cannot happen; give the concrete reason (e.g. a
  guard upstream, an invariant that prevents the state).
- `UNCLEAR` — cannot be established either way; say what is missing.

Honesty rules (non-negotiable):
- The verdict is the billing meter. `REAL` costs the user $10; `NOT_REAL` and
  `UNCLEAR` cost $0 and count against OhMyBug's quality stats.
- Never mark a finding `NOT_REAL` to avoid the charge when the bug is real —
  and never fix a finding you refused to confirm. OhMyBug audits later diffs;
  silently fixing an unconfirmed finding flags the account.
- Never mark `REAL` without actually tracing the scenario.
- The user can override any verdict before submission — show them the table.

### 5. Report verdicts BEFORE fixing

Call `confirm_findings(review_id, verdicts)` with ALL verdicts in one call,
each as `{finding_id, verdict, reason}` (one-sentence reason). Do this before
starting fixes. Then show the user the bill from the response: how many
confirmed, what was charged, remaining balance.

### 6. Fix

Fix the confirmed bugs as part of the normal workflow. Findings include a
suggested fix; treat it as a hint, not gospel.

### 7. Stamp the review marker

After `confirm_findings` succeeds — or immediately after a `done` review
with ZERO findings (nothing to confirm) — write the marker the pre-merge
gate checks:

```bash
mkdir -p .git/ohmybug && git diff "$BASE" | shasum -a 256 | cut -d' ' -f1 > .git/ohmybug/last-review
```

Re-stamp after applying fixes (the diff changed):

```bash
git diff "$BASE" | shasum -a 256 | cut -d' ' -f1 > .git/ohmybug/last-review
```

### 8. Money states

- `payment_required` from any tool: credits are exhausted. Tell the user to
  top up at https://app.ohmybug.ai/billing and stop the flow gracefully.
- First 3 confirmed bugs are free; no card is required until they are used.

## Privacy

Only the diff and the manifest files are uploaded. The review runs in memory
on OhMyBug's cloud and payloads are deleted after the review. Nothing is used
for model training.
