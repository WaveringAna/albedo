import { messageHeading, renderEntry, type DisplayFlags, type Entry } from "./transcript.js"
import { RowIndex, joinRows, type Rows } from "./row-index.js"

type Anchor = { entry: number; offset: number }
export class TranscriptLayout extends RowIndex {
  readonly starts: number[] = []
  constructor(readonly speaker: string, readonly headingWidth: number) { super() }

  anchorAt(row: number): Anchor {
    if (row >= this.length) return { entry: this.starts.length, offset: row - this.length }
    let low = 0; let high = this.starts.length
    while (low < high) {
      const middle = (low + high) >>> 1
      if (this.starts[middle]! <= row) low = middle + 1
      else high = middle
    }
    const entry = Math.max(0, low - 1)
    return { entry, offset: row - (this.starts[entry] ?? 0) }
  }

  rowAt({ entry, offset }: Anchor): number {
    if (entry >= this.starts.length) return this.length + offset
    const start = this.starts[entry]!
    const end = this.starts[entry + 1] ?? this.length
    return start + Math.min(offset, Math.max(0, end - start - 1))
  }
}
type EntryRenderer = typeof renderEntry

/** Append-only message bodies, correctable heading timestamps, two layout variants. */
export class TranscriptIndex {
  private readonly entries: Entry[] = []
  private readonly layouts = new Map<string, TranscriptLayout>()

  constructor(private readonly render: EntryRenderer = renderEntry) {}

  clear(): void { this.entries.length = 0; this.layouts.clear() }

  append(...entries: Entry[]): number {
    const start = this.entries.length
    this.entries.push(...entries)
    return start
  }

  /** Remove a provisional tail entry that the daemon did not accept. */
  discard(index: number): boolean {
    if (index !== this.entries.length - 1) return false
    this.entries.pop()
    this.layouts.clear()
    return true
  }

  timestamp(index: number, timestamp: number): void {
    const entry = this.entries[index]
    if (!entry || (entry.kind !== "user" && entry.kind !== "assistant")) return
    this.entries[index] = { ...entry, timestamp }
    for (const layout of this.layouts.values()) {
      const row = layout.starts[index]
      if (row !== undefined) layout.replace(row, messageHeading(entry.kind === "user" ? entry.source : layout.speaker, entry.kind === "user" ? 96 : 1, layout.headingWidth, timestamp))
    }
  }

  layout(flags: DisplayFlags, speaker: string, width: number, headingWidth = width): TranscriptLayout {
    const key = JSON.stringify([flags.tools, flags.thinking, speaker, width, headingWidth])
    const layout = this.layouts.get(key) ?? new TranscriptLayout(speaker, headingWidth)
    // LRU order; old layouts catch up from their own cursor, never rerender old entries.
    this.layouts.delete(key)
    this.layouts.set(key, layout)
    if (this.layouts.size > 2) this.layouts.delete(this.layouts.keys().next().value!)
    while (layout.starts.length < this.entries.length) {
      const entry = this.entries[layout.starts.length]!
      const rows = this.render(entry, flags, speaker, width, headingWidth)
      if (layout.starts.length) layout.append([""])
      layout.starts.push(layout.length)
      layout.append(rows)
    }
    return layout
  }
}

/** Combine only the visible portions of committed history and the changing tail. */
export function transcriptWindow(history: Rows, tails: readonly Rows[], start: number, height: number): string {
  return joinRows([history, ...tails]).slice(start, start + height).join("\n")
}
