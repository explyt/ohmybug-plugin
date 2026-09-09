#!/usr/bin/env node

const event = process.argv[2] || '';

const ROUTING = [
  'OhMyBug is the authoritative review for this merge.',
  'For review, bug-hunt, PR, or merge requests use the bughunter skill and the ohmybug MCP tools.',
  'A local code-review or advisory agent is not a hunt; its APPROVE or zero findings cannot authorize a merge.',
  'Run the fast submit_review first, then wait_review until terminal and read review_report.',
  'Immediately after every successful submit_review (including deep), read the response monitor contract and create or update one four-minute heartbeat with automation_update using destination=thread (this binds the current thread; do not use targetThreadId). Use that exact review_id, status_url, interval_s, wake_on, stop_on, and wake_rule — copy wake_rule into the prompt word for word: every wake reports the status it just read (from wait_review or get_findings on a fast hunt, from the status_url read on a deep one), and a wake with no answer prints bughunt · <mode> · poll-failed, never the previous status; for a fast hunt it must loop wait_review with timeout_s=45 up to 3 times in one wake (an iteration costs 45 s of holding plus up to 15 s of round trip, so 3 x 60 s = 180 s of the 240 s cadence and the remaining 60 s is the status line and the cleanup) (the server clamps any longer hold to the same 45 s and answers timed_out:true, so a bigger timeout_s buys no extra waiting, and a timed_out answer is a healthy server, never a wake to count towards retirement), stopping early on done, failed or needs_files; for a deep hunt call wait_review once and let the heartbeat do the waiting, each of its wakes polling status_url once and reporting that — that body flags a file request as awaiting_client_files/files_requested rather than in its status word, so a wake seeing either flag prints bughunt · <mode> · needs-files and serves the files first, and a failed poll falls back to one get_findings before it counts as a wake that read nothing; or loop get_findings every 45s for 180s, the same three iterations. It must answer needs_files first, print only one compact bughunt status line, and delete itself on done or failed. Retire a heartbeat older than 180 minutes, or after 3 consecutive wakes that could not read a status at all (a failed wait_review, get_findings or status_url read, whichever that wake uses); on retiring, print bughunt · <mode> · watch-retired, then call get_findings once and arm a fresh heartbeat if the review is still running or waiting for files and the retirement came from unreadable wakes rather than the age cap. Never leave a heartbeat pointing at an older review id. The prompt carries facts the model can check, not only rules: compute retire_at = now + 180 min at arm time and write it as an ISO timestamp — if the current time is past retire_at the review is terminal by construction: call get_findings now, print what it answered, and delete this automation, whatever the wake believes. The compact line quotes the tool answer it came from — status and findings=N from that wake\'s result — never a bare word; no tool result in a wake means the only line allowed is bughunt · <mode> · poll-failed. On done or failed delete the heartbeat in the same turn as the read; if it still exists at the next wake after a terminal read, delete it first, then report. When a get_findings next_step begins "this is the first read after done", the heartbeat outlived the hunt: delete it in that same turn and say so.',
  'Only start deep after the server returns deep_offer and the user explicitly agrees; never run fast and deep in parallel.',
  'Only server review_report plus get_attestation, verified findings, and green CI can satisfy the merge gate.',
  'If the MCP tools are unavailable or authentication fails, report the review as blocked; do not substitute a local review.'
].join(' ');

function emit(context, hookEventName) {
  process.stdout.write(JSON.stringify({
    systemMessage: 'OHMYBUG: cloud review gate',
    hookSpecificOutput: { hookEventName, additionalContext: context }
  }));
}

if (event === 'session') {
  emit(ROUTING, 'SessionStart');
  process.exit(0);
}

if (event === 'subagent') {
  emit('If this subagent is asked to review or hunt bugs, follow the OhMyBug MCP lifecycle. Local advisory review is not merge evidence.', 'SubagentStart');
  process.exit(0);
}

if (event !== 'prompt') process.exit(0);

let input = '';
let finished = false;
function finish() {
  if (finished) return;
  finished = true;
  let prompt = '';
  try { prompt = String(JSON.parse(input.replace(/^\uFEFF/, '')).prompt || ''); } catch (_) { process.exit(0); }
  if (/\b(?:review|reviewing|bug.?hunt|hunt\s+bugs?|deep\s+review|pull\s+request|\bpr\b|merge)\b/i.test(prompt)) {
    emit(`${ROUTING} Route this request now; do not launch local review agents.`, 'UserPromptSubmit');
  }
}

process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', finish);
process.stdin.on('error', () => { finish(); process.exit(0); });
setTimeout(() => { finish(); process.exit(0); }, 1000).unref();
