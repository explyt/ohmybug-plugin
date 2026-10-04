// The bughunter mod: Claude Code's view of an OhMyBug hunt.
//
// It shows and offers; it never refuses. Every rule that blocks something (the
// merge gate, the secret scan) lives in the shell hooks, which Codex and older
// Claude Code run too — a rule only some clients enforce is a rule the others
// silently lack. If this module fails to load, the plugin behaves exactly as it
// did before it existed.
//
// Quiet by default: a status-line entry while a hunt runs, and a toast plus one
// band only when there is something to act on (a hunt finished, a merge was
// refused, a deep hunt is on offer). No sound, no turn started on its own
// unless the person sets OHMYBUG_AUTO_RESUME=1.

import type { EngineInterface as Engine, Register } from 'claude-code'

import { bodyOf, findingsOf, gateReason, minutes, num, pollState, str, toolKind } from './parse'

/** One hunt the bughunter mod watches: what submit_review answered, then what the status URL says. */
type BughunterHunt = {
  id: string
  mode: string
  state: 'running' | 'needs_files' | 'done' | 'failed'
  statusUrl?: string
  cwd: string
  startedAt: number
  median?: number
  findings?: number
  /** The agent has read the terminal result itself (get_findings or wait_review). */
  seen: boolean
  nextAt: number
}

/** The one band above the prompt: something the person can act on, or nothing. */
type BughunterBand = {
  kind: 'done' | 'files' | 'failed' | 'deep' | 'gate'
  id?: string
  text: string
} | null

// The drawing reads these and every write asks for a redraw. Module variables,
// not $.state: a state contract has to be named in plugin.json, and older
// Claude Code refuses a manifest key it does not know. The hunts outlive the
// session through $.store.
let huntList: BughunterHunt[] = []
let bandNow: BughunterBand = null
const rawOpen = new Set<string>()

function setHunts($: Engine, list: BughunterHunt[]) { huntList = list; $.ui.invalidate('ui.render') }
function setBand($: Engine, b: BughunterBand) { bandNow = b; $.ui.invalidate('ui.render') }
function toggleRaw($: Engine, id: string) { if (!rawOpen.delete(id)) rawOpen.add(id); $.ui.invalidate('ui.render') }

const PANE = 'bughunter-hunts'
const STALE_MS = 6 * 3600_000
const SEVERITY = ['critical', 'high', 'medium', 'low']
const COLOR: Record<string, string> = { critical: 'red', high: 'red', medium: 'yellow' }

const isOpen = (h: BughunterHunt) => h.state === 'running' || h.state === 'needs_files'

function resumeText(h: BughunterHunt): string {
  if (h.state === 'needs_files') return `Reviewers of the OhMyBug hunt ${h.id} asked for files. Call get_findings with review_id ${h.id} and serve them.`
  if (h.state === 'failed') return `The OhMyBug hunt ${h.id} failed. Call get_findings with review_id ${h.id} to see why.`
  return `The OhMyBug hunt ${h.id} is done. Read it with get_findings (review_id ${h.id}) and continue the bughunter flow.`
}

function bandFor(h: BughunterHunt): BughunterBand {
  if (h.state === 'needs_files') return { kind: 'files', id: h.id, text: `Reviewers of hunt ${h.id} asked for files.` }
  if (h.state === 'failed') return { kind: 'failed', id: h.id, text: `Hunt ${h.id} failed.` }
  const n = h.findings
  return { kind: 'done', id: h.id, text: `Hunt ${h.id} is done${n === undefined ? '' : ` · ${n} finding${n === 1 ? '' : 's'}`}.` }
}

// What the person chose (environment) and what the last drawing said about the
// session. Module state on purpose: a reload starts it over, and nothing in it
// outlives the session. `ticking` keeps a slow poll from overlapping the next.
const ctx = { autoResume: false, showStatus: true, working: true, draft: false, blocked: false, ticking: false }

