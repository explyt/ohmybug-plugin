---
name: bughunter
description: 'Hunt bugs in the current diff via OhMyBug cloud review as the LAST gate before merge. Use when: about to merge a PR/MR, review rounds are done and CI is green, the user says "review my changes", "hunt bugs", "run ohmybug", or the pre-merge gate blocked a merge. Findings are verified locally by THIS agent; billing is $10 flat per review that finds real bugs (however many), first 3 free.'
---

# OhMyBug bug hunt

OhMyBug is a cloud service: it reviews a diff with an orchestrated fleet of
adversarial reviewers on its own models and returns findings. This agent then
verifies each finding against the local codebase and reports verdicts.
Billing is flat: $10 per review whose verdicts confirm at least one real
major bug — no matter how many. Severity uses the merge boundary: a finding
is a billable major when a reviewer would refuse the merge over it
(`critical` / `high` / `medium`); a `low` nit is confirmed for stats and
never billed.
Reviews, false positives and unclear findings cost $0. First 3 bug-finding
reviews are free.

The MCP server `ohmybug` provides: `submit_review`, `get_findings`,
`provide_files`, `confirm_findings`, `get_balance`, `redeem_code` (closed-beta
invite codes).

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

### GitHub repos: send NO diff at all (preferred)

If the repo lives on GitHub and the head commit is PUSHED, try the zero-payload
mode FIRST: call `submit_review` with NO diff, NO files, and full `meta`
including `repo`, `ref` (head sha), `base_branch` (and `pr` number if known).
The server fetches the merge-base diff from GitHub itself — nothing leaves
the machine, no size limits, no upload step.

