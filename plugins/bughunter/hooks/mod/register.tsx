// The bughunter mod: Claude Code's view of an OhMyBug hunt.
//
// It shows and offers; it never refuses. Every rule that blocks something (the
// merge gate) lives in the shell hooks, which Codex and older Claude Code run
// too — a rule only some clients enforce is a rule the others silently lack.
// If this module fails to load, the plugin behaves exactly as it did before it
// existed.
//
// Quiet: a status-line entry while a hunt runs, a toast and one band above the
// prompt when there is something to act on. No sound, no turn of its own unless
// the person sets OHMYBUG_AUTO_RESUME=1. The one line it adds to the system
// prompt (a read hunt whose verdicts are not sent) the status line shows the
// person in the same words.
//
// The rule every action obeys: a button or an auto-resume acts only on a hunt
// this mod tracks by review_id, in a state it saw that hunt move into itself.
// Nothing is derived from a refusal's wording: a gate refusal is shown as it
// reads, and the most it offers is "Poll <id>" for an open tracked hunt of this
// repository. A text does not say which hunt or which refusal it is about, and
// a "Hunt now" offered on the RUNNING refusal once started a second paid hunt.

import type { EngineInterface as Engine, Register, RenderChildren } from 'claude-code'

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
  /** confirm_findings for this hunt's id answered with the verdicts recorded. */
  judged?: boolean
  nextAt: number
}

/** The one band above the prompt. `id` is always a tracked hunt; `state` is the
 *  state the mod saw it move into, re-checked before any action. */
type BughunterBand =
  | { kind: 'hunt'; id: string; state: BughunterHunt['state']; text: string }
  | { kind: 'deep'; id: string; text: string }
  | { kind: 'gate'; id?: string; text: string }
  | null

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
/** Done, read by the agent, and no verdicts seen for it: the one next step left. */
const awaitsVerdicts = (h: BughunterHunt, cwd: string, now: number) =>
  h.cwd === cwd && h.state === 'done' && h.seen && !h.judged && now - h.startedAt < STALE_MS

function news(h: BughunterHunt): string {
  if (h.state === 'needs_files') return `Reviewers of hunt ${h.id} asked for files.`
  if (h.state === 'failed') return `Hunt ${h.id} failed.`
  const n = h.findings
  return `Hunt ${h.id} is done${n === undefined ? '' : ` · ${n} finding${n === 1 ? '' : 's'}`}.`
}

/** What Continue sends: the hunt's id, and the step its seen state calls for. */
function resumeText(h: BughunterHunt): string {
  if (h.state === 'needs_files') return `Reviewers of the OhMyBug hunt ${h.id} asked for files. Call get_findings with review_id ${h.id} and serve them.`
  if (h.state === 'failed') return `The OhMyBug hunt ${h.id} failed. Call get_findings with review_id ${h.id} to see why.`
  return `The OhMyBug hunt ${h.id} is done. Read it with get_findings (review_id ${h.id}) and continue the bughunter flow.`
}

/** The tracked hunt a 'hunt' band may still act on: same id, same state the mod
 *  saw it move into, not read by the agent since. Anything else acts on nothing. */
function actionable(b: BughunterBand): BughunterHunt | undefined {
  if (b?.kind !== 'hunt') return undefined
  const h = huntList.find(x => x.id === b.id)
  return h && h.state === b.state && !h.seen ? h : undefined
}

/** The open tracked hunt of this repository a gate band may offer to poll. */
const openHunt = (cwd: string, id?: string) =>
  huntList.find(h => h.cwd === cwd && isOpen(h) && (id === undefined || h.id === id))

// What the person chose (environment), what the last drawing said about the
// session and what the network allowed. Module state on purpose: a reload
// starts it over, and nothing in it outlives the session. `ticking` keeps a
// slow poll from overlapping the next.
const ctx = { autoResume: false, showStatus: true, working: true, draft: false, blocked: false, ticking: false }

const MERGE = /\b(gh\s+pr\s+merge|glab\s+mr\s+merge)\b/

/** A merge the gate refused: its own words, and Poll for an open tracked hunt
 *  here. Which hunt comes from the mod's list, never from the refusal's text. */
async function observeGate($: Engine, command: string, text: string | undefined, failed: boolean) {
  if (!MERGE.test(command)) return
  const reason = failed ? gateReason(text) : undefined
  if (!reason) { if (bandNow?.kind === 'gate') setBand($, null); return }
  setBand($, { kind: 'gate', id: openHunt(await $.session.cwd())?.id, text: reason })
}