async function observe($: Engine, kind: string | undefined, input: Record<string, unknown>, text: string | undefined, failed: boolean) {
  if (!kind) {
    if (!/\b(gh\s+pr\s+merge|glab\s+mr\s+merge)\b/.test(String(input.command ?? ''))) return
    const current = bandNow
    const reason = failed ? gateReason(text) : undefined
    if (reason) setBand($, { kind: 'gate', text: reason })
    else if (current?.kind === 'gate') setBand($, null)
    return
  }
  const body = failed ? undefined : bodyOf(text)
  if (!body) return
  const id = str(body.review_id) ?? str(input.review_id)
  if (!id) return
  const now = await $.clock.now()
  const list = [...huntList]
  const at = list.findIndex(h => h.id === id)

  if (kind === 'submit_review') {
    const statusUrl = str(body.status_url)
    if (!statusUrl) return
    const done = str(body.status) === 'done'
    const h: BughunterHunt = { id, mode: str(body.mode) ?? 'fast', state: done ? 'done' : 'running', statusUrl,
      cwd: await $.session.cwd(), startedAt: now, median: num(body.recent_median_minutes), seen: done,
      nextAt: now + 60_000 }
    if (at >= 0) list[at] = h; else list.push(h)
    const b = bandNow
    if (b?.kind === 'deep' || b?.kind === 'gate') setBand($, null)
  } else if (at >= 0 && (kind === 'get_findings' || kind === 'wait_review')) {
    const state = pollState(body) ?? list[at]!.state
    const terminal = state === 'done' || state === 'failed'
    list[at] = { ...list[at]!, state, seen: terminal || list[at]!.seen,
      findings: state === 'done' ? findingsOf(body).length : list[at]!.findings }
    const b = bandNow
    if (b?.id === id && b.kind !== 'deep') setBand($, null)
    const offer = body.deep_offer as Record<string, unknown> | undefined
    if (state === 'done' && offer && str(offer.pitch)) {
      setBand($, { kind: 'deep', id, text: str(offer.pitch)!.slice(0, 280) })
    }
  } else if (kind === 'confirm_findings') {
    const b = bandNow
    if (b?.id === id && b.kind === 'done') setBand($, null)
    return
  } else {
    return
  }
  await save($, list)
  await refreshStatus($)
}

async function save($: Engine, list: BughunterHunt[]) {
  setHunts($, list)
  await $.store.set('hunts', list)
}

async function refreshStatus($: Engine) {
  if (!ctx.showStatus) return
  const cwd = await $.session.cwd()
  const now = await $.clock.now()
  const mine = huntList.filter(h => h.cwd === cwd)
  const unread = mine.find(h => !h.seen && !isOpen(h))
  const running = mine.filter(isOpen)
  let text: string | undefined
  if (ctx.blocked && running.length) text = 'bughunt: status unreachable here, the agent polls instead'
  else if (unread) text = `bughunt ${unread.id} ${unread.state}${unread.findings === undefined ? '' : ` · ${unread.findings} found`}`
  else if (running.length === 1) {
    const h = running[0]!
    text = `bughunt ${h.mode} ${minutes(now - h.startedAt)}${h.median ? `/~${h.median}` : ''} min${h.state === 'needs_files' ? ' · files asked' : ''}`
  } else if (running.length > 1) text = `bughunt: ${running.length} running`
  $.ui.status(text)
}

async function announce($: Engine, h: BughunterHunt) {
  if (h.seen) return
  const b = bandFor(h)
  $.ui.toast(`OhMyBug: ${b!.text}`)
  if (ctx.autoResume && !ctx.working && !ctx.draft) {
    await $.prompt.submit({ text: resumeText(h) })
    return
  }
  setBand($, b)
}

async function tick($: Engine) {
  if (ctx.ticking) return
  ctx.ticking = true
  try {
    await pollDue($)
  } finally {
    ctx.ticking = false
  }
}

async function pollDue($: Engine) {
  const cwd = await $.session.cwd()
  const now = await $.clock.now()
  const list = [...huntList]
  let changed = false
  for (const [i, h] of list.entries()) {
    if (h.cwd !== cwd || !isOpen(h) || !h.statusUrl || now < h.nextAt) continue
    let res
    try {
      res = await $.http.fetch(h.statusUrl)
    } catch {
      // A policy (sec-default, a proxy allowlist) refused the request. Say so
      // once in the status line rather than look like a hunt that never ends.
      ctx.blocked = true
      list[i] = { ...h, nextAt: now + 240_000 }
      changed = true
      continue
    }
    ctx.blocked = false
    if (res.status === 404) { list[i] = { ...h, state: 'failed', seen: true }; changed = true; continue }
    let body
    try { body = res.ok ? JSON.parse(res.text) : undefined } catch { body = undefined }
    const state = body && typeof body === 'object' ? pollState(body) : undefined
    const wait = Math.min(240, Math.max(30, num(body?.next_poll_after_s) ?? 60))
    const next: BughunterHunt = { ...h, nextAt: now + wait * 1000 }
    if (state && state !== h.state) {
      next.state = state
      next.findings = num(body.findings) ?? h.findings
      await announce($, next)
    }
    list[i] = next
    changed = true
  }
  if (changed) await save($, list)
  await refreshStatus($)
}