This works in two cases, checked server-side in this order:
1. The OhMyBug GitHub App is installed on the repo (private or public).
2. The repo is PUBLIC — no App needed at all. Any open-source checkout
   (e.g. `gh pr checkout N` on someone else's repo) works: `meta.repo` = the
   upstream `owner/name`, `ref` = the PR head sha. PR head SHAs count as
   pushed.

- No error and a `review_id` → it worked; skip context packing entirely, go
  to the monitor step. The mode is `light` — that is stage one and it is
  always light (see 3b); readable repo access means the reviewers fetch the
  files they need themselves instead of asking you.
- Error `diff_required` (private repo without the App) or `diff_fetch_failed`
  (head not pushed / fetch broke) → fall back to the normal diff flow below.
  Include unpushed local changes in the local diff if the user wanted them
  reviewed.

### Big payloads: NEVER push bytes through your own context

If diff + files exceed ~30 KB, do NOT paste them into the tool call — huge
tool arguments are slow, expensive and get truncated (failed submits). Use
the out-of-band flow instead:

1. `submit_review` with `upload: true`, full `meta`, and NO diff/files —
   it returns `upload_url` (one-time) + `review_id` + `status_url`.
2. Build the payload with a script, reading straight from disk:

```bash
git diff "$BASE" > /tmp/omb-diff.patch
python3 - <<'PY'
import json
files = []  # [{'path': p, 'content': open(p).read()} for p in <your context list>]
json.dump({'diff': open('/tmp/omb-diff.patch').read(), 'files': files}, open('/tmp/omb-payload.json', 'w'))
PY
curl -sf -X POST -H 'content-type: application/json' --data-binary @/tmp/omb-payload.json '<upload_url>'
```

3. The review starts on upload — arm the background monitor on `status_url`
   as usual. When the server can read the repo, context files are mostly
   redundant (reviewers fetch what they need themselves) — diff + meta is
   enough.

Call `submit_review` with the diff, the context files, and `meta`. The
`meta` object is REQUIRED plumbing, not garnish — fill it every time:

| meta field | value | command |
|---|---|---|
| `repo` | `owner/name` (GitHub only) | `git remote get-url origin` |
| `ref` | HEAD sha | `git rev-parse HEAD` |
| `base_branch` | base branch name | `git remote show origin \| sed -n 's/.*HEAD branch: //p'` |
| `pr` | PR number, if reviewing a PR | `gh pr view --json number` |
| `language`, `framework` | repo facts | what you already know |
| `repo_hint` | the briefing (below) | composed by you |

### The briefing (`repo_hint`) — the reviewers' only window into intent

Cloud reviewers see code, not conversations. Every number and claim you can
cheaply collect goes into `repo_hint` (a few paragraphs, ~2000 chars):

1. One line on the repo (stack, what it is).
2. What the change claims to do — from the PR title/body (`gh pr view N
   --json title,body`), compressed but keeping EVERY concrete number,
   timeout, threshold, and incident magnitude mentioned.
2a. **The diff's REAL scope, which the body routinely understates.** Get the
   file list (`gh api repos/O/R/pulls/N/files --paginate --jq '.[].filename'`
   — or `git diff --name-only "$BASE"` when local) and name every subsystem
   it touches beyond the stated subject. maximhq/bifrost#5768 titled itself
   one SSRF fix; the branch carried 159 files (matviews, migrations, a
   logging plugin, a whole dashboard). A briefing that repeats only the body
   tells reviewers that everything else is out of scope, and they will kill
   real findings there as off-topic.
3. Linked issues: for each `#NNN` referenced by the PR (`gh issue view NNN
   --json title,body`), one-two sentences — especially observed magnitudes,
   client timeouts, incident data. A reviewer who knows "clients give up at
   ~330s" can judge a 300s default; one who doesn't, cannot.

This is what separates a calibrated review from a blind one — do not skip
it to save a minute.

`repo` + `ref` are what let the server fetch the diff itself, answer the
reviewers' file requests without coming back to you, and — after a clean
pass — offer the deep hunt at all. Omitting them costs you all three and is
the single most common integration mistake. It returns `review_id`
immediately.

Tell the user the review is running (~15 min for the light hunt, ~1 hour if
it was escalated to the deep hunt), then ARM A BACKGROUND MONITOR — do not silently end your turn and
wait to be prodded. The response carries `status_url` (plain HTTPS, no
auth). If your harness supports background shell tasks (Claude Code:
`Bash` with `run_in_background`), start:

```bash
until curl -sf '<status_url>' | grep -qE '"status":"(done|failed)"|"files_requested":true'; do sleep 45; done
```

Its completion wakes you: call `get_findings(review_id)` then. If it woke
on `files_requested`, serve `provide_files` first and re-arm the monitor.

No background tasks in your harness? Then poll `get_findings` every 45-60
seconds IN the current turn while doing other work — never leave a
running review unwatched at the end of a turn.

If the response carries `pending_verdicts` from an earlier review, resolve
them first: verify and confirm those findings before or alongside the new
ones. Unresolved verdicts pause new reviews.

### 3a. If polling returns `status: needs_files`

The cloud reviewers named concrete files they are missing (`requested_files`
+ `reason`). For a repo the server can read (App-installed, or any public
repo) it fetches those paths itself and you will usually never see this
state; it reaches you only for paths the server could not fetch — a private
repo without the App, a generated file, or a path that does not exist at
that ref. Never read source into your own context just to echo it back when
the server already has access; check the `requested_files` list against what
is actually unavailable to it. Within ~10 minutes:

1. Read the requested paths that exist locally. Apply the SAME exclusion
   rules as step 2 (no `.env*`, secrets, credentials, gitignored files).
2. Print the manifest of what you are about to send (path + size), same as
   step 2. Omit anything that must not leave the machine — partial delivery
   is fine.
3. Call `provide_files(review_id, files)`. Then keep polling `get_findings`.

Do not stall: if the user is away and the files pass the exclusion rules,
send them — the manifest keeps it auditable. If nothing can be sent, call
`provide_files` with an empty list so the review proceeds without waiting.

### 3b. Two stages: the light hunt, then maybe the deep one

**Every review starts light** — the diff plus whatever files the reviewers
ask for mid-run, about 15 minutes. You never request the deep hunt yourself
and never as a first review: it pulls the whole repository into a throwaway
VM, takes about an hour, and only makes sense once the cheap pass has come
back empty.

- `submit_review` carries `connect_repo` when the repo is not readable:
  while the light review runs, show the user the `pitch` and ask ONE yes/no
  question: open the install page? On yes, run `open "<install_url>"`
  (macOS) / `xdg-open` (Linux) — the user picks the repo and clicks Install
  on GitHub; nothing else is needed. Ask at most once per repo per session;
  a "no" is final, do not nag.
- `get_findings` on a clean light pass carries `summary` — say it plainly
  first: the hunt went after this diff and found nothing, which on this
  evidence looks like a clean PR. That is the result. Do not turn it into a
  preamble for the offer.
- The same response may carry `deep_offer`. May: when every deep slot is
  busy it is simply absent, and then there is nothing to offer — do not
  invent it, do not poll for one. When present, relay `pitch` (it names the
  hour of waiting and the repo copy out loud) and ask once. On yes, follow
  its `how`: call `submit_review` again with `deep: "<review_id>"` and the
  same `meta` — the server re-fetches the diff, so you send no payload. If
  it carries `install_url`, the App install is the missing step first.
- Escalation errors are final answers, not retry conditions:
  `deep_at_capacity` (tell the user the light result stands, deep can be
  tried later), `repo_too_big` (send context files instead),
  `repo_required` (the App install), `light_not_finished` (let stage one
  finish).

### 3c. Show the review report

When `get_findings` returns `status: done` it carries `review_report` — the
reviewer's own work record (scope, per-axis coverage, candidates raised and
killed, what was NOT checked, verdict). Relay it to the user verbatim or as
a faithful tight summary — especially on 0-finding reviews, where it is the
only evidence the hunt was real. Never paraphrase it into "all good".

