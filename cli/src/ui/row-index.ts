export type Rows = { readonly length: number; slice(start: number, end: number): string[] }

/** Immutable row blocks, indexed by their start row. No flattened history copy. */
export class RowIndex {
  private blocks: { start: number; rows: readonly string[] }[] = []
  length = 0

  append(rows: readonly string[]): void {
    if (!rows.length) return
    this.blocks.push({ start: this.length, rows })
    this.length += rows.length
  }

  replace(row: number, text: string): void {
    if (row < 0 || row >= this.length) return
    const index = this.blockAt(row)
    const block = this.blocks[index]!
    const rows = block.rows.slice()
    rows[row - block.start] = text
    this.blocks[index] = { start: block.start, rows }
  }

  snapshot(): Rows {
    const saved = new RowIndex()
    saved.blocks = this.blocks.slice()
    saved.length = this.length
    return saved
  }

  private blockAt(row: number): number {
    let low = 0; let high = this.blocks.length
    while (low < high) {
      const middle = (low + high) >>> 1
      if (this.blocks[middle]!.start <= row) low = middle + 1
      else high = middle
    }
    return low - 1
  }

  /** O(log(blocks) + visible rows), independent of the amount of offscreen text. */
  slice(start: number, end: number): string[] {
    start = Math.max(0, start)
    end = Math.min(this.length, end)
    if (end <= start) return []
    const rows: string[] = []
    for (let i = this.blockAt(start); i < this.blocks.length; i++) {
      const block = this.blocks[i]!
      if (block.start >= end) break
      const from = Math.max(0, start - block.start)
      const to = Math.min(block.rows.length, end - block.start)
      for (let row = from; row < to; row++) rows.push(block.rows[row]!)
    }
    return rows
  }
}

/** A cheap view over row sources: only the requested viewport is copied. */
export function joinRows(parts: readonly Rows[]): Rows {
  return {
    length: parts.reduce((sum, part) => sum + part.length, 0),
    slice(start, end) {
      const rows: string[] = []
      let offset = 0
      for (const part of parts) {
        const from = Math.max(0, start - offset)
        const to = Math.min(part.length, end - offset)
        if (to > from) rows.push(...part.slice(from, to))
        offset += part.length
        if (offset >= end) break
      }
      return rows
    },
  }
}