async function observe($: Engine, kind: string, input: Record<string, unknown>, text: string | undefined, failed: boolean) {
  const body = failed ? undefined : bodyOf(text)
  if (!body) return
  const id = str(body.review_id) ?? str(input.review_id)
  if (!id) return
  // Every await before the snapshot: a tool result read meanwhile must not be
  // undone by a stale copy of the list.
  const now = await $.clock.now()
  const cwd = await $.session.cwd()
  const list = [...huntList]
  const at = list.findIndex(h => h.id === id)

  if (kind === 'submit_review') {
    const statusUrl = str(body.status_url)
    if (!statusUrl) return
    if (bandNow?.kind === 'deep' || bandNow?.kind === 'gate') setBand($, null)
    // The server answered with the hunt already queued or running for this
    // input: nothing started, nothing charged. Keep the record as it is.
    if (at >= 0 && body.already_running === true) return
    const done = str(body.status) === 'done'
    const h: BughunterHunt = { id, mode: str(body.mode) ?? 'fast', state: done ? 'done' : 'running', statusUrl,
      cwd, startedAt: now, median: num(body.recent_median_minutes), seen: done,
      nextAt: now + 60_000 }
    if (at >= 0) list[at] = h; else list.push(h)
  } else if (at >= 0 && (kind === 'get_findings' || kind === 'wait_review')) {
    const state = pollState(body) ?? list[at]!.state
    const terminal = state === 'done' || state === 'failed'
    list[at] = { ...list[at]!, state, seen: terminal || list[at]!.seen,
      findings: state === 'done' ? findingsOf(body).length : list[at]!.findings }
    if (bandNow?.kind === 'hunt' && bandNow.id === id) setBand($, null)
    // The deep offer comes in the answer for this tracked hunt, and only there.
    const offer = body.deep_offer as Record<string, unknown> | undefined
    if (kind === 'get_findings' && state === 'done' && offer && typeof offer === 'object' && str(offer.pitch)) {
      setBand($, { kind: 'deep', id, text: str(offer.pitch)!.slice(0, 280) })
    }
  } else if (at >= 0 && kind === 'confirm_findings' && num(body.confirmed) !== undefined) {
    list[at] = { ...list[at]!, judged: true }
    if (bandNow?.id === id && bandNow.kind === 'hunt') setBand($, null)
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
  const unjudged = mine.find(h => awaitsVerdicts(h, cwd, now))
  const running = mine.filter(isOpen)
  let text: string | undefined
  if (ctx.blocked && running.length) text = 'bughunt: status unreachable here, the agent polls instead'
  else if (unread) text = `bughunt ${unread.id} ${unread.state}${unread.findings === undefined ? '' : ` · ${unread.findings} found`}`
  else if (running.length === 1) {
    const h = running[0]!
    text = `bughunt ${h.mode} ${minutes(now - h.startedAt)}${h.median ? `/~${h.median}` : ''} min${h.state === 'needs_files' ? ' · files asked' : ''}`
  } else if (running.length > 1) text = `bughunt: ${running.length} running`
  else if (unjudged) text = `bughunt ${unjudged.id} · verdicts not sent`
  $.ui.status(text)
}

/** Called only on a state change the poll itself saw. */
async function announce($: Engine, h: BughunterHunt) {
  if (h.seen) return
  await $.ui.toast(`OhMyBug: ${news(h)}`)
  if (ctx.autoResume && !ctx.working && !ctx.draft) {
    await $.prompt.submit({ text: resumeText(h) })
    return
  }
  setBand($, { kind: 'hunt', id: h.id, state: h.state, text: news(h) })
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
    ctx.autoResume = (await $.env.get('OHMYBUG_AUTO_RESUME')) === '1'
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
    const failed = ran.deny !== undefined || ran.isError === true
    try {
      if (kind) await observe($, kind, e as unknown as Record<string, unknown>, ran.deny ?? ran.text, failed)
      else await observeGate($, String((e as unknown as Record<string, unknown>).command ?? ''), ran.deny ?? ran.text, failed)
    } catch {
      // The call already happened; a bookkeeping slip must not touch its result.
    }
    return ran
  })

  // The one thing the mod tells the agent, and the status line tells the person
  // the same: a hunt it read whose verdicts it has not sent. Keyed by hunt id,
  // gone once confirm_findings for that id is seen or the hunt is 6 hours old.
  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    // Shown to the person or not told to the agent: OHMYBUG_STATUS=0 drops both.
    if (!ctx.showStatus) return composed
    try {
      const cwd = await $.session.cwd()
      const now = await $.clock.now()
      if (!huntList.some(h => awaitsVerdicts(h, cwd, now))) return composed
      const text = huntList.filter(h => awaitsVerdicts(h, cwd, now)).map(h => h.findings === 0
        ? `OhMyBug hunt ${h.id} is done with 0 findings and is not confirmed yet. Next: confirm_findings for ${h.id} with verdicts: [].`
        : `OhMyBug hunt ${h.id} is done and its verdicts are not sent. Next: verify each finding, then confirm_findings for ${h.id}.`).join('\n')
      return { sections: [...composed.sections, { id: 'bughunter:next-step', text, scope: 'session' as const }] }
    } catch {
      return composed
    }
  })

  // Auto-resume, opt-in only: a band for a hunt whose move the poll saw while a
  // turn ran is taken up when the turn ends, if that hunt is still in that state.
  on('turn.complete', async ($, e, next) => {
    const out = await next(e)
    if (e.agentId) return out
    ctx.working = false
    const h = ctx.autoResume && !ctx.draft ? actionable(bandNow) : undefined
    if (h) {
      setBand($, null)
      await $.prompt.submit({ text: resumeText(h) })
    }
    return out
  })

  on('turn.start', ($, e, next) => {
    ctx.working = true
    // A gate refusal is news for the turn it happened in; the band does not linger.
    if (bandNow?.kind === 'gate') setBand($, null)
    return next(e)
  })

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
    let actions: RenderChildren[] = []
    let lead = ''
    if (b.kind === 'deep') {
      // Pressing it is the person's consent; Not now sends nothing.
      lead = `Deep hunt offered for ${b.id}: `
      actions = [
        <Button key="deep-yes" label="Run deep hunt" hotkey="1" variant="primary" onPress={async () => {
          close(); await $.prompt.submit({ text: `Yes, run the deep hunt for ${b.id}.` })
        }} />,
        <Button key="deep-no" label="Not now" hotkey="2" role="dismiss" onPress={close} />,
      ]
    } else if (b.kind === 'gate') {
      lead = 'Merge blocked: '
      const open = b.id ? openHunt(await $.session.cwd(), b.id) : undefined
      if (open) {
        actions = [
          <Button key="gate-poll" label={`Poll ${open.id}`} hotkey="1" onPress={async () => {
            close()
            if (huntList.find(x => x.id === open.id && isOpen(x))) {
              await $.prompt.submit({ text: `Poll the OhMyBug hunt ${open.id}: call get_findings with review_id ${open.id}.` })
            }
          }} />,
        ]
      }
    } else if (actionable(b)) {
      actions = [
        <Button key="go" label="Continue" hotkey="1" variant="primary" onPress={async () => {
          const h = actionable(bandNow?.id === b.id ? bandNow : null)
          close()
          if (h) await $.prompt.submit({ text: resumeText(h) })
        }} />,
        <Button key="later" label="Later" hotkey="2" role="dismiss" onPress={close} />,
      ]
    } else {
      return next(e)
    }
    return (
      <Box flexDirection="column">
        <Text><Text color="red">OhMyBug</Text> {lead}{b.text}</Text>
        {actions.length ? <Box>{actions}</Box> : null}
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
      // Field notes: other hunters' lessons about the species, already in the
      // agent's context through the answer itself. Shown, never sent anywhere.
      const lessonsOf = (s: Record<string, unknown>) =>
        Array.isArray(s.lessons) ? s.lessons.flatMap(l => str(l) ?? []) : []
      const notes = species.reduce((n, s) => n + lessonsOf(s).length, 0)
      rows = [
        <Text>verdicts recorded · {confirmed} confirmed{num(body.minor_confirmed) ? ` · ${body.minor_confirmed} minor` : ''}</Text>,
        ...species.map(s => (
          <Box flexDirection="column">
            <Text>
              <Text dimColor>{str(s.finding_id) ?? '?'} →</Text> {str(s.name) ?? str(s.slug) ?? '?'}
              {s.confidence === 'medium' ? <Text dimColor> (likely)</Text> : null}
            </Text>
            {str(s.url) ? <Text dimColor>{'    '}{str(s.url)}</Text> : null}
            {lessonsOf(s).map(l => <Text dimColor>{'    '}· {l.slice(0, 240)}</Text>)}
          </Box>
        )),
        pending ? <Text dimColor>{pending} still being matched to a bug species</Text> : null,
        notes ? <Text dimColor>{notes} field note{notes === 1 ? '' : 's'} from other hunters {notes === 1 ? 'is' : 'are'} in the agent's context</Text> : null,
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
