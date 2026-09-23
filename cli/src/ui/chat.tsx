import { useEffect, useMemo, useRef, useState } from "react"
import { setTimeout as delay } from "node:timers/promises"
import { Box, Text, useApp, useInput, useWindowSize, useStdout, useAnimation, useIsScreenReaderEnabled } from "ink"
import { homedir } from "node:os"
import { createChatClient, WorkspaceMissingError, type AgentStatus, type ChatClient, type StreamEvent } from "../client.js"
import { imageLabel, type ImageAttachment, type ImageMetadata } from "../image.js"
import { advanceCodeLine, type CodeLine } from "./code-line.js"
import { MouseInput, type MouseEvent } from "./mouse.js"
import { copyText } from "./clipboard.js"
import { clipboardHasImage, readClipboardImage } from "./clipboard-image.js"
import { highlightSelection, selectedText, type Point, type Selection } from "./selection.js"
import { TextInput } from "./text-input.js"
import { ChatFooter } from "./footer.js"
import { color, renderToolProgress, progressCodeWidth, type Entry, type DisplayFlags } from "./transcript.js"
import { MarkdownIndex } from "./markdown-index.js"
import { joinRows, type Rows } from "./row-index.js"
import { TranscriptIndex, type TranscriptLayout } from "./transcript-index.js"
import { useCommandMenu, type ChatCommand } from "./commands.js"
import { toneColor } from "./page-view.js"
import type { Glance, PageTone } from "../page.js"

export type ChatScreenProps = {
  baseUrl?: string
  transport?: ChatClient
  visible?: boolean
  usageResetKey?: number
  commands?: ChatCommand[]
  /** Extension page glances, shown in the right margin when it has room. */
  glances?: Glance[]
  onCommand?: (value: string, clear: () => void) => boolean
  onCreate?: () => void
  token?: string
  agentId?: string
  agentName?: string
  workspace?: string
  model?: string
  notice?: string
  errorNotice?: string
  onWorkspaceChanged?: (workspace: string) => void
  copySelection?: (text: string) => Promise<void>
  clipboardImages?: { available: () => boolean; read: () => Promise<ImageAttachment | null> }
  fetchImpl?: typeof fetch
  onBack: () => void
  onQuit: () => void
  settleMs?: number
  reconnectMs?: number
}

type Drag = { rows: Rows; selection: Selection; top: number; column: number; direction: number }

type Active = { kind: "text" | "thinking"; content: MarkdownIndex }
type PendingUser = { text: string; image?: ImageAttachment; queued: boolean }
type WorkspaceRecovery = { missing: string; replacement: string; prompt: string; image?: ImageAttachment; saving: boolean; error?: string }
const SYSTEM_CLIPBOARD_IMAGES = { available: clipboardHasImage, read: readClipboardImage }
const userText = (text: string, image?: ImageMetadata): string => image ? `${text}\n[image · ${imageLabel(image)}]` : text
const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
type Connection = "connecting" | "live" | "disconnected"
const SIDEBAR_GAP = 2
const SIDEBAR_MIN = 16
const SIDEBAR_MAX = 32
const GLANCE_MARK: Record<PageTone, string> = { active: "●", warning: "!", plain: "○", muted: "✓" }

/** A page's glance: its title, then one truncated row per item, most important first. */
function GlancePanel({ glance, width, height }: { glance: Glance; width: number; height: number }) {
  const room = Math.max(0, Math.min(height, 12) - 1)
  const shown = glance.rows.length > room ? glance.rows.slice(0, Math.max(0, room - 1)) : glance.rows
  return <Box flexDirection="column" width={width} flexShrink={0}>
    <Text color="gray" wrap="truncate-end">{glance.title} · {glance.rows.length}</Text>
    {shown.map(row => <Text key={row.id} wrap="truncate-end">
      <Text color={toneColor(row.tone)}>{GLANCE_MARK[row.tone]}</Text> {row.text}
    </Text>)}
    {shown.length < glance.rows.length && <Text color="gray">+{glance.rows.length - shown.length} more</Text>}
  </Box>
}

const formatNumber = (value: number): string => value >= 100 ? value.toFixed(0) : value >= 10 ? value.toFixed(1) : value.toFixed(2)
const message = (error: unknown): string => error instanceof Error ? error.message : String(error)

