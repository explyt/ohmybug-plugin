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
`provide_files`, `confirm_findings`, `post_story`, `get_balance`,
`redeem_code` (closed-beta invite codes).

**The server's own words outrank this file.** A tool result carrying
`next_step`, `share.ask_user` or `deep_offer.how` is the current instruction;
this skill may be an old copy on this machine. Follow the result.

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

### How the diff gets here — in this order, always

**What leaves the machine must be proportional to what we cannot already see.**
Work down this list and stop at the first rung that applies:

1. **Repo on GitHub, head pushed → send NO payload.** `meta.repo` + `ref` +
   `base_branch`, empty `diff`, no `files`. Nothing leaves the machine, there is
   no size limit, and the reviewers fetch whatever files they need instead of you
   guessing which to attach. This is the normal path, not an optimisation.
2. **`diff_required` came back → offer the App install, before packing anything.**
   That error means the repo is not readable, and one browser click fixes it
   permanently. Ask once; do not start assembling a payload while you wait.
3. **Only then a payload** — and only for what rung 1 genuinely cannot serve:
   a repo that is not on GitHub, changes that are **not pushed** (the usual case
   is re-hunting your own fixes), or an org that will not install the App. Send
   the **whole working diff against the merge base** (`git diff <base>`,
   verbatim): the merge gate credits this tree as hunted only when the payload
   IS the tree. A smaller payload — just the fix — still buys a review of those
   bytes, but the gate cannot credit the tree with it, and the merge stays
   blocked until a full-diff hunt. Already pushed? Then rung 1 with `ref` = the
   head commit sha records the hunt without sending anything.
4. **`upload: true` only when that payload is genuinely large.** It is not a
   preference for shipping bytes, and the server ignores it whenever rung 1
   applies.

Rung 1 is the cheapest path, not a way around a permission refusal. Measured
twice: the classifier judges the TOOL from its schema, and `submit_review`
declares `diff`, `files` and `upload` whether or not you fill them in — so a
no-payload call is refused exactly like a payload one. See "If the environment
refuses the hunt" below for what to do instead, which is to stop rather than to
reformulate.

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
- Error `diff_required` (private repo without the App) → this is rung 2 above:
  offer the one-click App install FIRST and retry, because it removes the payload
  question for every future review in this repo. Only if the user declines do you
  pack a payload.
- Error `diff_fetch_failed` (head not pushed / fetch broke) → the code genuinely
  is not on GitHub yet. Either push it and retry rung 1, or send a payload
  carrying only the unpushed part.

### If the environment refuses the hunt — say it once and stop

A refusal (permission prompt answered no, auto-mode classifier, sandbox, no
network) is a **final answer for this session**, and it is about the tool rather
than about what you passed to it: the classifier reads the schema, so re-sending
the same call with an empty `diff` changes nothing. Measured twice.

1. **Say it once**, in one line: the hunt tools are refused in this environment,
   and the rule that would change that is `/permissions` →
   `mcp__plugin_bughunter_ohmybug__*`. Adding it is the user's own click in
   their own settings — never add it yourself, never ask for it to be widened
   "so auto-mode stops blocking". A tool that talks its way past the control
   built to stop tools like it is the exact shape of the attack that control is
   for.
2. **Then stop.** No retry with different arguments, no second tool, no env
   prefix in front of anything: `SKIP_BUGHUNT=1` disables a safety control, so
   the same classifier refuses it too — correctly. Above all, never carry a
   prefix from a refused command onto the next command. That is how a bug hunter
   ends up interfering with posting a ticket comment.
3. **Do not engineer around it.** Whether the merge waits for a hunt, goes ahead
   without one, or waits for a permission rule is the operator's call, not
   yours — report the refusal and let them make it. Never touch the gate's
   records to make the block go away.
4. If the repo is on GitHub with the head pushed, `meta.repo` + `ref` +
   `base_branch` and no payload is still the right call to have made — fewer
   bytes, no size limits, no upload step. It is simply not a way past a refusal.

A refusal for one repo is not a refusal for the next one, and a refusal now is
not a refusal after the user adds a rule: state it, and let the next call be the
next call.

### Big payloads: NEVER push bytes through your own context