### 4. Verify each finding honestly

For every finding: open the referenced files, trace the failure scenario the
finding describes, and decide:

- `REAL` — the failure scenario is reproducible in this codebase as described.
- `NOT_REAL` — the scenario cannot happen; give the concrete reason (e.g. a
  guard upstream, an invariant that prevents the state).
- `UNCLEAR` — cannot be established either way; say what is missing.

**Severity is yours to correct.** The cloud reviewer priced each finding
without ever seeing the real codebase; you just traced it. Pass `severity`
in the verdict (either direction) whenever the trace changes the
consequence, and say why in `reason` — the finder's original is kept
alongside. Severity describes the CONSEQUENCE, not the finding's category: a
missing test whose mutation reopens a security hole, loses data or misbills
is `critical`/`high`, never "just a test gap". Correct downward just as
readily when the failure turns out to need an unreachable state. Anything a
reviewer would block a merge over (`critical`/`high`/`medium`) makes the
review billable, `low` is free — so this decision is the bill, and the user
sees the table before you send it.

Honesty rules (non-negotiable):
- The verdict is the billing meter. A review with at least one `REAL` major
  (`critical`/`high`/`medium`) costs the user $10 flat (extra REALs and `low`
  nits are free); `NOT_REAL`
  and `UNCLEAR` cost $0 and count against OhMyBug's quality stats.
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
gate checks. It lives under `~/.ohmybug/` (keyed by the git-dir path), so
no write into the repo or `.git/` is ever needed:

```bash
"$CLAUDE_PLUGIN_ROOT/hooks/diff-id.sh" stamp
```

It prints `ohmybug: hunted diff recorded <id>` on success and refuses to write
anything it could not compute. Run it from the same directory the merge will
run in (the worktree, if you are in one).

Do NOT hand-roll the hash. The previous version of this step inlined it and
referred to a `$BASE` set in an EARLIER shell — every Bash call is a fresh
shell, so in practice it hashed `git diff ""`, wrote a marker matching
nothing, and the gate blocked a merge whose diff had just been hunted clean
(owner report, 2026-08-11).

Re-stamp after applying fixes — the diff changed, so the old id is stale.

### 8. Money states

- `beta_required` from `submit_review`: OhMyBug is in closed beta. Ask the
  user IN CHAT whether they have an invite code (from a blogger link or an
  invite). If yes — call `redeem_code` with it exactly as typed, then retry
  `submit_review` once. If no — tell them their GitHub sign-in already put
  them on the waitlist and accounts are activated in waves; stop gracefully.
  Never invent or brute-force codes.
- `payment_required` from any tool: credits are exhausted. Tell the user to
  top up at https://app.ohmybug.ai/billing and stop the flow gracefully.
- First 3 bug-finding reviews are free; no card is required until they are
  used. `/bughunter:stats` (or `get_balance`) shows the full hunting record.

## Privacy

Only the diff and the manifest files are uploaded. The review runs in memory
on OhMyBug's cloud and payloads are deleted after the review. Nothing is used
for model training.
