import { expect, mock, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

type Dollar = Parameters<TestBody>[0]
type On = Parameters<TestBody>[1]

const SUBMIT = 'mcp__plugin_bughunter_ohmybug__submit_review'
const GET = 'mcp__plugin_bughunter_ohmybug__get_findings'
const WAIT = 'mcp__plugin_bughunter_ohmybug__wait_review'
const VIEW = { scroll: { top: 0, bodyRows: 10 }, view: {} }

/** The texts a component draws, as the person would read them. */
async function drawn($: Dollar, component: string, props: Record<string, unknown>, requestId = 'x') {
  const ui = await $.ui.mount({ plugin: 'bughunter', surface: 'terminal', component, requestId, props } as never)
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
  await ui.unmount()
  return texts
}
const BAND = { plugin: 'bughunter', surface: 'terminal', component: 'AbovePrompt', requestId: 'x',
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100, ...VIEW } }
const band = ($: Dollar) => drawn($, 'AbovePrompt', BAND.props)
/** The keys of the Buttons the band draws. */
async function buttons($: Dollar) {
  const ui = await $.ui.mount(BAND as never)
  const keys = (await ui.findAll({ type: 'Button' })).map(b => String(b.key))
  await ui.unmount()
  return keys
}
async function press($: Dollar, key: string) {
  const ui = await $.ui.mount(BAND as never)
  await ui.press({ key })
  await ui.unmount()
}
const pane = ($: Dollar) => drawn($, 'Pane', { title: 'OhMyBug hunts', isFocused: false, bodyColumns: 60, placement: 'dock', ...VIEW }, 'bughunter-hunts')

const submitted = JSON.stringify({ review_id: 'rev_1', status: 'running', mode: 'fast',
  status_url: 'https://status.test/r/rev_1/status', recent_median_minutes: 38 })
const done = JSON.stringify({ review_id: 'rev_1', status: 'done', mode: 'fast', next_step: 'Verify each finding.',
  findings: [
    { finding_id: 'f_2', severity: 'low', file: 'a.ts', line: 3, title: 'Log line leaks the email domain' },
    { finding_id: 'f_1', severity: 'high', file: 'billing/refund.ts', line: 88, title: 'Refund retried twice on timeout' },
  ] })

/** The world beneath the plugin: a status URL, the toasts, the status line, the prompts it queues. */
/** What every test needs beneath the plugin: a session to start in, a command table, a drawing. */
function engine(on: On) {
  on('session.start', async ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', async () => ({ value: '/repo' }) as never)
  on('command.register', async () => ({ value: undefined }) as never)
  on('turn.complete', async ($, e) => ({ text: e.answer }))
  on('turn.start', async () => ({ turnId: 't1' }) as never)
  on('ui.render', async ($, e) => { const { Text } = $.ui.resolve(e); return Text({ children: 'engine drawing' } as never) })
}

function world(on: On, status: string | null | string[] | (() => Promise<string>)) {
  const replies = Array.isArray(status) ? [...status] : null
  const seen = { toasts: [] as string[], status: [] as (string | undefined)[], prompts: [] as string[] }
  engine(on)
  on('http.fetch', async () => (status === null ? { deny: 'refused by policy' }
    : { value: { status: 200, ok: true, headers: {}, text: typeof status === 'function' ? await status()
      : replies ? (replies.length > 1 ? replies.shift()! : replies[0]!) : status } }) as never)
  on('ui.toast', async ($, e) => { seen.toasts.push(e.text); return { value: undefined } as never })
  on('ui.status', async ($, e) => { seen.status.push(e.text); return { value: undefined } as never })
  on('prompt.submit', async ($, e) => { seen.prompts.push(e.text); return { text: e.text } })
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: submitted }))
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: done }))
  return seen
}

test('a hunt that finishes raises a toast and a band, and starts no turn by itself', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2, next_poll_after_s: 60 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT, meta: { repo: 'o/r', ref: 'abc', base_branch: 'main' } } as never)
  expect(seen.status.at(-1)).toMatch(/bughunt fast 0\/~38 min/)

  await clock.advance(75_000)
  expect(seen.toasts.join('\n')).toContain('rev_1 is done · 2 findings')
  expect(await band($)).toContain('Hunt rev_1 is done · 2 findings.')
  expect(await buttons($)).toEqual(['go', 'later'])
  // Without OHMYBUG_AUTO_RESUME nothing is sent, not even when a turn ends idle.
  await drawn($, 'PromptHint', { isDraft: false, isWorking: false, hint: '' })
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'end_turn' } as never)
  expect(seen.prompts).toHaveLength(0)
})