const formatUsage = (event: Extract<StreamEvent, { type: "usage" }>): string => {
  const parts: string[] = []
  if (typeof event.tokensPerSecond === "number") parts.push(`${formatNumber(event.tokensPerSecond)} tok/s`)
  if (typeof event.completionTokens === "number") parts.push(`${event.completionTokens} out`)
  if (typeof event.promptTokens === "number") parts.push(`${event.promptTokens} ctx`)
  if (typeof event.cachedPromptTokens === "number") parts.push(`${event.cachedPromptTokens} cached`)
  if (typeof event.cacheWriteTokens === "number") parts.push(`${event.cacheWriteTokens} cache write`)
  if (typeof event.totalTokens === "number") parts.push(`${event.totalTokens} total`)
  if (typeof event.elapsedMs === "number") parts.push(`${(event.elapsedMs / 1000).toFixed(1)}s`)
  return parts.length ? parts.join(" \u00b7 ") : "usage unavailable"
}

const awakeness = (status: AgentStatus, speaker: string): string => {
  switch (status.phase) {
    case "reasoning": return `${speaker} is reasoning`
    case "tool": return `${speaker} is using a tool`
    case "compacting": return `${speaker} is compacting context`
    case "preparing": return `${speaker} is preparing a turn`
    case "waiting": return `${speaker} is ready`
    default: return status.running && !status.idle ? `${speaker} is working` : `${speaker} is ready`
  }
}
const describeFailure = (error: unknown, agentId?: string): string => {
  const text = message(error)
  return agentId && /agent not found|^404\b/i.test(text) ? `session ${agentId} is unavailable — start it with \`albedo resume ${agentId}\`` : text
}

