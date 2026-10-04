// Pure readers of what the OhMyBug MCP tools and status URL answer. Every
// reader returns undefined on a shape it does not know, and the caller then
// leaves the engine's own drawing alone: this mod renders, it never decides.

export const OMB_TOOL = /^mcp__.*ohmybug.*__(submit_review|get_findings|wait_review|confirm_findings)$/

export const toolKind = (tool: string): string | undefined => OMB_TOOL.exec(tool)?.[1]

/** The text an MCP result carries: a string, content blocks, or { content }. */
export function textOf(output: unknown): string | undefined {
  if (typeof output === 'string') return output
  const blocks = Array.isArray(output) ? output
    : output && typeof output === 'object' && Array.isArray((output as { content?: unknown }).content)
      ? (output as { content: unknown[] }).content : undefined
  if (!blocks) return undefined
  const text = blocks.map(b => (b && typeof b === 'object' && (b as { type?: unknown }).type === 'text'
    ? String((b as { text?: unknown }).text ?? '') : '')).join('')
  return text || undefined
}

export type Body = Record<string, unknown>

/** The JSON object an OhMyBug tool answered, or undefined. */
export function bodyOf(output: unknown): Body | undefined {
  const text = textOf(output)
  if (!text) return undefined
  try {
    const v: unknown = JSON.parse(text)
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Body) : undefined
  } catch {
    return undefined
  }
}

export const str = (v: unknown): string | undefined => (typeof v === 'string' && v ? v : undefined)
export const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined)

export type Finding = { id: string; severity: string; where: string; title: string }

export function findingsOf(body: Body): Finding[] {
  const list = Array.isArray(body.findings) ? body.findings : []
  return list.flatMap(f => {
    if (!f || typeof f !== 'object') return []
    const o = f as Body
    const id = str(o.finding_id) ?? str(o.id)
    if (!id) return []
    const line = num(o.line)
    return [{ id, severity: (str(o.severity) ?? '?').toLowerCase(), title: str(o.title) ?? '',
      where: str(o.file) ? `${o.file}${line ? `:${line}` : ''}` : '' }]
  })
}

/** The status a poll of the status URL reports, in the mod's own words. */
export function pollState(body: Body): 'running' | 'needs_files' | 'done' | 'failed' | undefined {
  const s = str(body.status)
  if (s === 'done' || s === 'failed') return s
  // Either flag means reviewers wait on files; the status word stays 'running'.
  if (body.files_requested === true || body.awaiting_client_files === true || s === 'needs_files') return 'needs_files'
  return s ? 'running' : undefined
}

export const minutes = (ms: number): number => Math.max(0, Math.round(ms / 60000))
