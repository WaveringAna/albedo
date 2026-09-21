export type MouseEvent = { button: number; x: number; y: number; press: boolean; motion: boolean }

/** Ink strips the first escape; retain partial SGR reports across input chunks. */
export class MouseInput {
  private pending = ""
  read(input: string): MouseEvent[] | null {
    if (!this.pending && !/^(?:\x1b)?\[</.test(input)) return null
    const hadPending = this.pending !== ""
    const data = this.pending + input
    this.pending = ""
    if (hadPending && !/^[\d;Mm\x1b\[]/.test(input)) return null
    const events: MouseEvent[] = []
    let rest = data
    while (rest) {
      const match = /^(?:\x1b)?\[<(\d+);(\d+);(\d+)([Mm])/.exec(rest)
      if (!match) {
        if (/^(?:\x1b)?\[<[\d;]*$/.test(rest) && rest.length < 96) this.pending = rest
        break
      }
      const raw = Number(match[1])
      const x = Number(match[2]), y = Number(match[3])
      if (Number.isSafeInteger(raw) && Number.isSafeInteger(x) && Number.isSafeInteger(y) && x > 0 && y > 0)
        events.push({ button: raw & ~60, x, y, press: match[4] === "M", motion: (raw & 32) !== 0 })
      rest = rest.slice(match[0].length)
    }
    return events
  }
}