export function ChatScreen({
  baseUrl, transport, visible = true, usageResetKey = 0, commands, glances = [], onCommand, onCreate,
  token, agentId, agentName, workspace, model, notice, errorNotice, onWorkspaceChanged, fetchImpl, copySelection,
  clipboardImages = SYSTEM_CLIPBOARD_IMAGES, onBack, onQuit,
  settleMs = 750, reconnectMs = 1_000,
}: ChatScreenProps) {
  const speaker = agentName?.trim() || agentId?.trim() || "agent"
  const [transcript] = useState(() => new TranscriptIndex())
  const [, setRevision] = useState(0)
  const [active, setActive] = useState<Active | null>(null)
  const [toolProgress, setToolProgress] = useState<Extract<StreamEvent, { type: "tool_progress" }>["progress"]>(null)
  const [codeLine, setCodeLine] = useState<CodeLine | null>(null)
  const eventRevision = useRef(0)
  const [draft, setDraft] = useState("")
  const [pendingImage, setPendingImageState] = useState<ImageAttachment>()
  const pendingImageRef = useRef<ImageAttachment | undefined>(undefined)
  const pendingImageRead = useRef<Promise<ImageAttachment | null> | undefined>(undefined)
  const setPendingImage = (image: ImageAttachment | undefined): void => {
    pendingImageRef.current = image
    setPendingImageState(image)
  }
  const [clipboardImageAvailable, setClipboardImageAvailable] = useState(false)
  const [workspaceRecovery, setWorkspaceRecovery] = useState<WorkspaceRecovery>()
  const [status, setStatus] = useState<AgentStatus>()
  const [failure, setFailure] = useState("")
  const [stopping, setStopping] = useState(false)
  const [stopped, setStopped] = useState(false)
  const stopRequested = useRef<"requesting" | "stopping" | null>(null)
  const sending = useRef<Promise<unknown> | null>(null)
  const [usage, setUsage] = useState<Extract<StreamEvent, { type: "usage" }>>()
  useEffect(() => { setUsage(undefined) }, [usageResetKey])
  useEffect(() => {
    if (!visible || pendingImage) { setClipboardImageAvailable(false); return }
    let cancelled = false
    const detect = (): void => {
      let available = false
      try { available = clipboardImages.available() } catch {}
      if (!cancelled) setClipboardImageAvailable(available)
    }
    detect()
    const timer = setInterval(detect, 2_000)
    return () => { cancelled = true; clearInterval(timer) }
  }, [visible, pendingImage, clipboardImages])
  const [connection, setConnection] = useState<Connection>("connecting")
  const [flags, setFlags] = useState<DisplayFlags>({ tools: false, thinking: true, diffs: false, compaction: false })
  const [mouseInput] = useState(() => new MouseInput())
  const drag = useRef<Drag | null>(null)
  const [selecting, setSelecting] = useState(false)
  const [, selectionChanged] = useState(0)
  const [copyStatus, setCopyStatus] = useState("")
  // null follows the tail; a line index holds the viewport still while streaming.
  const [scrollTop, setScrollTop] = useState<number | null>(null)
  const [scrollLayout, setScrollLayout] = useState<TranscriptLayout | null>(null)
  const activeLine = useRef<Active | null>(null)
  const { waitUntilRenderFlush } = useApp()
  const inputPaint = useRef({ pending: false, revision: 0 })
  const streamed = useRef<string[]>([])
  const streamedEntries = useRef<number[]>([])
  const provisionalEntries = useRef<number[]>([])
  const pendingUsers = useRef<PendingUser[]>([])
  const live = useRef(true)
  const requests = useRef<AbortController | undefined>(undefined)
  const clientId = useRef(`cli-${crypto.randomUUID()}`)
  const client = useMemo(() => {
    if (transport || !baseUrl) return transport
    const send = fetchImpl ?? fetch
    const authorized: typeof fetch = token
      ? (input, init) => send(input, { ...init, headers: new Headers({ ...Object.fromEntries(new Headers(init?.headers)), authorization: `Bearer ${token}` }), redirect: "error" })
      : (input, init) => send(input, { ...init, redirect: "error" })
    return createChatClient({ baseUrl, clientId: clientId.current, ...(agentId ? { agentId } : {}), fetchImpl: authorized })
  }, [transport, baseUrl, token, agentId, fetchImpl])

  const push = (...records: Entry[]): number | undefined => {
    if (!live.current) return
    const index = transcript.append(...records)
    setRevision(current => current + 1)
    return index
  }
  const timestampEntries = (indices: number[], timestamp: number | undefined): void => {
    if (timestamp === undefined) return
    for (const index of indices) transcript.timestamp(index, timestamp)
    setRevision(current => current + 1)
  }
  const setActiveLine = (next: Active | null): void => {
    if (!live.current) return
    activeLine.current = next
    setActive(next)
  }
  const settle = (): void => {
    const current = activeLine.current
    if (!current) return
    const index = push({ kind: current.kind === "text" ? "assistant" : "thinking", text: current.content.text() })
    if (index !== undefined) {
      provisionalEntries.current.push(index)
      if (current.kind === "text") streamedEntries.current.push(index)
    }
    setActiveLine(null)
  }
  const failTurn = (error: unknown): void => {
    if (!live.current) return
    settle()
    streamed.current = []
    streamedEntries.current = []
    setToolProgress(null)
    const text = describeFailure(error, agentId)
    setFailure(text)
    setScrollTop(null)
    push({ kind: "error", text })
  }
  const handle = (event: StreamEvent): void => {
    eventRevision.current++
    switch (event.type) {
      case "retry":
        setActiveLine(null)
        for (const index of provisionalEntries.current.reverse()) transcript.discard(index)
        provisionalEntries.current = []
        streamedEntries.current = []
        streamed.current = []
        setToolProgress(null)
        setRevision(current => current + 1)
        return
      case "reset":
        provisionalEntries.current = []
        setUsage(undefined)
        drag.current = null
        setSelecting(false)
        transcript.clear()
        // Pending messages stay visible across a stream snapshot until their user events arrive.
        streamedEntries.current = []
        streamed.current = []
        setActiveLine(null)
        setToolProgress(null)
        setCodeLine(null)
        setScrollTop(null)
        setScrollLayout(null)
        setRevision(current => current + 1)
        return
      case "tool_progress":
        if (event.progress) {
          settle()
          setFailure("")
          setStopped(false)
          setStatus({ running: true, idle: false, phase: "tool" })
        }
        setToolProgress(event.progress)
        return
      case "thinking": case "text": {
        setToolProgress(null)
        setFailure("")
        setStopped(false)
        setStatus({ running: true, idle: false, phase: "reasoning" })
        let current = activeLine.current
        if (current?.kind !== event.type) {
          settle()
          current = { kind: event.type, content: new MarkdownIndex() }
        }
        if (event.type === "text") streamed.current.push(event.text)
        current.content.append(event.text)
        setActiveLine({ ...current })
        return
      }
      case "tool": {
        setToolProgress(null)
        settle()
        return void push({ kind: "tool", name: event.name, args: event.args, result: event.result, ...(event.trace ? { trace: event.trace } : {}) })
      }
      case "user": {
        const pending = event.clientId === (client?.clientId ?? clientId.current)
          ? pendingUsers.current.find(item => item.text === event.text) : undefined
        if (pending) {
          pendingUsers.current = pendingUsers.current.filter(item => item !== pending)
          setRevision(current => current + 1)
        }
        setFailure("")
        setStopped(false)
        settle()
        return void push({ kind: "user", source: event.source === "chat" ? "you" : event.source, text: userText(event.text, event.image), timestamp: event.timestamp })
      }
      case "usage":
        settle()
        return setUsage(event)
      case "interrupted":
        setToolProgress(null)
        settle()
        streamed.current = []
        streamedEntries.current = []
        stopRequested.current = null
        setStopping(false)
        setStopped(true)
        setFailure("")
        setStatus({ running: false, idle: false, phase: "resting" })
        return void push({ kind: "note", text: "stopped by you" })
      case "error": return failTurn(event.text)
      case "note": {
        settle()
        return void push({ kind: "note", text: event.text })
      }
      case "compacted": {
        setToolProgress(null)
        setFailure("")
        settle()
        return void push({ kind: "compaction", text: event.summary, evicted: event.evicted })
      }
      case "message": {
        setToolProgress(null)
        setFailure("")
        settle()
        const duplicate = event.text === streamed.current.join("")
        streamed.current = []
        if (duplicate) timestampEntries(streamedEntries.current, event.timestamp)
        else push({ kind: "assistant", text: event.text, timestamp: event.timestamp })
        streamedEntries.current = []
        provisionalEntries.current = []
        return
      }
    }
  }

  useEffect(() => {
    live.current = true
    if (!client) return
    const controller = new AbortController()
    requests.current = controller
    let reported = ""
    const disconnected = (error: unknown): void => {
      if (controller.signal.aborted) return
      settle()
      const text = describeFailure(error, agentId)
      setToolProgress(null)
      setConnection("disconnected")
      if (text !== reported) push({ kind: "error", text })
      reported = text
    }
    // The stream is long-lived. EOF is a disconnection, not successful completion.
    void (async () => {
      while (!controller.signal.aborted) {
        try {
          await client.stream({ signal: controller.signal,
            onOpen: () => { if (!controller.signal.aborted) setConnection("live") },
            onEvent: (event) => { if (!controller.signal.aborted) { setConnection("live"); reported = ""; handle(event) } },
          })
          disconnected(new Error("event stream closed"))
        } catch (error) { disconnected(error) }
        await delay(reconnectMs, undefined, { signal: controller.signal }).catch(() => {})
      }
    })()
    void (async () => {
      while (!controller.signal.aborted) {
        try {
          const revision = eventRevision.current
          const next = await client.getStatus(controller.signal)
          if (controller.signal.aborted) return
          // A response requested before a stream update cannot erase newer activity.
          if (revision !== eventRevision.current) {
            await delay(settleMs, undefined, { signal: controller.signal }).catch(() => {})
            continue
          }
          setStatus(next)
          if (!next.running || next.idle) {
            setToolProgress(null)
            settle()
            if (stopRequested.current === "stopping" && !next.running) {
              stopRequested.current = null
              setStopping(false)
              setStopped(true)
            }
          }
        } catch (error) { disconnected(error) }
        await delay(settleMs, undefined, { signal: controller.signal }).catch(() => {})
      }
    })()
    return () => { live.current = false; controller.abort() }
  }, [client, agentId, settleMs, reconnectMs])

  const sendTurn = (value: string, image = pendingImageRef.current): void => {
    const trimmed = value.trim()
    if (!client || !trimmed) return
    setDraft(current => current === value ? "" : current)
    setPendingImage(undefined)
    const pending: PendingUser = { text: trimmed, image, queued: Boolean(status?.running && !status.idle || sending.current) }
    pendingUsers.current.push(pending)
    setRevision(current => current + 1)
    if (!pending.queued) {
      setScrollTop(null)
      setFailure("")
      setStopped(false)
      setUsage(undefined)
      setStatus({ running: true, idle: false, phase: "preparing" })
    }
    const sent = client.send(trimmed, requests.current?.signal, image)
    sending.current = sent
    void sent.then(result => {
      if (!live.current || !pendingUsers.current.includes(pending)) return
      pending.queued = result.queued === true
      setRevision(current => current + 1)
    }).catch((error) => {
      if (!live.current) return
      pendingUsers.current = pendingUsers.current.filter(item => item !== pending)
      setRevision(current => current + 1)
      if (image && !pendingImageRef.current) setPendingImage(image)
      if (pending.queued) {
        push({ kind: "error", text: `message not queued: ${message(error)}` })
        setDraft(current => current || value)
        return
      }
      if (error instanceof WorkspaceMissingError) {
        setStatus({ running: false, idle: true, phase: "resting" })
        setDraft(current => current || value)
        setWorkspaceRecovery({ missing: error.workspace, replacement: error.workspace, prompt: value, ...(image ? { image } : {}), saving: false })
        return
      }
      failTurn(error)
      if (live.current) setDraft((current) => current || value)
    }).finally(() => { if (sending.current === sent) sending.current = null })
  }

  const submit = (value: string): void => {
    const trimmed = value.trim()
    if (onCommand?.(trimmed, () => setDraft(""))) return
    if (!trimmed) return
    if (trimmed === "/a" || trimmed === "/agents") { setDraft(""); return onBack() }
    if (trimmed === "/q" || trimmed === "/quit" || trimmed === "/exit") return onQuit()
    if (trimmed === "/status") {
      setDraft("")
      void client?.getStatus(requests.current?.signal).then((status) => push({ kind: "note", text: `${awakeness(status, speaker)}${workspace ? `\nworkspace: ${workspace}` : ""}${model ? `\nmodel: ${model}` : ""}${usage ? `\n${formatUsage(usage)}` : ""}` })).catch(failTurn)
      return
    }
    if (["/v", "/verbose", "/t", "/thinking"].includes(trimmed)) {
      setDraft("")
      const key = trimmed === "/v" || trimmed === "/verbose" ? "tools" : "thinking"
      setFlags((current) => ({ ...current, [key]: !current[key] }))
      return
    }
    if (trimmed === "/mouse") {
      setDraft("")
      setCopyStatus("wheel scrolling and drag-to-copy are always on")
      return
    }
    const reading = pendingImageRead.current
    if (reading) {
      setDraft("")
      void reading.catch(() => null).then(() => {
        if (live.current) sendTurn(value)
      })
      return
    }
    sendTurn(value)
  }

  const replaceWorkspace = (replacement: string): void => {
    const next = replacement.trim()
    const recovery = workspaceRecovery
    if (!recovery || recovery.saving || !next) return
    if (!client?.replaceWorkspace) {
      setWorkspaceRecovery({ ...recovery, error: "this connection cannot change a session workspace" })
      return
    }
    setWorkspaceRecovery({ ...recovery, replacement, saving: true, error: undefined })
    void client.replaceWorkspace(next, requests.current?.signal).then(updated => {
      if (!live.current) return
      onWorkspaceChanged?.(updated.workspace)
      setWorkspaceRecovery(undefined)
      sendTurn(recovery.prompt, recovery.image)
    }).catch(error => {
      if (live.current) setWorkspaceRecovery({ ...recovery, replacement, saving: false, error: message(error) })
    })
  }

  const pasteClipboardImage = (): void => {
    if (pendingImageRead.current) return
    setCopyStatus("reading clipboard image…")
    const reading = clipboardImages.read()
    pendingImageRead.current = reading
    void reading.then(image => {
      if (!live.current) return
      if (!image) { setClipboardImageAvailable(false); setCopyStatus("clipboard has no supported image"); return }
      setPendingImage(image)
      setClipboardImageAvailable(false)
      setCopyStatus("")
    }).catch(error => {
      if (live.current) setCopyStatus(`image paste failed: ${message(error)}`)
    }).finally(() => {
      if (pendingImageRead.current === reading) pendingImageRead.current = undefined
    })
  }

  const stop = (): void => {
    if ((!status?.running && !sending.current) || stopRequested.current || !client) return
    if (!client.interrupt) { push({ kind: "error", text: "this connection does not support stopping a turn" }); return }
    stopRequested.current = "requesting"
    setStopping(true)
    void (async () => {
      // A prompt echoed locally may still be on its way to the worker.
      await sending.current
      const result = await client.interrupt!()
      if (!live.current || !stopRequested.current) return
      stopRequested.current = result.interrupted ? "stopping" : null
      if (!result.interrupted) setStopping(false)
    })().catch((error) => {
      stopRequested.current = null
      if (!live.current) return
      setStopping(false)
      push({ kind: "error", text: `could not stop turn: ${message(error)}` })
    })
  }

  const menu = useCommandMenu(draft, submit, commands)
  const { stdout } = useStdout()
  useEffect(() => {
    if (!visible || !stdout.isTTY) return
    stdout.write("\x1b[?1002h\x1b[?1006h")
    return () => { stdout.write("\x1b[?1006l\x1b[?1002l\x1b[?1000l") }
  }, [stdout, visible])
  const { columns, rows } = useWindowSize()
  const width = Math.max(1, columns)
  const height = Math.max(1, rows)
  const padding = width >= 50 ? 2 : 1
  const viewportWidth = Math.max(1, width - padding * 2)
  const contentWidth = Math.min(100, viewportWidth)
  // A glance lives only in the margin beside the capped body text: message text
  // never reflows for it, and headings end at its left edge so their clocks sit
  // beside it. Without room it collapses to a count in the header.
  const glance = glances.find(item => item.rows.length)
  const margin = viewportWidth - contentWidth - SIDEBAR_GAP
  const sidebarWidth = glance && margin >= SIDEBAR_MIN ? Math.min(SIDEBAR_MAX, margin) : 0
  const transcriptWidth = sidebarWidth ? viewportWidth - sidebarWidth - SIDEBAR_GAP : viewportWidth
  const screenReader = useIsScreenReaderEnabled()
  const busy = connection !== "disconnected" && !failure && Boolean(stopping || toolProgress || (status?.running && !status.idle && status.phase !== "waiting"))
  const { frame } = useAnimation({ interval: 80, isActive: visible && busy && !screenReader })
  const spinner = busy && !screenReader ? SPINNER[frame % SPINNER.length]! : ""
  const nextCodeLine = advanceCodeLine(codeLine, toolProgress, screenReader ? 0 : progressCodeWidth(toolProgress, contentWidth))
  // Adjust on a new sample/width before painting; animation ticks don't consume code again.
  if (nextCodeLine !== codeLine) setCodeLine(nextCodeLine)
  // Chrome owns six rows. Recovery replaces the composer and borrows two more.
  const recoveryRows = workspaceRecovery ? 2 : 0
  const pending = pendingUsers.current
  const pendingRows = Math.min(3, pending.length, Math.max(0, height - 7 - recoveryRows - (notice || errorNotice ? 1 : 0)))
  const menuRows = Math.min(menu.rows, Math.max(0, height - 9 - recoveryRows - pendingRows))
  const transcriptRows = Math.max(1, height - 6 - recoveryRows - pendingRows - (notice || errorNotice ? 1 : 0) - menuRows)
  const history = transcript.layout(flags, speaker, contentWidth, transcriptWidth)
  // Resizing or expanding changes row counts above the viewport, not the record
  // being read. Tail appends keep the same layout and never move a history anchor.
  if (scrollLayout !== history) {
    setScrollLayout(history)
    if (scrollLayout && scrollTop !== null) setScrollTop(history.rowAt(scrollLayout.anchorAt(scrollTop)))
  }
  const activeRows = useMemo(() => {
    if (!active) return []
    const thinking = active.kind === "thinking"
    const body = thinking && !flags.thinking ? [color(90, "hidden · /t show")] : active.content.layout(contentWidth)
    return joinRows([
      history.length ? [""] : [],
      [color(thinking ? 90 : 1, thinking ? "thinking" : speaker)],
      thinking ? { length: body.length, slice: (start, end) => body.slice(start, end).map(line => color(90, line)) } : body,
    ])
  }, [history.length, active, flags.thinking, speaker, contentWidth])
  const progressRows = toolProgress ? [
    ...(history.length || active ? [""] : []), renderToolProgress(toolProgress, contentWidth, spinner, nextCodeLine?.line),
  ] : []
  const liveRows = joinRows([history, activeRows, progressRows])
  const displayRows = drag.current?.rows ?? liveRows
  const lineCount = displayRows.length
  const tail = Math.max(0, lineCount - transcriptRows)
  const top = drag.current?.top ?? (scrollTop === null ? tail : Math.min(scrollTop, tail))
  const inHistory = top < tail
  const statusText = connection === "disconnected" ? "disconnected · reconnecting"
    : stopping ? "stopping…"
      : failure ? "turn failed · see error above"
      : toolProgress ? toolProgress.phase === "generating" ? "generating call" : `running ${toolProgress.name}`
      : !status ? client ? "connecting…" : "opening session…"
        : !status.running || status.idle ? stopped ? "stopped" : "ready"
          : active?.kind === "text" ? "responding"
            : ({ reasoning: "thinking", tool: "running tool", preparing: "preparing", compacting: "compacting context", waiting: "ready", resting: "ready" }[status.phase ?? "reasoning"])
  const imageStatus = pendingImage ? `${imageLabel(pendingImage)} attached · esc remove`
    : clipboardImageAvailable ? "ctrl+v to paste image" : statusText
  const stats = usage ? [
    typeof usage.elapsedMs === "number" ? `${(usage.elapsedMs / 1000).toFixed(1)}s` : "",
    typeof usage.tokensPerSecond === "number" ? `${formatNumber(usage.tokensPerSecond)} tok/s` : "",
  ].filter(Boolean).join(" · ") : ""
  const directory = workspace?.startsWith(`${homedir()}/`) ? `~/${workspace.slice(homedir().length + 1)}` : workspace
  // Human scroll intent needn't wait behind the model's frame deadline. Coalesce
  // bursts, and drain input arriving during an in-flight flush before releasing it.
  const paintInput = (): void => {
    const paint = inputPaint.current
    paint.revision++
    if (paint.pending) return
    paint.pending = true
    void (async () => {
      let revision: number
      do {
        revision = paint.revision
        await waitUntilRenderFlush()
      } while (live.current && paint.revision !== revision)
    })().catch(failTurn).finally(() => { paint.pending = false })
  }
  const redrawSelection = (): void => { selectionChanged(revision => revision + 1); paintInput() }
  const scroll = (delta: number): void => {
    setCopyStatus("")
    const current = drag.current
    if (current) {
      current.top = Math.max(0, Math.min(current.top + delta, Math.max(0, current.rows.length - transcriptRows)))
      setScrollTop(current.top)
      redrawSelection()
    } else {
      setScrollTop(current => {
        const next = Math.max(0, Math.min(current ?? tail, tail) + delta)
        return next >= tail ? null : next
      })
      paintInput()
    }
  }
  const firstRow = 2 + (notice ? 1 : 0)
  const pointAt = (event: MouseEvent, position: number): Point => ({
    row: position + Math.max(0, Math.min(event.y - 1 - firstRow, transcriptRows - 1)),
    column: Math.max(0, Math.min(event.x - 1 - padding, transcriptWidth)),
  })
  const handleMouse = (event: MouseEvent): void => {
    if (event.press && (event.button === 64 || event.button === 65)) {
      scroll(event.button === 64 ? -3 : 3)
      if (drag.current) { drag.current.selection.head = pointAt(event, drag.current.top); drag.current.direction = 0 }
      return
    }
    if (event.button !== 0) return
    if (event.press && !event.motion) {
      setCopyStatus("")
      if (event.y - 1 < firstRow || event.y - 1 >= firstRow + transcriptRows) return
      // Keep selected text stable even when a message's timestamp is confirmed.
      const rows = joinRows([history.snapshot(), activeRows.slice(0, activeRows.length), progressRows])
      const point = pointAt(event, top)
      drag.current = { rows, selection: { anchor: point, head: point }, top, column: point.column, direction: 0 }
      setSelecting(true)
      setScrollTop(top)
      redrawSelection()
    } else if (drag.current && event.press && event.motion) {
      const current = drag.current
      current.selection.head = pointAt(event, current.top)
      current.column = current.selection.head.column
      current.direction = event.y - 1 <= firstRow && current.selection.head.row < current.selection.anchor.row ? -1
        : event.y - 1 >= firstRow + transcriptRows - 1 && current.selection.head.row > current.selection.anchor.row ? 1 : 0
      redrawSelection()
    } else if (drag.current && !event.press) {
      const current = drag.current
      current.selection.head = pointAt(event, current.top)
      const text = selectedText(current.rows, current.selection)
      drag.current = null
      setSelecting(false)
      redrawSelection()
      if (text) void (copySelection ? copySelection(text) : copyText(text, data => { stdout.write(data) }))
        .then(() => { if (live.current) setCopyStatus("copied") })
        .catch(error => { if (live.current) setCopyStatus(`copy failed: ${message(error)}`) })
    }
  }
  useEffect(() => {
    drag.current = null
    setSelecting(false)
  }, [width, height, visible])
  useEffect(() => {
    if (!copyStatus) return
    const timer = setTimeout(() => setCopyStatus(""), 3000)
    return () => clearTimeout(timer)
  }, [copyStatus])
  useEffect(() => {
    if (!selecting) return
    const timer = setInterval(() => {
      const current = drag.current
      if (!current?.direction) return
      scroll(current.direction)
      current.selection.head = { row: current.top + (current.direction < 0 ? 0 : transcriptRows - 1), column: current.column }
    }, 60)
    return () => clearInterval(timer)
  }, [selecting, transcriptRows])
  useInput((input, key) => {
    if (key.ctrl && input === "n") onCreate?.()
    if (key.ctrl && input === "c") onQuit()
  }, { isActive: visible })

  if (!visible) return null
  return <Box flexDirection="column" height={height} width={width} paddingX={padding}>
    <Box height={1} flexShrink={0} gap={2}>
      <Box flexShrink={0}><Text bold>{speaker}</Text></Box>
      <Box flexGrow={1} flexShrink={1}><Text color="gray" wrap="truncate-middle">{directory ?? "chat"}</Text></Box>
      {glance && !sidebarWidth && <Box flexShrink={0}><Text color="gray">{glance.title} {glance.rows.length}</Text></Box>}
      {model && <Box maxWidth={Math.floor(contentWidth / 2)} flexShrink={0}><Text color="gray" wrap="truncate-start">{model}</Text></Box>}
    </Box>
    <Text> </Text>
    {errorNotice
      ? <Text color="redBright" wrap="truncate-end">error: {errorNotice}</Text>
      : notice && <Text color="cyanBright" wrap="truncate-end">{notice}</Text>}
    <Box height={transcriptRows} flexShrink={0} gap={SIDEBAR_GAP}>
      <Box flexDirection="column" height={transcriptRows} width={transcriptWidth} overflow="hidden" flexShrink={0}>
        <Text>{lineCount ? highlightSelection(displayRows.slice(top, top + transcriptRows), top, drag.current?.selection ?? { anchor: { row: 0, column: 0 }, head: { row: 0, column: 0 } }).join("\n") : color(90, "what are we working on?")}</Text>
      </Box>
      {glance && sidebarWidth > 0 && <GlancePanel glance={glance} width={sidebarWidth} height={transcriptRows} />}
    </Box>
    {pending.slice(0, pendingRows < 3 ? pendingRows : 2).map((item, index) => <Text key={index} color="yellow" wrap="truncate-end">{item.queued ? `queued ${index + 1}` : "sending"} · {userText(item.text, item.image).replace(/\s+/g, " ")}</Text>)}
    {pendingRows === 3 && pending.length > 2 && <Text color="yellow" wrap="truncate-end">+{pending.length - 2} more pending</Text>}
    <Box height={1} flexShrink={0} justifyContent="space-between">
      <Text color={connection === "disconnected" || failure ? "redBright" : "gray"} wrap="truncate-end">
        {spinner && (!toolProgress || inHistory) ? `${spinner} ` : ""}{copyStatus || (inHistory ? `history · ${tail - top} rows below · pgdn` : pendingRows === 0 && pending.length ? `${pending.length} pending · ${imageStatus}` : imageStatus)}
      </Text>
      {!inHistory && !failure && width >= 60 && <Text color="gray">{stats}</Text>}
    </Box>
    <Text color="gray">{"─".repeat(Math.max(1, width - padding * 2))}</Text>
    {workspaceRecovery ? <>
      <Text color="yellow" wrap="truncate-middle">workspace not found: {workspaceRecovery.missing}</Text>
      <Box height={1} flexShrink={0}>
        <Text color="cyanBright">new workspace › </Text>
        <TextInput isActive={visible && !workspaceRecovery.saving} value={workspaceRecovery.replacement}
          onChange={replacement => setWorkspaceRecovery(current => current && { ...current, replacement, error: undefined })}
          onSubmit={replaceWorkspace} onKey={(input, key) => {
            // The composer is unmounted here but mouse reporting is not, and a
            // wheel or drag report would otherwise land in the path.
            if (mouseInput.read(input) !== null) return true
            if (!key.escape) return false
            setWorkspaceRecovery(undefined)
            return true
          }} width={Math.max(1, width - padding * 2 - 16)} />
      </Box>
      <Text color={workspaceRecovery.error ? "redBright" : "gray"} wrap="truncate-end">
        {workspaceRecovery.error ?? (workspaceRecovery.saving ? "updating workspace…" : "enter confirms and retries · esc cancels")}
      </Text>
    </> : <>
      <Box height={1} flexShrink={0}>
        <Text color="cyanBright">› </Text>
        <TextInput multiline isActive={visible} value={draft} onChange={setDraft} onSubmit={submit}
          onLeftWhenEmpty={onBack} onKey={(input, key, replace) => {
            const events = mouseInput.read(input)
            if (events !== null) { for (const event of events) handleMouse(event); return true }
            if (key.escape && drag.current) { drag.current = null; setSelecting(false); redrawSelection(); return true }
            if (key.ctrl && input === "v") {
              let available = false
              try { available = clipboardImages.available() } catch {}
              if (!available) { setClipboardImageAvailable(false); return false }
              pasteClipboardImage()
              return true
            }
            if (menu.onKey(input, key, replace)) return true
            // In legacy terminals Ctrl+J is LF, while Return is CR. Kitty reports Ctrl+J explicitly.
            if (input === "\n" || (key.ctrl && input === "j")) {
              setFlags(current => ({ ...current, diffs: !current.diffs }))
              return true
            }
            if (key.ctrl && input === "k") {
              setFlags(current => ({ ...current, compaction: !current.compaction }))
              return true
            }
            if (key.escape && pendingImage) { setPendingImage(undefined); setCopyStatus("image removed"); return true }
            if (key.upArrow || key.downArrow) { scroll(key.upArrow ? -1 : 1); return true }
            if (key.pageUp || key.pageDown) { scroll(key.pageUp ? -transcriptRows : transcriptRows); return true }
            if (key.ctrl && key.home) { setScrollTop(0); paintInput(); return true }
            if (key.ctrl && key.end) { setScrollTop(null); paintInput(); return true }
            if (key.escape) { stop(); return true }
            return false
          }} width={Math.max(1, width - padding * 2 - 2)} />
      </Box>
      {menuRows > 0 && <Box height={menuRows} overflow="hidden" flexShrink={0}>{menu.view}</Box>}
    </>}
    <ChatFooter width={viewportWidth} usage={usage} model={model} flags={flags} />
  </Box>
}