test('Continue sends the step for the hunt it names, by id', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  await press($, 'go')
  expect(seen.prompts).toEqual(['The OhMyBug hunt rev_1 is done. Read it with get_findings (review_id rev_1) and continue the bughunter flow.'])
  expect(await band($)).toBe('engine drawing')
})

test('a hunt the agent has read since loses its Continue', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(await buttons($)).toContain('go')
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await buttons($)).toEqual([])
  expect(seen.prompts).toHaveLength(0)
})

test('with OHMYBUG_AUTO_RESUME=1, a finished hunt resumes an idle session with its id', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, { OHMYBUG_AUTO_RESUME: '1' })
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await drawn($, 'PromptHint', { isDraft: false, isWorking: false, hint: '' })
  await clock.advance(75_000)
  expect(seen.prompts.join('\n')).toContain('get_findings (review_id rev_1)')
})

test('without OHMYBUG_AUTO_RESUME an idle session gets no prompt when a hunt finishes', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await drawn($, 'PromptHint', { isDraft: false, isWorking: false, hint: '' })
  await clock.advance(75_000)
  expect(seen.prompts).toHaveLength(0)
})

test('a submit answered already_running keeps the one record and its start time', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  engine(on)
  on('ui.status', async () => ({ value: undefined }) as never)
  on('http.fetch', async () => ({ value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ status: 'running' }) } }) as never)
  const replies = [submitted, JSON.stringify({ ...JSON.parse(submitted), already_running: true })]
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: replies.shift()! }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(5 * 60_000)
  await $.tool.call({ tool: SUBMIT } as never)
  const list = await pane($)
  expect(list.match(/rev_1/g)).toHaveLength(1)
  expect(list).toContain('5 min ago')
})

test('files served and the hunt running again is not announced as done', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, [JSON.stringify({ status: 'running', files_requested: true, next_poll_after_s: 30 }),
    JSON.stringify({ status: 'running', files_requested: false, next_poll_after_s: 30 })])
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(seen.toasts.join('\n')).toContain('asked for files')
  await clock.advance(45_000)
  expect(seen.toasts.join('\n')).not.toContain('is done')
})

test('a file request flagged only by awaiting_client_files is announced', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'running', awaiting_client_files: true }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(seen.toasts.join('\n')).toContain('asked for files')
})

test('a hunt the agent read while the poll was in flight is not announced again', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, async () => {
    await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
    return JSON.stringify({ status: 'done', findings: 2 })
  })
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(seen.toasts.join('\n')).not.toContain('is done')
  expect(await pane($)).not.toContain('not read yet')
})

test('a file request the agent read while the poll was in flight is not announced again', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const asked = JSON.stringify({ review_id: 'rev_1', status: 'running', files_requested: true })
  on('tool.call', { tool: WAIT }, async () => ({ result: { content: [] }, text: asked }))
  const seen = world(on, async () => {
    await $.tool.call({ tool: WAIT, review_id: 'rev_1' } as never)
    return asked
  })
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(seen.toasts.join('\n')).not.toContain('asked for files')
})

test('reading the result itself marks the hunt read', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  const list = await pane($)
  expect(list).toContain('2 found')
  expect(list).not.toContain('not read yet')
})

const RUNNING = 'OhMyBug: a hunt is RUNNING for this diff and has not returned yet. Poll get_findings until it says done, then merge.'
const UNHUNTED = 'OhMyBug: the current diff has not been hunted, or has CHANGED since the hunt (fixes count — re-hunt them).'

test('the gate\'s RUNNING refusal with a tracked open hunt offers Poll for that id and nothing else', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'running' }))
  on('tool.call', { tool: 'Bash' }, async () => ({ deny: RUNNING }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: 'Bash', command: 'gh pr merge 12 --squash' } as never)
  expect(await band($)).toContain('Merge blocked: a hunt is RUNNING for this diff')
  expect(await buttons($)).toEqual(['gate-poll'])
  await press($, 'gate-poll')
  expect(seen.prompts).toEqual(['Poll the OhMyBug hunt rev_1: call get_findings with review_id rev_1.'])
})

