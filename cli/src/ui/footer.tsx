import { Text } from "ink"
import type { StreamEvent } from "../events.js"
import type { DisplayFlags } from "./transcript.js"

type Usage = Extract<StreamEvent, { type: "usage" }>
const count = (value: number | undefined): number | undefined => value !== undefined && Number.isFinite(value) && value >= 0 ? value : undefined
const tokens = (value: number | undefined): string => value === undefined ? "—" : value >= 1_000_000 ? `${+(value / 1_000_000).toFixed(1)}m` : value >= 1000 ? `${+(value / 1000).toFixed(1)}k` : `${Math.floor(value)}`

function currentUsage(usage: Usage | undefined, model: string | undefined): Usage | undefined {
  return model && usage?.model && model !== usage.model ? undefined : usage
}

export function footerLine(width: number, usage?: Usage, model?: string, flags: DisplayFlags = { thinking: true, tools: false }): string {
  const current = currentUsage(usage, model)
  const prompt = count(current?.promptTokens)
  const completion = count(current?.completionTokens)
  const context = tokens(count(current?.totalTokens) ?? (prompt === undefined ? undefined : prompt + (completion ?? 0)))
  const cached = count(current?.cachedPromptTokens)
  // Provider-reported counts for the last completion, not a cache lifetime or hit rate.
  const cache = `${cached === undefined ? "—" : cached.toLocaleString("en-US")}/${prompt === undefined ? "—" : prompt.toLocaleString("en-US")}`
  const right = `ctx ${context} · cached ${cache}`
  const compact = `${context} · ${cache}`
  const columns = Math.max(0, Math.floor(width))
  const modes = `thinking ${flags.thinking ? "on" : "off"} · verbose ${flags.tools ? "on" : "off"}`
  const brief = `t:${flags.thinking ? "on" : "off"} v:${flags.tools ? "on" : "off"}`
  for (const [left, stats] of [[`/ commands · drag to copy · ctrl+j diffs · ${modes}`, right], [`/ commands · drag to copy · ${modes}`, compact], [`/ commands · ctrl+j diffs · ${brief}`, compact], [`/ commands · drag copy · ${brief}`, compact], [`/ commands · ${brief}`, compact], ["/", compact]] as const) {
    if (left.length + stats.length < columns) return left + " ".repeat(columns - left.length - stats.length) + stats
  }
  return "/ commands".slice(0, columns)
}

export function ChatFooter({ width, usage, model, flags }: { width: number; usage?: Usage; model?: string; flags: DisplayFlags }) {
  return <Text color="gray" wrap="truncate-end">{footerLine(width, usage, model, flags)}</Text>
}
