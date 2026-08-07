# OhMyBug plugin — bughunter

We find the bugs your Claude Code missed. You pay only for bugs your own
Claude confirms. $10 a bug, first 3 free.

## Install (Claude Code)

```bash
export OHMYBUG_API_KEY=omb_...   # your key from https://app.ohmybug.ai (add to your shell profile)
claude plugin marketplace add explyt/ohmybug-plugin
claude plugin install bughunter@ohmybug
```

The plugin reads `OHMYBUG_API_KEY` from your environment on every call —
no key ends up in any config file.

## Install (Codex CLI)

```bash
npx skills add explyt/ohmybug-plugin --skill bughunter
codex mcp add ohmybug --url https://mcp.ohmybug.ai/mcp \
  --header "Authorization: Bearer $OHMYBUG_API_KEY"
```

## What it does

- Before every `gh pr create`, a gate checks the diff was reviewed
  (skip once with `SKIP_BUGHUNT=1`).
- `/bughunter:review` (or just ask to "hunt bugs") sends your diff + selected
  context to OhMyBug's cloud. You see the exact file manifest before upload.
- An orchestrated fleet of adversarial reviewers hunts on OhMyBug's models.
  Only findings that survive triage come back.
- Your own agent verifies each finding against your codebase and reports
  REAL / NOT_REAL / UNCLEAR. You see and approve the verdicts.
- Billing: confirmed (REAL) bug — $10. Review runs, false positives,
  unclear findings — $0.

## MCP contract (server: https://mcp.ohmybug.ai/mcp)

| Tool | In | Out |
|---|---|---|
| `submit_review` | `diff`, `files[{path, content}]`, `meta{language?, base_branch?}` | `{review_id, status, pending_verdicts[]}` |
| `get_findings` | `review_id` | `{status: running\|done\|failed, findings[{finding_id, severity, file, line?, title, failure_scenario, suggested_fix?}]}` |
| `confirm_findings` | `review_id`, `verdicts[{finding_id, verdict: REAL\|NOT_REAL\|UNCLEAR, reason}]` | `{billed_usd, confirmed, balance_usd, receipt_id}` |
| `get_balance` | — | `{balance_usd, free_bugs_left, confirmed_total}` |

Errors: `payment_required` (top up), `pending_verdicts` (resolve previous
review's verdicts first).