for (const [kind, reason] of [['RUNNING', RUNNING], ['unhunted', UNHUNTED]] as const) {
  test(`a ${kind} gate refusal without a tracked hunt shows its text and no button`, async ($, on) => {
    mock.clock(on)
    mock.store(on)
    mock.env(on, {})
    const seen = world(on, JSON.stringify({ status: 'running' }))
    on('tool.call', { tool: 'Bash' }, async () => ({ deny: reason }))
    await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
    await $.tool.call({ tool: 'Bash', command: 'gh pr merge 12 --squash' } as never)
    expect(await band($)).toContain(`Merge blocked: ${reason.replace('OhMyBug: ', '')}`)
    expect(await buttons($)).toEqual([])
    expect(seen.prompts).toHaveLength(0)
  })
}

test('a gate refusal after the tracked hunt finished offers no button', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, JSON.stringify({ status: 'done', findings: 2 }))
  on('tool.call', { tool: 'Bash' }, async () => ({ deny: UNHUNTED }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  await $.tool.call({ tool: 'Bash', command: 'gh pr merge 12' } as never)
  expect(await buttons($)).toEqual([])
})

const findingsWith = (extra: Record<string, unknown>) => JSON.stringify({ ...JSON.parse(done), ...extra })

test('the deep hunt buttons come only with deep_offer, and Not now sends nothing', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const answers = [done, findingsWith({ deep_offer: { pitch: 'A deep hunt reads the whole repository.' } })]
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: answers.shift()! }))
  const seen = world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await buttons($)).not.toContain('deep-yes')
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await band($)).toContain('Deep hunt offered for rev_1: A deep hunt reads the whole repository.')
  expect(await buttons($)).toEqual(['deep-yes', 'deep-no'])
  await press($, 'deep-no')
  expect(seen.prompts).toHaveLength(0)
  expect(await band($)).toBe('engine drawing')
})

test('Run deep hunt sends the consent for the offered id', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: findingsWith({ deep_offer: { pitch: 'Go deep.' } }) }))
  const seen = world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  await press($, 'deep-yes')
  expect(seen.prompts).toEqual(['Yes, run the deep hunt for rev_1.'])
})

test('a deep_offer for a hunt the mod does not track draws no band', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: findingsWith({ review_id: 'rev_x', deep_offer: { pitch: 'Go deep.' } }) }))
  world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_x' } as never)
  expect(await buttons($)).toEqual([])
})

test('a status URL the network refuses is said in the status line, not hidden', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, null)
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(seen.status.at(-1)).toContain('status unreachable here')
})

const CONFIRM = 'mcp__plugin_bughunter_ohmybug__confirm_findings'
const confirmCard = async ($: Dollar, species: unknown[]) => drawn($, 'ToolResult', { tool_use_id: 'c1', tool: CONFIRM,
  output: JSON.stringify({ confirmed: 1, species }), isErrored: false }, 'c1')

test('the confirm card shows each species with its page and field notes', async ($, on) => {
  mock.store(on)
  engine(on)
  const texts = await confirmCard($, [{ finding_id: 'f_1', slug: 'retry-twice', name: 'Retry twice',
    url: 'https://bugs.test/retry-twice', lessons: ['Make the retry idempotent.', 'Key the write by request id.'] }])
  expect(texts).toContain('Retry twice')
  expect(texts).toContain('https://bugs.test/retry-twice')
  expect(texts).toContain('    · Make the retry idempotent.')
  expect(texts).toContain('2 field notes from other hunters are in the agent\'s context')
})

test('a species without lessons draws no field-note lines', async ($, on) => {
  mock.store(on)
  engine(on)
  const texts = await confirmCard($, [{ finding_id: 'f_1', slug: 'retry-twice', name: 'Retry twice' }])
  expect(texts).toContain('Retry twice')
  expect(texts).not.toContain('field note')
  expect(texts).not.toContain('    · ')
})

