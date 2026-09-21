import stringWidth from "string-width"
import type { ToolProgress } from "../client.js"

export type CodeLine = {
  callId: string
  width: number
  source: { offset: number; text: string }
  line: string
}
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

/** A typewriter row: fill, clear on overflow, continue. No wrapping or scrollback. */
export function advanceCodeLine(current: CodeLine | null, progress: ToolProgress | null, width: number): CodeLine | null {
  const source = progress?.phase === "generating" ? progress.code : undefined
  if (!source || !progress || width < 1) return null
  const same = current?.callId === progress.callId && current.width === width
  if (same && current.source.offset === source.offset && current.source.text === source.text) return current
  const end = same ? current.source.offset + current.source.text.length : 0
  const shared = same ? Math.max(current.source.offset, source.offset) : 0
  const continued = same && source.offset <= end && source.offset + source.text.length > end &&
    source.text.slice(shared - source.offset, end - source.offset) === current.source.text.slice(shared - current.source.offset)
  let line = continued ? current.line : ""
  const delta = source.text.slice(continued ? end - source.offset : 0).replace(/[\p{Cc}\p{Cf}]/gu, " ")
  for (const { segment } of graphemes.segment(delta)) {
    if (stringWidth(line + segment) > width) line = ""
    if (stringWidth(segment) <= width) line += segment
  }
  return { callId: progress.callId, width, source, line }
}
