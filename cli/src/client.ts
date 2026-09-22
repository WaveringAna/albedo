import { createToolProgressReporter } from "./progress.js"
import { parseToolTrace, type StreamEvent, type ToolProgress } from "./events.js"
import { parseImageMetadata, type ImageAttachment } from "./image.js"

export type { StreamEvent, ToolTrace, ToolProgress } from "./events.js"
export type { ImageAttachment, ImageMetadata } from "./image.js"

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
export type WorkspaceUpdate = { workspace: string }

export class WorkspaceMissingError extends Error {
  readonly name = "WorkspaceMissingError"
  constructor(readonly workspace: string) {
    super(`workspace not found: ${workspace}`)
  }
}

export interface ChatClient {
  /** The sender identity used by send; lets views suppress their optimistic echo. */
  readonly clientId?: string
  send: (content: string, signal?: AbortSignal, image?: ImageAttachment) => Promise<{ ok: true; queued?: boolean }>
  replaceWorkspace?: (workspace: string, signal?: AbortSignal) => Promise<WorkspaceUpdate>
  interrupt?: () => Promise<{ interrupted: boolean }>
  getStatus: (signal?: AbortSignal) => Promise<AgentStatus>
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
  image?: unknown
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
  if (event.type === "retry") return { type: "retry" }

  if (
    event.type === "user" &&
    typeof event.text === "string" &&
    typeof event.source === "string" &&
    typeof event.triggeredAt === "string"
  ) {
    const image = parseImageMetadata(event.image)
    return {
      type: "user",
      text: event.text,
      source: event.source,
      triggeredAt: event.triggeredAt,
      ...stamp,
      ...(typeof event.clientId === "string" ? { clientId: event.clientId } : {}),
      ...(image ? { image } : {}),
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

const responseError = async (res: Response): Promise<Error> => {
  const fallback = `${res.status} ${res.statusText}`.trim() || "request failed"

  try {
    const data = (await res.json()) as { code?: unknown; error?: unknown; workspace?: unknown }
    if (data.code === "workspace_missing" && typeof data.workspace === "string")
      return new WorkspaceMissingError(data.workspace)
    if (typeof data.error === "string" && data.error.trim()) return new Error(data.error)
  } catch {}

  return new Error(fallback)
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

  const requestSignal = (signal?: AbortSignal): AbortSignal => signal
    ? AbortSignal.any([signal, AbortSignal.timeout(20_000)]) : AbortSignal.timeout(20_000)
  const send: ChatClient["send"] = async (content, signal, image) => {
    const res = await fetchImpl(agentUrl(agentId ? "/events" : "/trigger/chat"), {
      method: "POST",
      headers: headers(true),
      body: JSON.stringify({ content, ...(image ? { image } : {}), ...(clientId ? { clientId } : {}) }),
      signal: requestSignal(signal),
    })

    if (!res.ok) {
      throw await responseError(res)
    }

    const data = await res.json().catch(() => ({})) as { queued?: unknown }
    return { ok: true, queued: data.queued === true }
  }

  const replaceWorkspace: ChatClient["replaceWorkspace"] = agentId ? async (workspace, signal) => {
    const health = await fetchImpl(url("/health"), { headers: headers(), signal: requestSignal(signal) })
    if (!health.ok) throw await responseError(health)
    const capabilities = (await health.json() as { capabilities?: unknown }).capabilities
    if (!Array.isArray(capabilities) || !capabilities.includes("session_workspace"))
      throw new Error("daemon upgrade needed to change this workspace; when ready, run albedo daemon --stop, then albedo (this clears python variables)")

    const res = await fetchImpl(agentUrl("/workspace"), {
      method: "POST",
      headers: headers(true),
      body: JSON.stringify({ workspace }),
      signal: requestSignal(signal),
    })
    if (!res.ok) throw await responseError(res)
    const data = await res.json() as { workspace?: unknown }
    if (typeof data.workspace !== "string") throw new Error("daemon returned invalid session metadata")
    return { workspace: data.workspace }
  } : undefined

  const interrupt = async (): Promise<{ interrupted: boolean }> => {
    const res = await fetchImpl(agentUrl(agentId ? "/interrupt" : "/awp/interrupt"), { method: "POST", headers: headers(), signal: AbortSignal.timeout(15_000) })
    if (!res.ok) throw await responseError(res)
    const data = await res.json() as { interrupted?: unknown }
    return { interrupted: data.interrupted === true }
  }

  const getStatus: ChatClient["getStatus"] = async (signal) => {
    const res = await fetchImpl(agentUrl("/status"), { headers: headers(), signal: requestSignal(signal) })
    if (!res.ok) {
      throw await responseError(res)
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
      throw res.ok ? new Error("stream body missing") : await responseError(res)
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
            throw new Error(typeof error?.error === "string" ? error.error : typeof error?.text === "string" ? error.text : `event stream failed: ${JSON.stringify(raw)}`)
          }
          const page = raw as { cursor?: unknown; events?: unknown }
          if (Number.isSafeInteger(page?.cursor) && Array.isArray(page.events)) {
            for (const serialized of page.events) {
              const item = serialized as Record<string, unknown>
              if (["reset", "retry", "turn_started", "message", "interrupted", "error"].includes(String(item.type))) {
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
                const fresh = !argumentsByCall.has(item.callId)
                const retained = [...argumentsByCall].reduce((size, [id, args]) => size + id.length + args.length, 0)
                if ((fresh && argumentsByCall.size >= 32) || retained + item.text.length + (fresh ? item.callId.length : 0) > 2_000_000) {
                  argumentsByCall.clear()
                  afterSeq = -1
                  throw new Error("tool argument previews exceed client limit")
                }
                const args = (argumentsByCall.get(item.callId) ?? "") + item.text
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
      // Reconnects keep bounded unfinished arguments; detaching releases them
      // and starts any future attachment from a fresh snapshot.
      if (signal?.aborted) { argumentsByCall.clear(); afterSeq = -1 }
      signal?.removeEventListener("abort", cancel)
      await reader.cancel().catch(() => {})
      reader.releaseLock()
      report(null, "running")
    }
  }

  return {
    clientId,
    send,
    ...(replaceWorkspace ? { replaceWorkspace } : {}),
    interrupt,
    getStatus,
    stream,
  }
}