/** The prompt text the mod adds, as the model would read it. */
async function nextStep($: Dollar) {
  const { sections } = await $.prompt.compose({ model: 'm', promptModel: 'm', surfaces: ['terminal'], tools: [], outputStyle: null, traits: [] })
  return sections.filter(x => x.id === 'bughunter:next-step').map(x => x.text).join('\n')
}
const composeBeneath = (on: On) =>
  on('prompt.compose', async () => ({ sections: [{ id: 'intro', text: 'engine', scope: 'shared' as const }] }))
const confirmed = (id: string) => JSON.stringify({ review_id: id, confirmed: 1 })

test('a read hunt without verdicts is named in the prompt and the status line until confirm', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  composeBeneath(on)
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  on('tool.call', { tool: CONFIRM }, async () => ({ result: { content: [] }, text: confirmed('rev_1') }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  expect(await nextStep($)).toBe('')
  await clock.advance(75_000)
  expect(await nextStep($)).toBe('')
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await nextStep($)).toBe('OhMyBug hunt rev_1 is done and its verdicts are not sent. Next: verify each finding, then confirm_findings for rev_1.')
  expect(seen.status.at(-1)).toBe('bughunt rev_1 · verdicts not sent')
  await $.tool.call({ tool: CONFIRM, review_id: 'rev_1' } as never)
  expect(await nextStep($)).toBe('')
  expect(seen.status.at(-1)).toBeUndefined()
})

test('a read hunt with 0 findings is told to confirm with an empty verdict list', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  composeBeneath(on)
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: JSON.stringify({ review_id: 'rev_1', status: 'done', findings: [] }) }))
  world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await nextStep($)).toBe('OhMyBug hunt rev_1 is done with 0 findings and is not confirmed yet. Next: confirm_findings for rev_1 with verdicts: [].')
})

test('a running hunt wins the status line over an earlier one without verdicts', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const ids = ['rev_a', 'rev_b']
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: JSON.stringify({ ...JSON.parse(submitted), review_id: ids.shift() }) }))
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: findingsWith({ review_id: 'rev_a' }) }))
  const seen = world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_a' } as never)
  expect(seen.status.at(-1)).toBe('bughunt rev_a · verdicts not sent')
  await $.tool.call({ tool: SUBMIT } as never)
  expect(seen.status.at(-1)).toMatch(/^bughunt fast 0/)
})

test('of two read hunts only the one without verdicts is named', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  composeBeneath(on)
  engine(on)
  const answer = (id: string) => JSON.stringify({ review_id: id, status: 'done', mode: 'fast',
    status_url: `https://status.test/r/${id}/status` })
  const ids = ['rev_a', 'rev_b']
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: answer(ids.shift()!) }))
  on('tool.call', { tool: CONFIRM }, async () => ({ result: { content: [] }, text: confirmed('rev_a') }))
  on('ui.status', async () => ({ value: undefined }) as never)
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: CONFIRM, review_id: 'rev_a' } as never)
  const text = await nextStep($)
  expect(text).toContain('hunt rev_b is done')
  expect(text).not.toContain('rev_a')
})

test('OHMYBUG_STATUS=0 keeps the status line clear and the prompt line out', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, { OHMYBUG_STATUS: '0' })
  composeBeneath(on)
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(seen.status).toHaveLength(0)
  expect(await nextStep($)).toBe('')
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`the findings card lists findings by severity on ${surface}`, async ($, on) => {
    mock.store(on)
    engine(on)
    const ui = await $.ui.mount({ plugin: 'bughunter', surface, component: 'ToolResult', requestId: 't1',
      props: { tool_use_id: 't1', tool: GET, output: done, isErrored: false } } as never)
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
    expect(texts).toContain('fast hunt rev_1 · done · 2 findings')
    expect(texts.indexOf('Refund retried twice')).toBeLessThan(texts.indexOf('Log line leaks'))
  })

  test(`an answer the card cannot read is drawn by the engine on ${surface}`, async ($, on) => {
    mock.store(on)
    engine(on)
    const ui = await $.ui.mount({ plugin: 'bughunter', surface, component: 'ToolResult', requestId: 't2',
      props: { tool_use_id: 't2', tool: GET, output: 'not json', isErrored: false } } as never)
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
    expect(texts).not.toContain('hunt')
  })
}