If diff + files exceed ~30 KB, do NOT paste them into the tool call — huge
tool arguments are slow, expensive and get truncated (failed submits). Use
the out-of-band flow instead:

1. `submit_review` with `upload: true`, full `meta`, and NO diff/files —
   it returns `upload_url` (one-time) + `review_id` + `status_url`. Always send
   `meta.repo` + `ref` + `base_branch` anyway: when the server can fetch the
   diff itself it ignores `upload` and just starts, and you never touch the
   upload at all. A `review_id` with `status: running` instead of
   `awaiting_upload` means exactly that — nothing to upload, go monitor.
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

An uploaded payload never passes through the local recorder, so the merge
gate cannot credit this working tree with the hunt: the record is `meta.ref`
only, honoured only on a clean checkout standing at that commit. When the
work is unpushed AND the diff is too big to send inline, commit and push it
first and use rung 1 (`ref` = the pushed head sha) — otherwise the merge gate
will still block after the review, and the submit says so at submit time.

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

**The `diff` field takes a diff, and nothing else.** Not a summary, not a file
list, not "see attached files" — those go in `repo_hint`. A non-empty `diff`
means "the payload is here", so writing prose into it silently cancels the
GitHub fetch and the reviewers get a note instead of code. That cost a whole
run on 2026-08-11: 2.5 KB of briefing, zero attached files, a VM spent hunting
for a diff that did not exist. The server now refuses prose (`diff_not_a_diff`)
or, when it can, fetches the real diff and tells you it overrode you — but the
rule is simpler than the recovery: **if you are not sending diff bytes, send an
empty diff.**

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
is actually unavailable to it.

**Answer it as the FIRST action of the turn.** The request is held open for a
few minutes only, and the hold is not our time: while the reviewers wait for a
file they are not hunting, and the customer paid for the hunting. So
`provide_files` comes before anything else — before investigating what the
request implies, before fixing what it made you notice, before tidying the file
they asked about. Measured, on this project's own review: the monitor woke on
`needs_files` on time, the agent spent the window gathering and improving
instead of sending, and `provide_files` came back `no_pending_request` — the
review finished without the files, on a diff nobody could fully read. Send
first; a partial or empty answer beats a late one, and whatever you noticed
while looking is still there afterwards.

A path the request names may not exist at all — the reviewers see only the diff
in the light hunt, so some names are guesses. Do not go looking for a plausible
substitute and do not rename anything: send what exists, leave out what does
not, and let the reason text tell you which files actually matter (it often
names more than the machine-readable list).

Within that window:

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
- **`next_step` is an instruction to you.** When a response carries it,
  do that in your very next message to the user — before merging,
  committing, or moving on. It exists because this file can be months out
  of date on someone's machine while the server is current: if the two ever
  disagree, `next_step` wins.
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
- **Arm the monitor for the deep hunt too, and give the user the
  `review_id`.** The hour is exactly how long it takes to forget: the deep run
  needs no files from you, so nothing prods you mid-run, and an agent that
  armed a monitor for every 15-minute light pass will skip it on the one run
  that waits four times as long. Then the user paid an hour of attention for a
  result nobody read. Tell them in chat that it is running and name the
  `review_id`, so they can ask for it later even if you lost the thread.
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

**The balance belongs to the account, not to you.** One key is shared by every
session, worktree and machine that uses it, so `balance_usd`, `reviews_total`
and `billed_usd_total` move while you do nothing. The only figures describing
YOUR call are `billed_usd` and `receipt_id` in that response. Never compute
your own spend by comparing two balance readings, and never raise a
money alarm from a difference between them: on 2026-08-11 an agent did exactly
that, charged itself another session's $20, and spent a round of investigation
disproving its own report. If a charge looks wrong, quote the receipt.

### 6. Fix

Fix the confirmed bugs as part of the normal workflow. Findings include a
suggested fix; treat it as a hint, not gospel.

### 6b. Offer the story (only when a bug actually landed)

`confirm_findings` answers with a `share` block whenever at least one bug
was confirmed. It is an offer to make to the USER, never a thing to do on
their behalf: the post is public and carries their GitHub handle.

