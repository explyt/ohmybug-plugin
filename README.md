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

## Install (pi)

[pi](https://pi.dev) has no built-in MCP — add the adapter, then the server:

```bash
pi install npm:pi-mcp-adapter
npx skills add explyt/ohmybug-plugin --skill bughunter
```

Add to `.mcp.json` in your project root (or `~/.config/mcp/mcp.json`):

```json
{
  "mcpServers": {
    "ohmybug": { "url": "https://mcp.ohmybug.ai/mcp", "auth": "oauth" }
  }
}
```

Restart pi, run `/mcp-auth ohmybug` once — a GitHub page opens in the
browser, your account with 3 free bug-finding reviews is created
automatically. Then say "hunt bugs" or `/skill:bughunter`.

Prefer a raw key (CI)? Use `"auth": "bearer", "bearerTokenEnv":
"OHMYBUG_API_KEY"` instead of `"auth": "oauth"`.

Optional merge gate (pi has blocking tool hooks) — `.pi/extensions/ohmybug-gate.ts`:

```ts
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";

pi.on("tool_call", async (event) => {
  if (isToolCallEventType("bash", event) && /\bgh pr merge\b/.test(event.input.command)
      && !process.env.SKIP_BUGHUNT) {
    return { block: true, reason: "Final diff not hunted — run /skill:bughunter first (or SKIP_BUGHUNT=1)" };
  }
});
```

## Install (Codex app / CLI)

The plugin package wires the skill, MCP server, and Codex review routing in one
install. Codex uses the same GitHub OAuth flow as Claude Code:

```bash
codex plugin marketplace add explyt/ohmybug-plugin
codex plugin add bughunter@ohmybug
codex mcp login ohmybug
```

Start a new Codex thread after installation so the skill, MCP tools, and routing
hook are loaded. Then ask Codex to run the OhMyBug cloud hunt (or use the
plugin's starter prompt). A local `APPROVE` from a code-review agent is not
merge evidence.

### Existing skill-only installs

If the plugin was installed with `npx skills add`, keep the skill and add the
same MCP server explicitly:

```bash
npx skills add explyt/ohmybug-plugin --skill bughunter
codex mcp add ohmybug --url https://mcp.ohmybug.ai/mcp
```

`codex mcp add` detects OAuth and opens the GitHub sign-in flow automatically.

For headless CI, use an operator-issued raw `omb_` key — write to
[hi@ohmybug.ai](mailto:hi@ohmybug.ai) or DM [@ohmybug](https://x.com/ohmybug)
to get one:

```bash
export OHMYBUG_API_KEY=omb_...
codex mcp add ohmybug --url https://mcp.ohmybug.ai/mcp \
  --bearer-token-env-var OHMYBUG_API_KEY
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
