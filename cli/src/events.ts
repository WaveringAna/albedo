import type { ImageMetadata } from "./image.js"

/** Display-only execution evidence, never appended to the model's tool output. */
export type ToolActivity = { kind: "read" | "search" | "list" | "run"; target: string; failed?: boolean }
export type FileChange =
  | { path: string; kind: "diff"; diff: string; added: number; removed: number }
  | { path: string; kind: "unavailable"; reason: string }
export type ToolTrace = { activities: ToolActivity[]; changes: FileChange[]; truncated?: boolean }

export function parseToolTrace(value: unknown): ToolTrace | undefined {
  if (!value || typeof value !== "object") return
  const trace = value as ToolTrace
  if (!Array.isArray(trace.activities) || !Array.isArray(trace.changes)
    || trace.activities.length > 64 || trace.changes.length > 16) return
  const text = (value: unknown, limit: number): value is string => typeof value === "string" && value.length <= limit
  if (!trace.activities.every(item => item && ["read", "search", "list", "run"].includes(item.kind)
    && text(item.target, 1_000) && (item.failed === undefined || typeof item.failed === "boolean"))) return
  if (!trace.changes.every(item => item && text(item.path, 1_000) && (item.kind === "unavailable"
    ? text(item.reason, 1_000)
    : item.kind === "diff" && text(item.diff, 16_000) && Number.isSafeInteger(item.added) && item.added >= 0
      && Number.isSafeInteger(item.removed) && item.removed >= 0))) return
  if (trace.truncated !== undefined && typeof trace.truncated !== "boolean") return
  return trace
}

/** Inferred intent, not evidence of execution. Completed changes come from ToolTrace. */
export type ToolIntent = { kind: "write" | "edit" | "read" | "run"; target: string }
export type ToolProgress = {
  callId: string
  name: string
  phase: "generating" | "running"
  intent?: ToolIntent
  /** Decoded Python tail; offset is its UTF-16 position in the full code. Live only. */
  code?: { offset: number; text: string }
}

export type StreamEvent =
  | { type: "reset" }
  | { type: "retry" }
  | { type: "text"; text: string }
  /** A turn that failed: the runner aborted and the agent said nothing. */
  | { type: "error"; text: string }
  | { type: "interrupted" }
  /**
   * A settled reply from the agent's own log. Live turns also arrive as `text`
   * chunks; replayed history has only this, because chunks are not persisted.
   */
  | { type: "message"; role: "assistant"; text: string; timestamp?: number }
  | { type: "user"; text: string; source: string; triggeredAt: string; clientId?: string; timestamp?: number; image?: ImageMetadata }
  | { type: "thinking"; text: string }
  /** Something the daemon did on its own, such as releasing an idle kernel. */
  | { type: "note"; text: string }
  | { type: "tool_progress"; progress: ToolProgress | null }
  | { type: "tool"; name: string; args: Record<string, unknown>; result: string; trace?: ToolTrace }
  | {
      type: "usage"
      model?: string
      /** Provider completion time in Unix epoch milliseconds, stable across replay. */
      recordedAt?: number
      promptTokens?: number
      cachedPromptTokens?: number
      cacheWriteTokens?: number
      completionTokens?: number
      totalTokens?: number
      elapsedMs?: number
      tokensPerSecond?: number
    }