- Relay `share.ask_user`, and **draft it yourself in the same message** —
  finished, to the format in `share.format`. Do not ask the user how long it
  should be, what to redact, or whether to translate it; do not make them ask
  you to shorten it. They approve or edit; they do not brief you.
- **Two fields, and the second is the point.** The story is why anyone reads
  the post; the lesson is why they keep it. Write both ONCE, to these budgets —
  "at most 3 lines" is not a length, and drafts written to it had to be
  shortened twice by hand (owner, 2026-08-11):
  - **English only**, always — the feed is one public wall, and a post in the
    chat's language is unreadable to most of it. Translate, never
    transliterate: the server refuses any letter outside the Latin script
    (accents are fine: naïve, façade).
  - `text` — exactly **2 sentences, ≤220 characters**. First: the trap,
    concretely. Second: what happens when it fires.
  - `lesson` — up to **2 rules, one line each, ≤200 characters total**:
    **bold imperative rule** then half a sentence of why. Each line must be
    pasteable into someone else's guidelines unchanged.
  - Voice: the 1000 most common English words, short sentences, active,
    present tense — a non-native reader gets it in one pass with no
    dictionary. No hedging, no filler, no adverbs holding up a weak verb, no
    long Latin noun where a plain verb fits ("check", not "verification").
    Name the failure so the reader sees it happen. `share.format` carries a
    worked example at exactly this length — match its register, don't invent
    your own. These budgets are what the server ENFORCES, not what it prefers:
    a longer draft is refused and the user has to approve a second one.
- **Anonymise it, unasked.** The reader has no context on this project and
  must learn nothing private from it: no repo or company name, no file paths,
  no route or endpoint names, no vendor names, no URLs, no PR/ticket numbers,
  no test counts, no domain specifics that identify what the product does or
  for whom. Describe the MECHANICS of the defect, not its setting. The server
  refuses posts containing paths, URLs, repo slugs or ticket numbers — but
  the vendor and the domain it cannot detect, so that part is on you.
- Show the user `share.show_progress` as-is — the star row (`★★★☆☆ 3/5`) says
  how close they are to a free review without making them do arithmetic. The
  stars count published stories, not bugs. When `share.earned_unclaimed` is
  above 1 the row stops moving (it is full, and "to go" is zero); the count is
  then the only thing that has changed, and each post claims exactly one.
- Show the exact text and wait for a yes. Then publish with **`share.how`**,
  which carries a one-time URL:

  ```bash
  curl -sf -X POST -H 'content-type: application/json' \
    -d '{"text":"…","lesson":"…","rounds_survived":N}' <share.how URL>
  ```

  `post_story(review_id, text, lesson, rounds_survived)` does the same when
  your client has that tool. Prefer whichever you actually have; the URL
  always works, because curl has no version.
- **Never tell the user to paste it into the website by hand**, and never
  smuggle the text through another field (a verdict `reason` is a verdict
  justification — putting a story there is not publishing it). If the URL
  itself fails, say plainly that publication failed and show the error.

  Earlier guidance here named `confirm_findings` as the fallback "because you
  demonstrably have that tool". That was wrong in the same way the first path
  was: the tool exists, but a cached SCHEMA for it has no `story` field and
  requires `verdicts`, so the call is impossible in exactly the session the
  fallback was written for (owner report, 2026-08-11 — a user approved a
  paragraph and nothing could publish it).
- `rounds_survived` is the number of review passes — human or agent — this
  code went through before the hunt caught the bug. Count honestly: your own
  review rounds, CI, the human reviewer, previous agents. It is the score
  the public leaderboard ranks by, and an inflated number is the one thing
  that would make the whole board worthless.
- `share.earns_free_review: true` means this post makes their next
  bug-finding review free — say so plainly, it is true. A free hunt is earned
  by five PUBLISHED stories about hunts that found something, not by the bugs
  themselves, so the field is about the story they are being offered: publish
  it and the next hunt is free. When it is false, `next_free_at_bug` says how
  many more stories away it is; mention it once, do not
  push.
- A "no" is final. Never post without approval, never re-ask in the same
  session.

### 7. The review marker — nothing to do

