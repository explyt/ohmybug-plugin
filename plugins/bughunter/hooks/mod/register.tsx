// The bughunter mod: Claude Code's view of an OhMyBug hunt.
//
// It shows; it never acts and never refuses. Every rule that blocks something
// (the merge gate) lives in the shell hooks, which Codex and older Claude Code
// run too — a rule only some clients enforce is a rule the others silently
// lack. Nothing here sends a prompt either: a button that acts would have to
// know which hunt and which refusal it acts on, and text it parses does not
// say. If this module fails to load, the plugin behaves exactly as it did
// before it existed.
//
// Quiet: a status-line entry while a hunt runs, a toast when one changes to
// something the agent has not read yet. No band, no sound, no turn of its own.

import type { EngineInterface as Engine, Register } from 'claude-code'

import { bodyOf, findingsOf, minutes, num, pollState, str, toolKind } from './parse'

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

// The drawing reads these and every write asks for a redraw. Module variables,
// not $.state: a state contract has to be named in plugin.json, and older
// Claude Code refuses a manifest key it does not know. The hunts outlive the
// session through $.store.
let huntList: BughunterHunt[] = []
const rawOpen = new Set<string>()

function setHunts($: Engine, list: BughunterHunt[]) { huntList = list; $.ui.invalidate('ui.render') }
function toggleRaw($: Engine, id: string) { if (!rawOpen.delete(id)) rawOpen.add(id); $.ui.invalidate('ui.render') }

const PANE = 'bughunter-hunts'
const STALE_MS = 6 * 3600_000
const SEVERITY = ['critical', 'high', 'medium', 'low']
const COLOR: Record<string, string> = { critical: 'red', high: 'red', medium: 'yellow' }

const isOpen = (h: BughunterHunt) => h.state === 'running' || h.state === 'needs_files'

function news(h: BughunterHunt): string {
  if (h.state === 'needs_files') return `Reviewers of hunt ${h.id} asked for files.`
  if (h.state === 'failed') return `Hunt ${h.id} failed.`
  const n = h.findings
  return `Hunt ${h.id} is done${n === undefined ? '' : ` · ${n} finding${n === 1 ? '' : 's'}`}.`
}

// What the person chose (environment) and what the network allowed. Module
// state on purpose: a reload starts it over, and nothing in it outlives the
// session. `ticking` keeps a slow poll from overlapping the next.
const ctx = { showStatus: true, blocked: false, ticking: false }

async function observe($: Engine, kind: string, input: Record<string, unknown>, text: string | undefined, failed: boolean) {
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
  } else if (at >= 0 && (kind === 'get_findings' || kind === 'wait_review')) {
    const state = pollState(body) ?? list[at]!.state
    const terminal = state === 'done' || state === 'failed'
    list[at] = { ...list[at]!, state, seen: terminal || list[at]!.seen,
      findings: state === 'done' ? findingsOf(body).length : list[at]!.findings }
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
  if (!h.seen) await $.ui.toast(`OhMyBug: ${news(h)}`)
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
  const due = huntList.filter(h => h.cwd === cwd && isOpen(h) && h.statusUrl && now >= h.nextAt)
  for (const h of due) {
    let res
    try {
      res = await $.http.fetch(h.statusUrl!)
    } catch {
      // A policy (sec-default, a proxy allowlist) refused the request. Say so
      // once in the status line rather than look like a hunt that never ends.
      ctx.blocked = true
      await apply($, h.id, () => ({ nextAt: now + 240_000 }))
      continue
    }
    ctx.blocked = false
    if (res.status === 404) { await apply($, h.id, () => ({ state: 'failed', seen: true })); continue }
    let body
    try { body = res.ok ? JSON.parse(res.text) : undefined } catch { body = undefined }
    const state = body && typeof body === 'object' ? pollState(body) : undefined
    const wait = Math.min(240, Math.max(30, num(body?.next_poll_after_s) ?? 60))
    // Judged against the hunt as apply() finds it, not the copy taken before the
    // fetch: a tool result read meanwhile may already have moved it there.
    let moved = false
    const next = await apply($, h.id, cur => {
      moved = !!state && state !== cur.state
      return moved
        ? { nextAt: now + wait * 1000, state, findings: num(body.findings) ?? cur.findings }
        : { nextAt: now + wait * 1000 }
    })
    // Back to running (files served) is news to nobody.
    if (next && moved && state !== 'running') await announce($, next)
  }
  await refreshStatus($)
}

/** Change one hunt as it stands NOW: the fetch awaited above may have let the
 *  agent read it, or submit another, and a stale copy would undo both. */
async function apply($: Engine, id: string, change: (cur: BughunterHunt) => Partial<BughunterHunt>) {
  const cur = huntList.find(x => x.id === id)
  if (!cur || !isOpen(cur)) return undefined
  const next = { ...cur, ...change(cur) }
  await save($, huntList.map(x => (x.id === id ? next : x)))
  return next
}

export const register: Register = on => {
  // Read from the environment, not the manifest's userConfig: older Claude Code
  // validates plugin.json strictly and refuses keys it does not know, and a
  // refused manifest would take the shell gate down with it. The environment is
  // also where managed settings put a team's choice.
  on('session.start', async ($, e, next) => {
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
    if (!kind) return next(e)
    const ran = await next(e)
    try {
      await observe($, kind, e as unknown as Record<string, unknown>, ran.deny ?? ran.text, ran.deny !== undefined || ran.isError === true)
    } catch {
      // The call already happened; a bookkeeping slip must not touch its result.
    }
    return ran
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
          body.deep_offer ? <Text dimColor>a deep hunt is on offer (show the raw answer)</Text> : null,
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
