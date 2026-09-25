import { useEffect, useMemo, useState } from "react"
import { Box, Text, useInput, useWindowSize } from "ink"
import { request, type Connection } from "../daemon.js"
import { wrap } from "./transcript.js"

export type ContextSection = {
  id: string
  label: string
  kind: "instructions" | "extension_context" | "history" | "tools" | "other"
  source: string
  item_count: number
  byte_count: number
  preview: string
  pages: number
}

export type CompactionState = {
  strategy?: string
  status: "not_configured" | "not_needed" | "compacted" | "unknown"
  source?: string
  trigger_free_percent?: number
  input_limit_tokens?: number
  estimated_input_tokens?: number
  provider_input_tokens?: number
  provider_cached_input_tokens?: number
  estimate_method?: string
  before_items?: number
  after_items?: number
}

export type ContextSnapshot =
  | { state: "pending"; reason: string }
  | {
      state: "ready"
      captured_at?: number
      provider?: string
      model: string
      protocol?: string
      context_window_tokens?: number
      sections: ContextSection[]
      compaction: CompactionState
    }

export type ContextPage = {
  section: string
  page: number
  pages: number
  content: string
  omitted?: string
}

type ContextInspectorProps = {
  connection: Connection
  sessionId: string
  onCancel: () => void
}

type Detail = { section: ContextSection; page: number; value?: ContextPage; error?: string }

const upgrade = "daemon upgrade needed for /context; when ready, run albedo daemon --stop, then albedo (this clears python variables)"
const message = (error: unknown): string => error instanceof Error ? error.message : String(error)
const integer = (value: unknown): value is number => Number.isSafeInteger(value) && (value as number) >= 0
const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value)
const text = (value: unknown, limit: number): value is string => typeof value === "string" && value.length <= limit

const parseSection = (value: unknown): ContextSection | undefined => {
  if (!value || typeof value !== "object") return
  const section = value as Partial<ContextSection>
  if (!text(section.id, 200) || !section.id || !text(section.label, 200) || !section.label ||
      !["instructions", "extension_context", "history", "tools", "other"].includes(String(section.kind)) ||
      !text(section.source, 500) || !integer(section.item_count) || !integer(section.byte_count) ||
      !text(section.preview, 2_000) || !integer(section.pages) || section.pages > 10_000) return
  return section as ContextSection
}

export const parseContextSnapshot = (value: unknown): ContextSnapshot => {
  if (!value || typeof value !== "object") throw new Error("daemon returned invalid context metadata")
  const snapshot = value as Record<string, unknown>
  if (snapshot.state === "pending" && text(snapshot.reason, 500)) return { state: "pending", reason: snapshot.reason }
  if (snapshot.state !== "ready" || !text(snapshot.model, 512) || !Array.isArray(snapshot.sections) || snapshot.sections.length > 1_000)
    throw new Error("daemon returned invalid context metadata")
  const sections = snapshot.sections.map(parseSection)
  if (sections.some(section => !section)) throw new Error("daemon returned invalid context section metadata")
  const raw = snapshot.compaction
  if (!raw || typeof raw !== "object") throw new Error("daemon returned invalid compaction metadata")
  const compaction = raw as Record<string, unknown>
  if (!["not_configured", "not_needed", "compacted", "unknown"].includes(String(compaction.status)))
    throw new Error("daemon returned invalid compaction metadata")
  const optionalText = (key: string, limit: number): string | undefined => compaction[key] === undefined ? undefined
    : text(compaction[key], limit) ? compaction[key] as string : (() => { throw new Error("daemon returned invalid compaction metadata") })()
  const optionalInteger = (key: string): number | undefined => compaction[key] === undefined ? undefined
    : integer(compaction[key]) ? compaction[key] as number : (() => { throw new Error("daemon returned invalid compaction metadata") })()
  const free = compaction.trigger_free_percent
  if (free !== undefined && (!finite(free) || (free as number) < 0 || (free as number) > 100))
    throw new Error("daemon returned invalid compaction metadata")
  const captured = snapshot.captured_at
  const contextWindow = snapshot.context_window_tokens
  if (captured !== undefined && !integer(captured) || contextWindow !== undefined && !integer(contextWindow))
    throw new Error("daemon returned invalid context metadata")
  for (const key of ["provider", "protocol"])
    if (snapshot[key] !== undefined && !text(snapshot[key], 512)) throw new Error("daemon returned invalid context metadata")
  return {
    state: "ready",
    ...(captured === undefined ? {} : { captured_at: captured as number }),
    ...(snapshot.provider === undefined ? {} : { provider: snapshot.provider as string }),
    model: snapshot.model,
    ...(snapshot.protocol === undefined ? {} : { protocol: snapshot.protocol as string }),
    ...(contextWindow === undefined ? {} : { context_window_tokens: contextWindow as number }),
    sections: sections as ContextSection[],
    compaction: {
      status: compaction.status as CompactionState["status"],
      ...(optionalText("strategy", 200) === undefined ? {} : { strategy: optionalText("strategy", 200) }),
      ...(optionalText("source", 500) === undefined ? {} : { source: optionalText("source", 500) }),
      ...(free === undefined ? {} : { trigger_free_percent: free as number }),
      ...(optionalInteger("input_limit_tokens") === undefined ? {} : { input_limit_tokens: optionalInteger("input_limit_tokens") }),
      ...(optionalInteger("estimated_input_tokens") === undefined ? {} : { estimated_input_tokens: optionalInteger("estimated_input_tokens") }),
      ...(optionalInteger("provider_input_tokens") === undefined ? {} : { provider_input_tokens: optionalInteger("provider_input_tokens") }),
      ...(optionalInteger("provider_cached_input_tokens") === undefined ? {} : { provider_cached_input_tokens: optionalInteger("provider_cached_input_tokens") }),
      ...(optionalText("estimate_method", 500) === undefined ? {} : { estimate_method: optionalText("estimate_method", 500) }),
      ...(optionalInteger("before_items") === undefined ? {} : { before_items: optionalInteger("before_items") }),
      ...(optionalInteger("after_items") === undefined ? {} : { after_items: optionalInteger("after_items") }),
    },
  }
}