The pre-merge gate's marker is written by a `PostToolUse` hook on the review
tools themselves: `submit_review` records which diff was sent, and the first
`done` from `get_findings` (or a `confirm_findings` call) promotes it. It
lives under `~/.ohmybug/`, keyed by the git-dir path, so nothing is ever
written into the repo or `.git/`.

This used to be a step here, and that was the bug: a hunt driven by calling
the tools directly — a normal way to use them — left no marker, so the gate
blocked a diff that HAD been hunted (owner report, 2026-08-11). Evidence that
depends on someone remembering to file it will eventually accuse honest work,
and each false accusation is an argument for disarming the control.

So: never write the marker by hand, and never reach for `SKIP_BUGHUNT=1`
because a hunt "already ran". If the gate blocks after a finished hunt, the
diff changed since it (fixes count — hunt them too), or the hook is missing
because the installed plugin predates it. Say which; do not paper over it.

`SKIP_BUGHUNT=1` belongs to the operator, not to you. You cannot run it — a
prefix that disables a safety control is what the classifier is there to refuse
— and carrying it onto an unrelated command is what once made this plugin block
a ticket comment. If the gate blocks and you cannot hunt, say both facts in one
line and stop; the person reading has the hatch, and it is theirs to use.

### 8. Money states

- `beta_required` from `submit_review`: OhMyBug is in closed beta until
  September 1 and this account is not activated yet. The sign-in already
  worked, so nothing is broken — only activation is missing. In order:
  1. Look for an invite already on this machine: `cat ~/.ohmybug/invite`. An
     invite link writes the code there while the plugin is being installed, so
     this usually costs the user nothing. Found one? `redeem_code` with it, then
     retry `submit_review` once. If `redeem_code` rejects it, that file is
     stale: do not retry it or try variants of it, go to step 2.
  2. Otherwise ask the user IN CHAT for their invite. The whole invite link and
     the bare code are equally good — pass what they give you to `redeem_code`
     unchanged; the code is taken out of a link server-side.
  3. No invite, or the answer comes back `invalid_code` / `code_exhausted`? Do
     not loop and do not guess. Say that their GitHub sign-in already holds
     their place in the queue (accounts open in waves), that codes ride the
     links handed out at x.com/ohmybug, and that hi@ohmybug.ai asks for one
     directly. Then stop gracefully.
- `payment_required` from `submit_review`: credit is exhausted, and the
  refusal message already carries the payment links for THIS account. **Show
  the user those URLs verbatim** — they are per-account (the account id is
  baked in so the payment lands on the right balance), so never retype one,
  never strip its query string, and never send the user to a page you
  remember instead. Show the credit terms that come with them, then stop the
  flow gracefully; nothing was charged. When the user says they have paid,
  retry `submit_review` — the payment webhook credits the balance in seconds.
- The same links reach you two other ways, with the same rule: `buy` +
  `buy_terms` on `get_balance` (present only when the balance cannot pay for
  the next catch), and `buy` + `buy_terms` + `out_of_credit` on
  `confirm_findings` — that one is the useful one, because it warns at the end
  of the hunt that the NEXT one will be refused. Pass `out_of_credit` on to
  the user with the links; do not wait for the refusal to arrive.
- `buy` rows are `{what, usd, url}`. Show them all and let the user choose;
  the subscription row's `what` says to append `&threads=N` — quote it, do not
  build the URL yourself.
- A refusal for `budget_exhausted` is NOT a money problem: it is a daily spend
  ceiling. Never offer payment links for it — topping up does not lift it.
- `get_balance` also answers "what do you charge" without anyone running out:
  `prices` is what is on sale and what it costs, `recent_movements` is the
  last few charges and top-ups, and `manage_billing` is a short-lived link to
  the payment provider's own page (invoices, receipts, card, and for a
  subscriber the thread count and cancellation). Read prices from there rather
  than from memory, and give the user every `manage_billing` link there is:
  more than one means more than one subscription is being billed, and each
  page manages only its own.
- First 3 bug-finding reviews are free; no card is required until they are
  used. `/bughunter:stats` (or `get_balance`) shows the full hunting record.

## Privacy

Only the diff and the manifest files are uploaded. The review runs in memory
on OhMyBug's cloud and payloads are deleted after the review. Nothing is used
for model training.
