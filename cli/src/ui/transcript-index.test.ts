import assert from "node:assert/strict"
import test from "node:test"
import { TranscriptIndex, transcriptWindow } from "./transcript-index.js"
import { RowIndex } from "./row-index.js"
import { renderEntry, type Entry } from "./transcript.js"

test("indexed windows match flat rows across arbitrary block and tail boundaries", () => {
  const index = new RowIndex()
  const flat: string[] = []
  for (let i = 0; i < 200; i++) {
    const block = Array.from({ length: (i * 17) % 13 }, (_, j) => `${i}:${j}`)
    index.append(block)
    flat.push(...block)
  }
  assert.equal(index.length, flat.length)
  const tails = [["", "thinking", "世界"], ["", "⠋ writing main.ts"]]
  const combined = [...flat, ...tails.flat()]
  for (let start = 0; start <= combined.length + 5; start++) {
    for (const height of [0, 1, 3, 40]) {
      assert.deepEqual(index.slice(start, start + height), flat.slice(start, start + height))
      assert.equal(transcriptWindow(index, tails, start, height), combined.slice(start, start + height).join("\n"))
    }
  }
})


test("layout eviction and appends preserve all history with wide and ansi text", () => {
  const transcript = new TranscriptIndex()
  const flags = { tools: false, thinking: true }
  const entries: Entry[] = Array.from({ length: 80 }, (_, i) => ({ kind: "assistant", text: `${i} **bold** \u001b[32m${"界".repeat(i + 1)}\u001b[0m` }))
  for (const entry of entries) { transcript.append(entry); transcript.layout(flags, "niri", 40) }
  for (const width of [20, 30, 40, 1, 100, 40]) {
    const expected = entries.flatMap((e, i) => [...(i ? [""] : []), ...renderEntry(e, flags, "niri", width)])
    const rows = transcript.layout(flags, "niri", width)
    assert.deepEqual(rows.slice(0, rows.length), expected)
  }
})

test("reflow and expansion anchor the same record and clamp offsets in collapsed records", () => {
  const transcript = new TranscriptIndex()
  transcript.append(
    { kind: "tool", name: "python", args: {}, result: "a long result\n".repeat(50) },
    { kind: "user", source: "you", text: "the record being read" },
    { kind: "thinking", text: "reasoning\n".repeat(100) },
  )
  const flags = { tools: false, thinking: true }
  const old = transcript.layout(flags, "niri", 30)
  const anchor = old.anchorAt(old.starts[1]! + 1)
  for (const width of [12, 80]) {
    const next = transcript.layout({ tools: true, thinking: false }, "niri", width)
    assert.deepEqual(next.anchorAt(next.rowAt(anchor)), anchor)
    const collapsed = next.rowAt({ entry: 2, offset: 80 })
    assert.match(next.slice(collapsed, collapsed + 1)[0]!, /hidden/)
  }
  assert.equal(old.rowAt(old.anchorAt(old.length + 20)), old.length + 20)
})


test("timestamp confirmation changes only headings and never mutates a drag snapshot", () => {
  let renders = 0
  const index = new TranscriptIndex((...args) => { renders++; return renderEntry(...args) })
  const flags = { tools: false, thinking: true }
  const id = index.append({ kind: "assistant", text: "body" })
  const layout = index.layout(flags, "albedo", 40, 120)
  const saved = layout.snapshot()
  const before = saved.slice(0, saved.length)
  index.timestamp(id, new Date(2026, 8, 21, 0, 58, 30).getTime())
  assert.equal(index.layout(flags, "albedo", 40, 120), layout)
  assert.equal(renders, 1)
  assert(layout.slice(0, 1)[0]!.includes("00:58:30"))
  assert.deepEqual(layout.slice(1, layout.length), before.slice(1))
  assert.deepEqual(saved.slice(0, saved.length), before)
  index.layout(flags, "albedo", 60, 80)
  index.layout(flags, "albedo", 60, 90)
  assert(index.layout(flags, "albedo", 40, 120).slice(0, 1)[0]!.includes("00:58:30"))
})
