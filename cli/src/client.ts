import { createToolProgressReporter } from "./progress.js"
import { parseToolTrace, type StreamEvent, type ToolProgress } from "./events.js"

export type { StreamEvent, ToolTrace, ToolProgress } from "./events.js"

export type FetchLike = (input: URL | RequestInfo, init?: RequestInit) => Promise<Response>

export interface CreateChatClientOptions {
  baseUrl: string
  fetchImpl?: FetchLike
  clientId?: string
  agentId?: string
}

export interface StreamOptions {
  signal?: AbortSignal
  onOpen?: () => void
  onEvent: (event: StreamEvent) => void
}

export type AgentPhase = "resting" | "preparing" | "reasoning" | "tool" | "waiting"
export type AgentStatus = { running: boolean; idle: boolean; phase?: AgentPhase }

export interface ChatClient {
  /** The sender identity used by send; lets views suppress their optimistic echo. */
  readonly clientId?: string
  send: (content: string) => Promise<{ ok: true }>
  interrupt?: () => Promise<{ interrupted: boolean }>
  getStatus: () => Promise<AgentStatus>
  stream: (options: StreamOptions) => Promise<void>
}

type UnknownEvent = {
  type?: unknown
  text?: unknown
  source?: unknown
  triggeredAt?: unknown
  timestamp?: unknown
  clientId?: unknown
  name?: unknown
  args?: unknown
  result?: unknown
  trace?: unknown
  progress?: unknown
  model?: unknown
  recordedAt?: unknown
  promptTokens?: unknown
  cachedPromptTokens?: unknown
  cacheWriteTokens?: unknown
  completionTokens?: unknown
  totalTokens?: unknown
  elapsedMs?: unknown
  tokensPerSecond?: unknown
}

const AGENT_PHASES = new Set<AgentPhase>(["resting", "preparing", "reasoning", "tool", "waiting"])

const normalizeUrl = (baseUrl: string): string =>
  baseUrl.endsWith("/") ? baseUrl.slice(0, -1) : baseUrl

const toEvent = (raw: unknown): StreamEvent | null => {
  if (!raw || typeof raw !== "object") return null

  const event = raw as UnknownEvent
  const stamp = typeof event.timestamp === "number" && Number.isSafeInteger(event.timestamp) && event.timestamp >= 0 ? { timestamp: event.timestamp } : {}
  if (event.type === "tool_progress") {
    if (event.progress === null) return { type: "tool_progress", progress: null }
    if (!event.progress || typeof event.progress !== "object") return null
    const progress = event.progress as Partial<ToolProgress>
    if (typeof progress.callId !== "string" || progress.callId.length > 200 ||
        typeof progress.name !== "string" || progress.name.length > 100 ||
        (progress.phase !== "generating" && progress.phase !== "running")) return null
    const intent = progress.intent
    const code = progress.code
    return { type: "tool_progress", progress: {
      ...(progress.phase === "generating" && code && Number.isSafeInteger(code.offset) && code.offset >= 0 &&
        typeof code.text === "string" && code.text.length <= 512 ? { code: { offset: code.offset, text: code.text } } : {}),
      callId: progress.callId, name: progress.name.replace(/[\p{Cc}\p{Cf}]/gu, " "), phase: progress.phase,
      ...(intent && ["write", "edit", "read", "run"].includes(intent.kind) &&
        typeof intent.target === "string" && intent.target.length <= 300 ? { intent: { kind: intent.kind, target: intent.target } } : {}),
    } }
  }
  if (event.type === "message" && typeof event.text === "string") return { type: "message", role: "assistant", text: event.text, ...stamp }
  if (event.type === "interrupted") return { type: "interrupted" }

  if (
    event.type === "user" &&
    typeof event.text === "string" &&
    typeof event.source === "string" &&
    typeof event.triggeredAt === "string"
  ) {
    return {
      type: "user",
      text: event.text,
      source: event.source,
      triggeredAt: event.triggeredAt,
      ...stamp,
      clientId: typeof event.clientId === "string" ? event.clientId : undefined,
    }
  }

  if (event.type === "thinking" && typeof event.text === "string") {
    return { type: "thinking", text: event.text }
  }

  if (event.type === "error" && typeof event.text === "string") {
    return { type: "error", text: event.text }
  }

  if (
    event.type === "tool" &&
    typeof event.name === "string" &&
    typeof event.result === "string" &&
    event.args &&
    typeof event.args === "object"
  ) {
    const trace = parseToolTrace(event.trace)
    return {
      type: "tool",
      name: event.name,
      args: event.args as Record<string, unknown>,
      result: event.result,
      ...(trace ? { trace } : {}),
    }
  }

  if (event.type === "usage") {
    return {
      type: "usage",
      model: typeof event.model === "string" ? event.model : undefined,
      recordedAt: typeof event.recordedAt === "number" && Number.isFinite(event.recordedAt) ? event.recordedAt : undefined,
      promptTokens: typeof event.promptTokens === "number" ? event.promptTokens : undefined,
      cachedPromptTokens: typeof event.cachedPromptTokens === "number" ? event.cachedPromptTokens : undefined,
      cacheWriteTokens: typeof event.cacheWriteTokens === "number" ? event.cacheWriteTokens : undefined,
      completionTokens: typeof event.completionTokens === "number" ? event.completionTokens : undefined,
      totalTokens: typeof event.totalTokens === "number" ? event.totalTokens : undefined,
      elapsedMs: typeof event.elapsedMs === "number" ? event.elapsedMs : undefined,
      tokensPerSecond: typeof event.tokensPerSecond === "number" ? event.tokensPerSecond : undefined,
    }
  }

  if (typeof event.text === "string") {
    return { type: "text", text: event.text }
  }

  return null
}

