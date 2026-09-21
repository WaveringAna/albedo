import type { Session } from "./daemon.js"

export function assistantAge(timestamp: number | null | undefined, now = Date.now()): string {
  if (timestamp == null || !Number.isFinite(timestamp)) return "time unknown"
  const seconds = Math.max(0, Math.floor(now / 1000 - timestamp))
  if (seconds < 60) return "just now"
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`
  return `${Math.floor(seconds / 86400)}d ago`
}

export function sessionListing(sessions: Session[], now = Date.now()): string {
  return sessions.map(session => {
    const name = session.title?.replace(/[\p{Cc}\u202a-\u202e\u2066-\u2069]/gu, " ").trim() || "session name unavailable"
    return `${name}  [${session.id.slice(0, 8)}]\n  last assistant: ${assistantAge(session.last_assistant_at, now)}`
  }).join("\n\n") || "no sessions"
}