export const parseContextPage = (value: unknown, expectedSection: string): ContextPage => {
  if (!value || typeof value !== "object") throw new Error("daemon returned invalid context page")
  const page = value as Partial<ContextPage>
  if (page.section !== expectedSection || !integer(page.page) || !integer(page.pages) || page.pages > 10_000 ||
      page.page >= Math.max(1, page.pages) || !text(page.content, 65_536) ||
      page.omitted !== undefined && !text(page.omitted, 1_000)) throw new Error("daemon returned invalid context page")
  return page as ContextPage
}

const count = (value: number, unit: string): string => `${value.toLocaleString("en-US")} ${unit}${value === 1 ? "" : "s"}`
const compactionLabel = (state: CompactionState): string => {
  const name = state.strategy || "none"
  const status = ({ not_configured: "not configured", not_needed: "not needed", compacted: "applied", unknown: "state unavailable" })[state.status]
  return `${name} · ${status}`
}

export function ContextInspector({ connection, sessionId, onCancel }: ContextInspectorProps) {
  const [snapshot, setSnapshot] = useState<ContextSnapshot>()
  const [error, setError] = useState("")
  const [revision, retry] = useState(0)
  const [selected, setSelected] = useState(0)
  const [detail, setDetail] = useState<Detail>()
  const [scroll, setScroll] = useState(0)
  const { columns, rows } = useWindowSize()

  useEffect(() => {
    let active = true
    setSnapshot(undefined); setError(""); setDetail(undefined)
    void request<{ capabilities?: string[] }>(connection, "/health").then(health => {
      if (!health.capabilities?.includes("session_context")) throw new Error(upgrade)
      return request<unknown>(connection, `/sessions/${encodeURIComponent(sessionId)}/context`)
    }).then(value => { if (active) setSnapshot(parseContextSnapshot(value)) }).catch(cause => { if (active) setError(message(cause)) })
    return () => { active = false }
  }, [connection, sessionId, revision])

  const loadPage = (section: ContextSection, page: number): void => {
    if (section.pages === 0) return
    const next = Math.max(0, Math.min(section.pages - 1, page))
    setDetail({ section, page: next }); setScroll(0)
    void request<unknown>(connection, `/sessions/${encodeURIComponent(sessionId)}/context/${encodeURIComponent(section.id)}/${next}`)
      .then(value => setDetail(current => current?.section.id === section.id && current.page === next
        ? { ...current, value: parseContextPage(value, section.id) } : current))
      .catch(cause => setDetail(current => current?.section.id === section.id && current.page === next
        ? { ...current, error: message(cause) } : current))
  }

  const sections = snapshot?.state === "ready" ? snapshot.sections : []
  const index = Math.min(selected, Math.max(0, sections.length - 1))
  const visibleRows = Math.max(1, rows - 7)
  const sectionCapacity = Math.max(1, Math.floor((rows - 9) / 3))
  const sectionStart = Math.min(
    Math.max(0, index - Math.floor(sectionCapacity / 2)),
    Math.max(0, sections.length - sectionCapacity),
  )
  const visibleSections = sections.slice(sectionStart, sectionStart + sectionCapacity)
  const detailRows = useMemo(() => detail?.value ? wrap(detail.value.content, Math.max(1, columns - 4)) : [], [detail?.value, columns])
  const maxScroll = Math.max(0, detailRows.length - visibleRows)

  useInput((input, key) => {
    if (key.escape || key.ctrl && ["c", "d"].includes(input)) {
      if (detail) { setDetail(undefined); setScroll(0) } else onCancel()
      return
    }
    if (error || snapshot?.state === "pending") {
      if (input.toLowerCase() === "r") retry(value => value + 1)
      return
    }
    if (detail) {
      if (key.leftArrow && detail.page > 0) loadPage(detail.section, detail.page - 1)
      else if (key.rightArrow && detail.page + 1 < detail.section.pages) loadPage(detail.section, detail.page + 1)
      else if (key.upArrow) setScroll(value => Math.max(0, value - 1))
      else if (key.downArrow) setScroll(value => Math.min(maxScroll, value + 1))
      else if (key.pageUp) setScroll(value => Math.max(0, value - visibleRows))
      else if (key.pageDown) setScroll(value => Math.min(maxScroll, value + visibleRows))
      return
    }
    if (input.toLowerCase() === "r") retry(value => value + 1)
    else if (key.upArrow || key.downArrow) setSelected(Math.max(0, Math.min(sections.length - 1, index + (key.upArrow ? -1 : 1))))
    else if (key.return && sections[index]?.pages) loadPage(sections[index]!, 0)
  })

  if (detail) return <Box flexDirection="column">
    <Text>albedo /context · {detail.section.label}</Text>
    <Text dimColor>{detail.section.source} · page {detail.page + 1}/{detail.section.pages} · {count(detail.section.byte_count, "byte")}</Text>
    {detail.error ? <Text color="red" wrap="wrap">{detail.error}</Text>
      : !detail.value ? <Text dimColor>loading inspectable prepared content…</Text>
        : <>
          {detail.value.omitted && <Text color="yellow" wrap="wrap">omitted: {detail.value.omitted}</Text>}
          <Box flexDirection="column" marginTop={1}>{detailRows.slice(scroll, scroll + visibleRows).map((line, row) => <Text key={`${scroll + row}:${line}`}>{line || " "}</Text>)}</Box>
        </>}
    <Text dimColor>↑↓ scroll · pgup/pgdn jump · ←→ page · esc sections</Text>
  </Box>

  return <Box flexDirection="column">
    <Text>albedo /context · prepared request</Text>
    <Text dimColor>read-only · durable transcript and request-only context are separate</Text>
    {error && <Text color="red" wrap="wrap">{error}</Text>}
    {!snapshot ? <Text dimColor>{error ? "r retry · esc return to chat" : "loading prepared request snapshot…"}</Text>
      : snapshot.state === "pending" ? <>
        <Text color="yellow">pending · no request has been prepared for this runtime session</Text>
        <Text dimColor>{snapshot.reason}</Text>
        <Text dimColor>r refresh · esc return to chat</Text>
      </> : <>
        <Text>{snapshot.provider ? `${snapshot.provider} · ` : ""}{snapshot.model}{snapshot.protocol ? ` · ${snapshot.protocol}` : ""}</Text>
        <Text dimColor>context window: {snapshot.context_window_tokens === undefined ? "not reported" : `${snapshot.context_window_tokens.toLocaleString("en-US")} tokens (configured)`}</Text>
        <Text dimColor>compaction: {compactionLabel(snapshot.compaction)}</Text>
        {snapshot.compaction.trigger_free_percent !== undefined && <Text dimColor>trigger: keep {snapshot.compaction.trigger_free_percent}% free</Text>}
        {snapshot.compaction.provider_input_tokens !== undefined
          ? <Text dimColor>provider input: {snapshot.compaction.provider_input_tokens.toLocaleString("en-US")} tokens{snapshot.compaction.provider_cached_input_tokens === undefined ? "" : ` · ${snapshot.compaction.provider_cached_input_tokens.toLocaleString("en-US")} cached tokens`}</Text>
          : snapshot.compaction.estimated_input_tokens !== undefined && <Text dimColor>estimated input: {snapshot.compaction.estimated_input_tokens.toLocaleString("en-US")} tokens · {snapshot.compaction.estimate_method || "method not reported"}</Text>}
        <Box flexDirection="column" marginTop={1}>{visibleSections.map((section, row) => {
          const position = sectionStart + row
          return <Box key={section.id} flexDirection="column">
            <Text color={position === index ? "cyan" : undefined}>{position === index ? ">" : " "} {position + 1}. {section.label} <Text dimColor>· {section.source}</Text></Text>
            <Text dimColor>  {count(section.item_count, "item")} · {count(section.byte_count, "measured byte")}{section.pages ? ` · ${count(section.pages, "page")}` : " · content unavailable"}</Text>
            {position === index && section.preview && <Text wrap="truncate">  {section.preview}</Text>}
          </Box>
        })}</Box>
        {!sections.length && <Text dimColor>the prepared request contains no inspectable sections</Text>}
        {sections.length > visibleSections.length && <Text dimColor>showing {sectionStart + 1}–{sectionStart + visibleSections.length} of {sections.length} sections</Text>}
        <Text dimColor>↑↓ select · enter inspect content · r refresh · esc return to chat</Text>
      </>}
  </Box>
}
