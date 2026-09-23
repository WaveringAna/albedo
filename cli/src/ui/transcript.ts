import stringWidth from "string-width"
import type { ToolProgress } from "../client.js"
import wrapAnsi from "wrap-ansi"
import type { StreamEvent } from "../client.js"
import { renderMarkdownAnsi } from "./markdown.js"
import { renderDiff } from "./diff.js"

export type Entry =
  | { kind: "assistant"; text: string; timestamp?: number }
  | { kind: "thinking" | "note" | "error"; text: string }
  | { kind: "compaction"; text: string; evicted: number }
  | { kind: "user"; source: string; text: string; timestamp?: number }
  | ({ kind: "tool" } & Pick<Extract<StreamEvent, { type: "tool" }>, "name" | "args" | "result" | "trace">)
export type DisplayFlags = { tools: boolean; thinking: boolean; diffs?: boolean; compaction?: boolean }
export const color = (code: number, text: string): string => `\x1b[${code}m${text}\x1b[0m`
export const wrap = (text: string, width: number): string[] => wrapAnsi(text, Math.max(1, width), { hard: true, trim: false }).split("\n")
const count = (n: number, unit: string): string => `${n} ${unit}${n === 1 ? "" : "s"}`

function preview(rows: string[], limit: number, width: number, tail = false): string[] {
  if (rows.length <= limit) return rows
  const hint = wrap(color(90, `… ${count(rows.length - limit, "row")} hidden · /v expand`), width)
  // Detached strings keep three preview rows from pinning an entire wrapped result.
  const visible = (tail ? rows.slice(-limit) : rows.slice(0, limit))
    .map(row => Buffer.from(row, "utf16le").toString("utf16le"))
  return tail ? [...hint, ...visible] : [...visible, ...hint]
}

function toolSummary(name: string, args: Record<string, unknown>): string {
  switch (name) {
    case "python": return `python · ${count(String(args.code ?? "").split("\n").length, "line")}`
    case "shell": return `$ ${String(args.command ?? "")}`
    case "read_file": return `read ${String(args.path ?? "")}`
    case "write_file": return `write ${String(args.path ?? "")}`
    case "edit_file": return `edit ${String(args.path ?? "")}`
    default: return name
  }
}

export function messageHeading(label: string, tone: number, width: number, timestamp?: number): string {
  const date = timestamp === undefined ? undefined : new Date(timestamp)
  const time = date && Number.isFinite(date.valueOf())
    ? [date.getHours(), date.getMinutes(), date.getSeconds()].map(value => String(value).padStart(2, "0")).join(":") : ""
  const columns = Math.max(0, Math.floor(width))
  const clock = time && columns >= time.length + 3 ? time : ""
  const name = truncate(label.replace(/[\p{Cc}\u202a-\u202e\u2066-\u2069]/gu, " "), columns - (clock ? clock.length + 1 : 0))
  return color(tone, name) + (clock ? " ".repeat(columns - stringWidth(name) - clock.length) + color(90, clock) : "")
}

