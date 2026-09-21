import { useEffect, useState } from "react"
import { Text } from "ink"
import type { StreamEvent } from "../events.js"
import type { DisplayFlags } from "./transcript.js"

type Usage = Extract<StreamEvent, { type: "usage" }>
const count = (value: number | undefined): number | undefined => value !== undefined && Number.isFinite(value) && value >= 0 ? value : undefined
const tokens = (value: number | undefined): string => value === undefined ? "—" : value >= 1_000_000 ? `${+(value / 1_000_000).toFixed(1)}m` : value >= 1000 ? `${+(value / 1000).toFixed(1)}k` : `${Math.floor(value)}`

// Model-family estimates, not expiry guarantees; compatible proxies may differ.
function cacheLifetime(model: string): number | undefined {
  const name = model.toLowerCase().split("/").at(-1) ?? ""
  if (name.startsWith("deepseek-")) return 43_200_000
  if (/^(claude-|gemini-)/.test(name)) return 300_000
  if (/^(gpt-|chatgpt-|o[134](?:-|$)|glm-|mistral-|codestral-)/.test(name)) return 1_800_000
  return undefined
}

function currentUsage(usage: Usage | undefined, model: string | undefined): Usage | undefined {
  return model && usage?.model && model !== usage.model ? undefined : usage
}

export function cacheExpiry(usage: Usage | undefined, model?: string): number | undefined {
  const current = currentUsage(usage, model)
  const ttl = cacheLifetime(model ?? current?.model ?? "")
  const cached = count(current?.cachedPromptTokens)
  const recordedAt = count(current?.recordedAt)
  return ttl !== undefined && recordedAt !== undefined && cached !== undefined && cached > 0 ? recordedAt + ttl : undefined
}

export function footerLine(width: number, usage?: Usage, model?: string, now = Date.now(), flags: DisplayFlags = { thinking: true, tools: false }): string {
  const current = currentUsage(usage, model)
  const prompt = count(current?.promptTokens)
  const completion = count(current?.completionTokens)
  const context = tokens(count(current?.totalTokens) ?? (prompt === undefined ? undefined : prompt + (completion ?? 0)))
  const cached = count(current?.cachedPromptTokens)
  const percent = prompt !== undefined && prompt > 0 && cached !== undefined && cached <= prompt ? `${Math.round(cached / prompt * 100)}%` : "—"
  const expiry = cacheExpiry(current, model)
  const seconds = expiry === undefined ? undefined : Math.max(0, Math.floor((expiry - now) / 1000))
  const ttl = seconds === undefined ? "—" : seconds === 0 ? "expired" : `~${seconds >= 3600 ? `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m` : seconds >= 60 ? `${Math.floor(seconds / 60)}m ${seconds % 60}s` : `${seconds}s`}`
  const right = `ctx ${context} · cached ${percent} · ttl ${ttl}`
  const compact = `${context} · ${percent} · ${ttl}`
  const columns = Math.max(0, Math.floor(width))
  const modes = `thinking ${flags.thinking ? "on" : "off"} · verbose ${flags.tools ? "on" : "off"}`
  const brief = `t:${flags.thinking ? "on" : "off"} v:${flags.tools ? "on" : "off"}`
  for (const [left, stats] of [[`/ commands · drag to copy · ${modes}`, right], [`/ commands · drag to copy · ${modes}`, compact], [`/ commands · drag copy · ${brief}`, compact], [`/ commands · ${brief}`, compact], ["/", compact]] as const) {
    if (left.length + stats.length < columns) return left + " ".repeat(columns - left.length - stats.length) + stats
  }
  return "/ commands".slice(0, columns)
}

export function ChatFooter({ width, usage, model, flags }: { width: number; usage?: Usage; model?: string; flags: DisplayFlags }) {
  const [, tick] = useState(0)
  const expiry = cacheExpiry(usage, model)
  useEffect(() => {
    if (expiry === undefined || expiry <= Date.now()) return
    const timer = setInterval(() => {
      tick(value => value + 1)
      if (Date.now() >= expiry) clearInterval(timer)
    }, 1000)
    return () => clearInterval(timer)
  }, [expiry])
  return <Text color="gray" wrap="truncate-end">{footerLine(width, usage, model, Date.now(), flags)}</Text>
}
