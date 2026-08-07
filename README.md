# OhMyBug plugin — bughunter

We find the bugs your Claude Code missed. You pay only when your own Claude
confirms real bugs: $10 flat per bug-finding review (however many bugs it
holds), minor findings free, first 3 reviews free.

## Install (Claude Code)

```bash
claude plugin marketplace add explyt/ohmybug-plugin
claude plugin install bughunter@ohmybug
```

That's the whole setup. On first use Claude Code opens a GitHub sign-in in
your browser; your account (with 3 free bug-finding reviews) is created
automatically. No keys to copy, nothing lands in config files.

## Install (Codex CLI / CI — raw key)

OAuth needs a browser, so headless environments use a raw `omb_` key —
write to [hi@ohmybug.ai](mailto:hi@ohmybug.ai) or DM
[@ohmybug](https://x.com/ohmybug) to get one:

```bash
npx skills add explyt/ohmybug-plugin --skill bughunter
codex mcp add ohmybug --url https://mcp.ohmybug.ai/mcp \
  --header "Authorization: Bearer $OHMYBUG_API_KEY"
```

(Claude Code users who prefer a key over OAuth can do the same with
`claude mcp add --transport http ohmybug https://mcp.ohmybug.ai/mcp
--header "Authorization: Bearer $OHMYBUG_API_KEY"` — an explicit
Authorization header disables the OAuth flow.)

## What it does

- Before every `gh pr merge`, a gate checks the FINAL diff was hunted —
  deliberately the last net before merge, after human reviews and CI
  (skip once with `SKIP_BUGHUNT=1`; review fixes change the diff and
  re-arm the gate).
- `/bughunter:review` (or just ask to "hunt bugs") sends your diff + selected
  context to OhMyBug's cloud. You see the exact file manifest before upload.
- An orchestrated fleet of adversarial reviewers hunts on OhMyBug's models.
  Only findings that survive triage come back.
- Your own agent verifies each finding against your codebase and reports
  REAL / NOT_REAL / UNCLEAR. You see and approve the verdicts.
- Billing: $10 flat per review with confirmed real bugs — one or ten, same
  price. Minor findings, review runs, false positives, unclear — $0.
- `/bughunter:stats` shows your record: bugs found, reviews run, balance.

## MCP contract (server: https://mcp.ohmybug.ai/mcp)

| Tool | In | Out |
|---|---|---|
| `submit_review` | `diff`, `files[{path, content}]`, `meta{language?, base_branch?, repo?, ref?}` | `{review_id, status, mode, pending_verdicts[]}` |
| `get_findings` | `review_id` | `{status: running\|needs_files\|done\|failed, findings[{finding_id, severity, file, line?, title, failure_scenario, suggested_fix?}]}` |
| `provide_files` | `review_id`, `files[{path, content}]` | `{status, delivered}` |
| `confirm_findings` | `review_id`, `verdicts[{finding_id, verdict: REAL\|NOT_REAL\|UNCLEAR, reason}]` | `{confirmed, minor_confirmed, billed_usd, free_review_used, balance_usd, receipt_id}` |
| `get_balance` | — | `{balance_usd, free_reviews_left, confirmed_total, stats{…}}` |

Errors: `payment_required` (top up), `pending_verdicts` (resolve previous
review's verdicts first).