export function renderEntry(entry: Entry, flags: DisplayFlags, speaker: string, width: number, headingWidth = width): string[] {
  const markdown = (text: string): string[] => wrap(renderMarkdownAnsi(text, width), width)
  switch (entry.kind) {
    case "assistant": return [messageHeading(speaker, 1, headingWidth, entry.timestamp), ...markdown(entry.text)]
    case "user": return [messageHeading(entry.source, 96, headingWidth, entry.timestamp), ...markdown(entry.text)]
    case "thinking": return [color(90, "thinking"), ...(flags.thinking
      ? markdown(entry.text).map(line => color(90, line)) : [color(90, "hidden · /t show")])]
    case "note": return wrap(color(90, entry.text), width)
    case "compaction": return [
      ...wrap(color(90, `compaction done · ${entry.evicted} items summarized · ctrl+k ${flags.compaction ? "hide" : "view"} summary`), width),
      ...(flags.compaction ? markdown(entry.text).map(line => color(90, line)) : []),
    ]
    case "error": return wrap(color(91, `error: ${entry.text}`), width)
    case "tool": {
      const failed = /(?:^|\n)(?:error:|cancelled:|traceback \(most recent call last\):)/i.test(entry.result)
      const trace = entry.trace
      const rows: string[] = []
      const hasTrace = trace && (trace.activities.length > 0 || trace.changes.length > 0)
      if (!hasTrace || flags.tools || failed) rows.push(...wrap(color(failed ? 91 : 90,
        `${toolSummary(entry.name, entry.args)}${failed ? " · failed" : ""}`), width))
      if (hasTrace && !flags.tools && !failed) {
        const edited = new Set(trace.changes.map(change => change.path))
        for (const item of trace.activities) {
          if (item.kind === "read" && edited.has(item.target)) continue
          rows.push(color(item.failed ? 91 : 36, truncate(`${item.kind}${item.failed ? " failed" : ""} ${item.target.replace(/[\p{Cc}\p{Cf}]/gu, " ")}`, width)))
        }
        for (const change of trace.changes) {
          const read = trace.activities.some(item => item.kind === "read" && item.target === change.path)
          const counts = change.kind === "diff" ? `  +${change.added} −${change.removed}` : ""
          rows.push(color(36, truncate(`${read ? "read + " : ""}edited ${change.path.replace(/[\p{Cc}\p{Cf}]/gu, " ")}${counts}`, width)))
          if (flags.diffs) rows.push(...(change.kind === "diff" ? renderDiff(change.diff, change.path, width) : wrap(color(90, change.reason), width)))
        }
        if (trace.truncated) rows.push(color(90, truncate("activity capture limited · /v expand", width)))
        return rows
      }
      if (trace?.activities.length) {
        rows.push(color(1, trace.activities.some(item => item.kind === "run") ? "executed" : "explored"))
        for (const item of trace.activities) {
          const action = color(item.failed ? 91 : 36, `${item.kind}${item.failed ? " failed" : ""}`)
          rows.push(...wrap(`  ${action} ${item.target}`, width))
        }
      }
      for (const change of trace?.changes ?? []) {
        rows.push(...wrap(`${color(1, `edited ${change.path}`)}${change.kind === "diff"
          ? `  ${color(32, `+${change.added}`)} ${color(31, `−${change.removed}`)}` : ""}`, width))
        if (flags.diffs) rows.push(...(change.kind === "diff" ? renderDiff(change.diff, change.path, width) : wrap(color(90, change.reason), width)))
      }
      if (trace?.truncated) rows.push(...wrap(color(90, "activity capture limited; some operations are not shown"), width))
      if (flags.tools && entry.name === "python" && typeof entry.args.code === "string") {
        rows.push(...markdown(`\`\`\`python\n${entry.args.code}\n\`\`\``))
      }
      if (flags.tools || failed || !hasTrace) {
        const output = wrap(entry.result.trimEnd() || "(no output)", width)
        rows.push(...(flags.tools ? output : preview(output, 3, width, failed)))
      }
      return rows
    }
  }
}

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })
const truncate = (text: string, width: number): string => {
  if (width <= 0) return ""
  if (stringWidth(text) <= width) return text
  let line = ""
  for (const { segment } of graphemes.segment(text)) {
    if (stringWidth(line + segment) > width - 1) break
    line += segment
  }
  return `${line}…`
}
const progressLabel = (progress: ToolProgress): string => {
  const intent = progress.intent
  return (intent ? `${{ write: "writing", edit: "editing", read: "reading", run: progress.phase === "generating" ? "preparing" : "running" }[intent.kind]} ${intent.target}`
    : progress.phase === "generating" ? `making a ${progress.name} call` : `running ${progress.name}`).replace(/[\p{Cc}\p{Cf}]/gu, " ")
}

export function progressCodeWidth(progress: ToolProgress | null, width: number): number {
  if (!progress?.code || progress.phase !== "generating") return 0
  const labelWidth = Math.min(stringWidth(progressLabel(progress)), Math.max(0, Math.floor((width - 5) / 2)))
  return Math.max(0, width - 2 - labelWidth - 3)
}

/** A transient, single-row action, replaced by the actual result rather than logged. */
export function renderToolProgress(progress: ToolProgress, width: number, spinner = "", code = ""): string {
  const prefix = spinner ? `${spinner} ` : ""
  const codeWidth = spinner ? progressCodeWidth(progress, width) : 0
  const label = truncate(progressLabel(progress), width - stringWidth(prefix) - (codeWidth ? codeWidth + 3 : 0))
  if (width < 2 && spinner) return color(36, spinner)
  return `${color(36, prefix)}${color(37, label)}${codeWidth ? `${color(90, " · ")}${color(37, truncate(code, codeWidth))}` : ""}`
}