/** Conversation records carry the durable text of a turn; only the agent's own replies are new information. */
const toMessage = (raw: unknown): StreamEvent | null => {
  if (!raw || typeof raw !== "object") return null
  const record = raw as { role?: unknown; content?: unknown }
  if (record.role !== "assistant" || typeof record.content !== "string" || !record.content.trim()) return null
  return { type: "message", role: "assistant", text: record.content }
}

const parseError = async (res: Response): Promise<string> => {
  const fallback = `${res.status} ${res.statusText}`.trim()

  try {
    const data = (await res.json()) as { error?: unknown }
    if (typeof data.error === "string" && data.error.trim()) return data.error
  } catch {}

  return fallback || "request failed"
}

const splitLines = (chunkBuffer: string): { lines: string[]; rest: string } => {
  const normalized = chunkBuffer.replace(/\r\n/g, "\n")
  const lines = normalized.split("\n")
  const rest = lines.pop() ?? ""
  return { lines, rest }
}

export function createChatClient(options: CreateChatClientOptions): ChatClient {
  const fetchImpl = options.fetchImpl ?? fetch
  const baseUrl = normalizeUrl(options.baseUrl)
  const clientId = options.clientId ?? `cli-${crypto.randomUUID()}`
  const agentId = options.agentId?.trim()
  const headers = (json = false): HeadersInit => ({
    ...(json ? { "content-type": "application/json" } : {}),
  })
  const url = (path: string) => `${baseUrl}${path}`
  const agentUrl = (path: string) =>
    agentId ? url(`/sessions/${encodeURIComponent(agentId)}${path}`) : url(path)

  const send: ChatClient["send"] = async (content) => {
    const res = await fetchImpl(agentUrl(agentId ? "/events" : "/trigger/chat"), {
      method: "POST",
      headers: headers(true),
      body: JSON.stringify({ content, ...(clientId ? { clientId } : {}) }),
    })

    if (!res.ok) {
      throw new Error(await parseError(res))
    }

    return { ok: true }
  }

  const interrupt = async (): Promise<{ interrupted: boolean }> => {
    const res = await fetchImpl(agentUrl(agentId ? "/interrupt" : "/awp/interrupt"), { method: "POST", headers: headers(), signal: AbortSignal.timeout(15_000) })
    if (!res.ok) throw new Error(await parseError(res))
    const data = await res.json() as { interrupted?: unknown }
    return { interrupted: data.interrupted === true }
  }

  const getStatus: ChatClient["getStatus"] = async () => {
    const res = await fetchImpl(agentUrl("/status"), { headers: headers() })
    if (!res.ok) {
      throw new Error(await parseError(res))
    }

    const data = (await res.json()) as { running?: unknown; idle?: unknown; phase?: unknown }
    const phase = typeof data.phase === "string" && AGENT_PHASES.has(data.phase as AgentPhase)
      ? data.phase as AgentPhase
      : undefined
    return { running: data.running === true, idle: data.idle === true, ...(phase ? { phase } : {}) }
  }

  let afterSeq = -1
  const argumentsByCall = new Map<string, string>()
  const stream: ChatClient["stream"] = async ({ signal, onOpen, onEvent }) => {
    const route = agentId
      ? `/stream?after_seq=${afterSeq}`
      : `/awp/stream?${afterSeq ? `after_seq=${afterSeq}` : "tail=true"}`
    const res = await fetchImpl(agentUrl(route), { signal, headers: headers() })
    if (!res.ok || !res.body) {
      throw new Error(res.ok ? "stream body missing" : await parseError(res))
    }
    onOpen?.()

    const reader = res.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ""
    let eventSeq = afterSeq
    let eventType = ""
    const report = createToolProgressReporter(progress => onEvent({ type: "tool_progress", progress }))
    const cancel = (): void => { void reader.cancel().catch(() => {}) }
    signal?.addEventListener("abort", cancel, { once: true })

    try {
      while (!signal?.aborted) {
        const { done, value } = await reader.read()
        if (done) break

        buffer += decoder.decode(value, { stream: true })
        const { lines, rest } = splitLines(buffer)
        buffer = rest

        for (const line of lines) {
          if (!line) eventType = ""
          if (line.startsWith("event:")) eventType = line.slice(6).trim()
          if (line.startsWith("id:")) {
            const sequence = Number(line.slice(3).trim())
            if (Number.isSafeInteger(sequence) && sequence > 0) {
              eventSeq = sequence
            }
          }
          if (!line.startsWith("data:")) continue

          const payload = line.slice(5).trimStart()
          if (!payload) continue

          let raw: unknown
          try { raw = JSON.parse(payload) } catch { continue }
          if (eventType === "error") {
            const error = raw as { error?: unknown; text?: unknown } | null
            throw new Error(typeof error?.error === "string" ? error.error : typeof error?.text === "string" ? error.text : "stream failed")
          }
          const page = raw as { cursor?: unknown; events?: unknown }
          if (Number.isSafeInteger(page?.cursor) && Array.isArray(page.events)) {
            for (const serialized of page.events) {
              const item = serialized as Record<string, unknown>
              if (["reset", "turn_started", "message", "interrupted", "error"].includes(String(item.type))) {
                argumentsByCall.clear()
                report(null, "running")
              }
              if (item.type === "reset") { onEvent({ type: "reset" }); continue }
              if (item.type === "turn_started") continue
              if (item.type === "tool") {
                if (typeof item.callId === "string") argumentsByCall.delete(item.callId)
                report(null, "running")
              }
              if (item.type === "tool_progress") {
                const progress = item.progress as Partial<ToolProgress> | null
                if (progress?.phase === "running" && typeof progress.callId === "string") {
                  argumentsByCall.delete(progress.callId)
                  report(null, "running")
                }
              }
              if (item.type === "arguments_delta" && typeof item.callId === "string" && typeof item.text === "string") {
                const args = (argumentsByCall.get(item.callId) ?? "") + item.text
                if (args.length > 2_000_000) throw new Error("tool arguments exceed client limit")
                argumentsByCall.set(item.callId, args)
                report({ id: item.callId, function: { name: "python", arguments: args } }, "generating")
                continue
              }
              if (item.type === "tool" && typeof item.args === "string") {
                try { item.args = JSON.parse(item.args) } catch { item.args = {} }
              }
              const event = toEvent(item)
              if (event) onEvent(event)
            }
            afterSeq = page.cursor as number
            continue
          }
          const envelope = raw && typeof raw === "object" ? (raw as { type?: unknown; payload?: unknown }) : null
          const event = envelope?.type === "stream.event"
            ? toEvent(envelope.payload)
            : envelope?.type === "conversation.message"
              ? toMessage(envelope.payload)
              : toEvent(raw)
          if (event) onEvent(event)
          afterSeq = Math.max(afterSeq, eventSeq)
        }
      }
    } finally {
      // Keep only unfinished raw arguments for cursor-based reconnection, never
      // their decoded code or syntax tree while the transport is disconnected.
      signal?.removeEventListener("abort", cancel)
      await reader.cancel().catch(() => {})
      reader.releaseLock()
      report(null, "running")
    }
  }

  return {
    clientId,
    send,
    interrupt,
    getStatus,
    stream,
  }
}
