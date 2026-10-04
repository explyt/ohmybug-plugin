import { expect, mock, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

type Dollar = Parameters<TestBody>[0]
type On = Parameters<TestBody>[1]

const SUBMIT = 'mcp__plugin_bughunter_ohmybug__submit_review'
const GET = 'mcp__plugin_bughunter_ohmybug__get_findings'
const VIEW = { scroll: { top: 0, bodyRows: 10 }, view: {} }

/** The texts a component draws, as the person would read them. */
async function drawn($: Dollar, component: string, props: Record<string, unknown>, requestId = 'x') {
  const ui = await $.ui.mount({ plugin: 'bughunter', surface: 'terminal', component, requestId, props } as never)
  return (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
}
const band = ($: Dollar) => drawn($, 'AbovePrompt', { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100, ...VIEW })
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
  on('ui.render', async ($, e) => { const { Text } = $.ui.resolve(e); return Text({ children: 'engine drawing' } as never) })
}

function world(on: On, status: string | null) {
  const seen = { toasts: [] as string[], status: [] as (string | undefined)[], prompts: [] as string[] }
  engine(on)
  on('http.fetch', async () => (status === null ? { deny: 'refused by policy' } : { value: { status: 200, ok: true, headers: {}, text: status } }) as never)
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
  expect(seen.prompts).toHaveLength(0)
})

test('reading the result itself marks the hunt read and clears the band', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await band($)).not.toContain('OhMyBug')
  const list = await pane($)
  expect(list).toContain('2 found')
  expect(list).not.toContain('not read yet')
})

test('with OHMYBUG_AUTO_RESUME=1, a finished hunt resumes an idle session', async ($, on) => {
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

test('a merge the gate refused raises a band with the gate\'s own reason', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  engine(on)
  on('tool.call', { tool: 'Bash' }, async () => ({ deny: 'OhMyBug: a hunt is RUNNING for this diff and has not returned yet.' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: 'Bash', command: 'gh pr merge 12 --squash' } as never)
  expect(await band($)).toContain('Merge blocked: a hunt is RUNNING for this diff and has not returned yet.')
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
