import wrapAnsi from "wrap-ansi"
import { renderMarkdownAnsi } from "./markdown.js"
import { RowIndex, joinRows, type Rows } from "./row-index.js"

type Layout = { rows: RowIndex; fragments: number; revision: number; tail: string[] }
const render = (text: string, width: number): string[] =>
  wrapAnsi(renderMarkdownAnsi(text, width), width, { hard: true, trim: false }).split("\n")

/** Completed lines/closed fences never change; only the unfinished suffix is reparsed.
 * Keep a fence together: syntax highlighting can span its lines. Raw ANSI similarly
 * falls back to a single fragment so styles crossing newlines are preserved. */
export class MarkdownIndex {
  private readonly fragments: string[] = []
  private readonly layouts = new Map<number, Layout>()
  private readonly fence: string[] = []
  private line = ""
  private revision = 0
  private opaque = false

  append(chunk: string): void {
    this.revision++
    this.opaque ||= /[\x1b\x9b]/.test(chunk)
    let start = 0
    for (let end = chunk.indexOf("\n"); end !== -1; end = chunk.indexOf("\n", start)) {
      this.line += chunk.slice(start, end + 1)
      const delimiter = this.line.startsWith("```")
      if (this.fence.length) {
        this.fence.push(this.line)
        if (delimiter) { this.fragments.push(this.fence.join("")); this.fence.length = 0 }
      } else if (delimiter) this.fence.push(this.line)
      else this.fragments.push(this.line)
      this.line = ""
      start = end + 1
    }
    this.line += chunk.slice(start)
  }

  text(): string { return this.fragments.join("") + this.fence.join("") + this.line }

  layout(width: number): Rows {
    width = Math.max(1, width)
    const layout = this.layouts.get(width) ?? { rows: new RowIndex(), fragments: 0, revision: -1, tail: [] }
    this.layouts.delete(width)
    this.layouts.set(width, layout)
    if (this.layouts.size > 2) this.layouts.delete(this.layouts.keys().next().value!)
    if (layout.revision !== this.revision) {
      if (this.opaque) layout.tail = render(this.text(), width)
      else {
        while (layout.fragments < this.fragments.length) {
          layout.rows.append(render(this.fragments[layout.fragments++]!.slice(0, -1), width))
        }
        layout.tail = render(this.fence.join("") + this.line, width)
      }
      layout.revision = this.revision
    }
    return this.opaque ? layout.tail : joinRows([layout.rows, layout.tail])
  }
}
