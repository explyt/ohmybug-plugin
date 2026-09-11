#!/usr/bin/env node

const event = process.argv[2] || '';

const ROUTING = [
  'OhMyBug is the authoritative review for this merge.',
  'For review, bug-hunt, PR, or merge requests use the bughunter skill and the ohmybug MCP tools.',
  'A local code-review or advisory agent is not a hunt; its APPROVE or zero findings cannot authorize a merge.',
  'Run the fast submit_review first – unless the user asked for the deep hunt in their own words (deep hunt, deep review, full-repo, --deep or a bare deep as the argument of the review command, in any language – the adjective alone, as in deep-dive review or a deep look, asks for a thorough fast review): then one submit_review with deep: true and meta.repo + meta.ref (the pushed head sha) + meta.base_branch, no payload, is the first and only review, with no fast stage first and no second question. Let the heartbeat wait at the server\'s cadence until the review is terminal, then read review_report.',
  'Immediately after every successful submit_review (including deep), read the response monitor contract and create or update one four-minute heartbeat with automation_update using destination=thread (this binds the current thread; do not use targetThreadId). Use that exact review_id, status_url, interval_s, heartbeat_s, wake_on, stop_on, and wake_rule — every number the wake will measure against goes into the prompt, because a wake fires in a fresh context holding nothing but that prompt; copy wake_rule into the prompt word for word: every wake reports the status it just read (from wait_review or get_findings on a fast hunt, from the status_url read on a deep one), and a wake with no answer prints bughunt · <mode> · poll-failed, never the previous status. The automation is the cadence and a wake is one read: inside a wake make ONE read and end — get_findings, or one wait_review with its default hold (the server caps the hold whatever timeout_s you ask for and answers timed_out:true, so a bigger timeout_s buys no extra waiting, and a timed_out answer is this wake\'s reading, running, from a healthy server, never a wake to count towards retirement); never loop either call inside the wake to cover the cadence, because a wake that loops is still holding the thread when the next one fires, and stop on done, failed or needs_files; the one exception is a payload submit (a diff sent as bytes, where the server cannot read the repo and serve the reviewers\' file requests itself) while a file request can still arrive: inside that wake call wait_review back to back, each answer a reading, and stop on done, failed or needs_files — or before the next wake is due: start another hold only if it, its round trip, and one more round trip for the handover\'s own calls would end inside heartbeat_s from this wake\'s start, so what is left before interval_s is the handover (the status line, the delete) and the next wake finds the thread free; a hold costs the server\'s cap plus the round trip and the handover\'s calls are round trips too, so a bound that subtracts the hold alone lets the last one return as the next wake fires, and one that leaves the handover to the heartbeat_s-interval_s gap shrinks it on the slow links that need it — a repo or deep submit never needs this; for a deep hunt the wake polls status_url once and reports that — that body flags a file request as awaiting_client_files/files_requested rather than in its status word, so a wake seeing either flag prints bughunt · <mode> · needs-files and serves the files first, and a failed poll falls back to one get_findings before it counts as a wake that read nothing. It must answer needs_files first, print only one compact bughunt status line, and delete itself on done or failed. Retire a heartbeat older than 180 minutes, or after 3 consecutive wakes that could not read a status at all (a failed wait_review, get_findings or status_url read, whichever that wake uses); on retiring, print bughunt · <mode> · watch-retired, then call get_findings once and arm a fresh heartbeat if the review is still running or waiting for files and the retirement came from unreadable wakes rather than the age cap. Never leave a heartbeat pointing at an older review id. The prompt carries facts the model can check, not only rules: compute retire_at = submit time + 180 min and write it as an ISO timestamp, the same instant into every replacement heartbeat so the cap bounds the review and not each job — if the current time is past retire_at, print bughunt · <mode> · watch-retired, delete this automation, then call get_findings once and report what it answered (still running when it is: 180 min is budget plus queue, so a queued deep hunt can be live there) — delete before the read, whatever the wake believes, because a delete that waits on a tool call is lost when that call fails. A terminal line quotes the answer it came from — on done print findings=N from that wake\'s read (wait_review, get_findings or the status_url body all carry a findings count), never the bare word; non-terminal wakes keep the enumerated lines, and no answer from a wake\'s read means the only line allowed is bughunt · <mode> · poll-failed. On done or failed delete the heartbeat in the same turn as the read; if it still exists at the next wake after a terminal read, delete it first, then report. When a get_findings next_step begins "this is the first read after done", the heartbeat outlived the hunt: delete it in that same turn and say so (the server sends it only when the hunt has been done for over ten minutes with its findings unread, so a wake that catches done within one cadence never sees it).',
  'The submit answer and every poll body carry live_url: the private page where the person who started the hunt watches it in a browser – stages, findings, the sandbox-destroyed receipt, a Save as PDF button – for 6 hours after the result. Print it for the user as a plain line twice: once when the submit answer arrives, and once more beside your terminal done/failed line so they can save the report. It is a capability link: never paste it into a PR, an issue, a commit or anything shared, and never poll it yourself – status_url is your door. No live_url on the body (an older server) means no page: say nothing about one.',
  'On your own initiative start deep only after the server returns deep_offer and the user explicitly agrees; never run fast and deep in parallel. A refusal of a deep-first request (repo_required, repo_too_big, commit_required, fast_running, deep_at_capacity) is shown to the user verbatim, then the fast hunt is offered with one yes/no question – never a silent downgrade to fast. A deep-first hunt arms the same heartbeat as an escalation, from its own response\'s monitor, and its compact line reads bughunt · deep · running.',
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
  if (/\b(?:review|reviewing|bug.?hunt|hunt\s+bugs?|deep\s+(?:review|hunt)|full[- ]repo(?:sitory)?\b|pull\s+request|\bpr\b|merge)\b/i.test(prompt)) {
    // The user's own words are the only thing that puts deep first (the server
    // takes deep: true from nobody else); the sentence says so only when the
    // prompt names the hunt, so a plain "review this" never reads as a deep
    // ask. The noun phrase, not the adjective, and every alternative closed on
    // BOTH sides: a hyphen is a word boundary, so \bdeep\b took "deep-dive
    // review" for the paid hour, and an open-ended full[- ]repo took "full
    // report". The slash command's own argument counts, bare or dashed.
    const deep = /\bdeep\s+(?:hunt|review|scan|pass|mode)\b|\bfull[- ]repo(?:sitory)?\b|--deep\b|\bbughunter:review\s+(?:--)?deep\b/i.test(prompt)
      ? ' The prompt names the deep hunt: if the user is asking for it, submit_review with deep: true is the first and only review – no fast stage first, no second question.'
      : '';
    emit(`${ROUTING} Route this request now; do not launch local review agents.${deep}`, 'UserPromptSubmit');
  }
}

process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', finish);
process.stdin.on('error', () => { finish(); process.exit(0); });
setTimeout(() => { finish(); process.exit(0); }, 1000).unref();