export const register: Register = on => {
  // Read from the environment, not the manifest's userConfig: older Claude Code
  // validates plugin.json strictly and refuses keys it does not know, and a
  // refused manifest would take the shell gate down with it. The environment is
  // also where managed settings put a team's choice.
  on('session.start', async ($, e, next) => {
    ctx.autoResume = (await $.env.get('OHMYBUG_AUTO_RESUME')) === '1'
    ctx.showStatus = (await $.env.get('OHMYBUG_STATUS')) !== '0'
    const now = await $.clock.now()
    const saved = (await $.store.get('hunts')) as BughunterHunt[] | undefined
    setHunts($, Array.isArray(saved) ? saved.filter(h => now - h.startedAt < STALE_MS) : [])
    await $.command.register({ name: 'hunts', description: 'OhMyBug: the hunts of this repository, in a pane' })
    $.clock.every(15_000, () => { void tick($) })
    await refreshStatus($)
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const tool = String(e.tool)
    const kind = toolKind(tool)
    if (!kind && tool !== 'Bash') return next(e)
    const ran = await next(e)
    try {
      await observe($, kind, e as unknown as Record<string, unknown>, ran.deny ?? ran.text, ran.deny !== undefined || ran.isError === true)
    } catch {
      // The call already happened; a bookkeeping slip must not touch its result.
    }
    return ran
  })

  on('turn.complete', async ($, e, next) => {
    const out = await next(e)
    ctx.working = false
    if (ctx.autoResume && !ctx.draft) {
      const b = bandNow
      const h = b && (b.kind === 'done' || b.kind === 'files' || b.kind === 'failed')
        ? huntList.find(x => x.id === b.id) : undefined
      if (h && !h.seen) {
        setBand($, null)
        await $.prompt.submit({ text: resumeText(h) })
      }
    }
    return out
  })

  on('turn.start', ($, e, next) => { ctx.working = true; return next(e) })

  on('ui.render', { component: 'PromptHint' }, ($, e, next) => {
    ctx.draft = e.props.isDraft
    ctx.working = e.props.isWorking
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const b = bandNow
    if (!b || e.props.hasSurvey) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    const close = () => setBand($, null)
    const send = (text: string) => async () => { await close(); await $.prompt.submit({ text }) }
    const list = huntList
    const hunt = b.id ? list.find(x => x.id === b.id) : undefined
    let actions
    if (b.kind === 'deep') {
      actions = [
        <Button key="deep-yes" label="Run deep hunt" hotkey="1" variant="primary" onPress={send(`Yes, run the deep hunt for ${b.id}.`)} />,
        <Button key="deep-no" label="Not now" hotkey="2" onPress={send(`No deep hunt for ${b.id} now.`)} />,
      ]
    } else if (b.kind === 'gate') {
      actions = [
        <Button key="gate-hunt" label="Hunt now" hotkey="1" variant="primary" onPress={send('Run the OhMyBug hunt on the current diff (bughunter skill), then retry the merge.')} />,
        <Button key="gate-close" label="Dismiss" hotkey="2" onPress={close} />,
      ]
    } else {
      actions = [
        <Button key="go" label="Continue" hotkey="1" variant="primary" onPress={send(hunt ? resumeText(hunt) : `Call get_findings for ${b.id}.`)} />,
        <Button key="later" label="Later" hotkey="2" onPress={close} />,
      ]
    }
    const lead = b.kind === 'deep' ? `Deep hunt offered for ${b.id}: ` : b.kind === 'gate' ? 'Merge blocked: ' : ''
    return (
      <Box flexDirection="column">
        <Text><Text color="red">OhMyBug</Text> {lead}{b.text}</Text>
        <Box>{actions}</Box>
      </Box>
    )
  })

  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    const kind = toolKind(e.props.tool)
    if (!kind || kind === 'submit_review' || e.props.isErrored) return next(e)
    const body = bodyOf(e.props.output)
    if (!body || body.error) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    const toggle = (
      <Button key="raw" plain dimColor label={rawOpen.has(e.requestId) ? 'show the card' : 'show the raw answer'}
        onPress={() => toggleRaw($, e.requestId)} />
    )
    if (rawOpen.has(e.requestId)) return <Box flexDirection="column">{await next(e)}{toggle}</Box>

    let rows
    if (kind === 'confirm_findings') {
      const species = Array.isArray(body.species) ? (body.species as Record<string, unknown>[]) : []
      const pending = num(body.species_pending) ?? 0
      const confirmed = num(body.confirmed)
      if (confirmed === undefined) return next(e)
      rows = [
        <Text>verdicts recorded · {confirmed} confirmed{num(body.minor_confirmed) ? ` · ${body.minor_confirmed} minor` : ''}</Text>,
        ...species.map(s => (
          <Text>
            <Text dimColor>{str(s.finding_id) ?? '?'} →</Text> {str(s.name) ?? str(s.slug) ?? '?'}
            {s.confidence === 'medium' ? <Text dimColor> (likely)</Text> : null}
          </Text>
        )),
        pending ? <Text dimColor>{pending} still being matched to a bug species</Text> : null,
      ]
    } else {
      const state = pollState(body)
      const id = str(body.review_id) ?? '?'
      if (state !== 'done') {
        rows = [<Text dimColor>hunt {id} · {state === 'needs_files' ? 'reviewers asked for files' : state ?? 'running'}{body.timed_out ? ' · still running' : ''}</Text>]
      } else {
        const found = findingsOf(body).sort((a, b) => SEVERITY.indexOf(a.severity) - SEVERITY.indexOf(b.severity))
        rows = [
          <Text>{str(body.mode) ?? 'fast'} hunt {id} · done · {found.length} finding{found.length === 1 ? '' : 's'}</Text>,
          ...found.map(f => (
            <Box flexDirection="column">
              <Text>
                <Text color={COLOR[f.severity]} dimColor={!COLOR[f.severity]}>● {f.severity.padEnd(8)}</Text>
                {f.id}  {f.title}
              </Text>
              {f.where ? <Text dimColor>{'           '}{f.where}</Text> : null}
            </Box>
          )),
          found.length === 0 && str(body.summary) ? <Text>{str(body.summary)}</Text> : null,
          str(body.next_step) ? <Text dimColor>next: {str(body.next_step)!.slice(0, 240)}</Text> : null,
          body.deep_offer ? <Text dimColor>a deep hunt is on offer (see above the prompt)</Text> : null,
        ]
      }
    }
    return <Box flexDirection="column">{rows}{toggle}</Box>
  })

  on('command.run', { command: 'hunts' }, async $ => {
    await $.ui.open({ id: PANE, title: 'OhMyBug hunts' })
    return { text: 'OhMyBug hunts pane opened.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const cwd = await $.session.cwd()
    const now = await $.clock.now()
    const mine = huntList.filter(h => h.cwd === cwd).reverse()
    if (!mine.length) return <Text dimColor>No hunts in this repository in the last 6 hours.</Text>
    return (
      <Box flexDirection="column">
        {mine.map(hunt => (
          <Box flexDirection="column">
            <Text>
              <Text color={isOpen(hunt) ? 'yellow' : hunt.state === 'failed' ? 'red' : 'green'}>{isOpen(hunt) ? '●' : hunt.state === 'failed' ? '✗' : '✓'}</Text>
              {' '}{hunt.id} {hunt.mode} · {hunt.state === 'needs_files' ? 'files asked' : hunt.state}
            </Text>
            <Text dimColor>
              {'  '}{minutes(now - hunt.startedAt)} min ago{hunt.median && isOpen(hunt) ? ` · runs take ~${hunt.median} min` : ''}
              {hunt.findings !== undefined ? ` · ${hunt.findings} found` : ''}{!hunt.seen && !isOpen(hunt) ? ' · not read yet' : ''}
            </Text>
          </Box>
        ))}
      </Box>
    )
  })
}
