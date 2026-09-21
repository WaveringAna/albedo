import assert from "node:assert/strict"
import test from "node:test"
import stringWidth from "string-width"
import { advanceCodeLine, type CodeLine } from "./code-line.js"
import type { ToolProgress } from "../client.js"
const progress = (text: string, offset = 0, callId = "cell-1"): ToolProgress => ({ callId, name: "python", phase: "generating", code: { text, offset } })

test("python fills one row, then clears and keeps typing instead of wrapping or scrolling", () => {
  let row = advanceCodeLine(null, progress("def abcdefg"), 12)
  assert.equal(row?.line, "def abcdefg")
  row = advanceCodeLine(row, progress("def abcdefg("), 12)
  assert.equal(row?.line, "def abcdefg(")
  row = advanceCodeLine(row, progress("def abcdefg(longarg)"), 12)
  assert.equal(row?.line, "longarg)")
  assert.equal(advanceCodeLine(row, progress("def abcdefg(longarg)"), 12), row, "spinner ticks and duplicate samples do not type twice")
})

test("a rolling transport tail never duplicates or loses characters on normal streamed updates", () => {
  const text = "def function_name(long_argument): return long_argument + 1; ".repeat(30)
  let row: CodeLine | null = null
  for (let end = 1; end <= text.length; end++) {
    const start = Math.max(0, end - 512)
    row = advanceCodeLine(row, progress(text.slice(start, end), start), 23)
    const pageStart = Math.floor((end - 1) / 23) * 23
    assert.equal(row?.line, text.slice(pageStart, end))
  }
})

test("width, new calls, missed samples, unicode, control characters and completion stay bounded", () => {
  let row = advanceCodeLine(null, progress("abc界界界\nnext\x1b"), 7)
  assert.ok(stringWidth(row!.line) <= 7)
  assert.doesNotMatch(row!.line, /[\n\x1b]/)
  row = advanceCodeLine(row, progress("abcdef"), 3)
  assert.equal(row?.line, "def")
  row = advanceCodeLine(row, progress("next", 0, "cell-2"), 20)
  assert.equal(row?.line, "next")
  row = advanceCodeLine(row, progress("missed then new", 1000, "cell-2"), 20)
  assert.equal(row?.line, "missed then new")
  assert.equal(advanceCodeLine(row, { ...progress("done"), phase: "running" }, 20), null)
  assert.equal(advanceCodeLine(row, null, 20), null)
  assert.equal(advanceCodeLine(row, progress("x"), 0), null)
})

test("corrected argument snapshots replace the row instead of appending to stale code", () => {
  const row = advanceCodeLine(null, progress("wrong prefix"), 30)
  const corrected = advanceCodeLine(row, progress("corrected function()"), 30)
  assert.equal(corrected?.line, "corrected function()")
})
