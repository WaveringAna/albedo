import assert from "node:assert/strict"
import test from "node:test"
import { stripVTControlCharacters as strip } from "node:util"
import { color, wrap, renderToolProgress, renderEntry, type Entry } from "./transcript.js"
const flags = { thinking: true, tools: false }
const tool = (result: string): Entry => ({ kind: "tool", name: "python", args: { code: 'print("hi")' }, result })

test("a single huge python repr is capped by wrapped terminal rows, not source lines", () => {
  const entry = tool("x".repeat(1_000))
  const rows = renderEntry(entry, flags, "niri", 40).map(strip)
  assert.equal(rows[0], "python · 1 line")
  assert.equal(rows.length, 5)
  assert.match(rows[4]!, /22 rows hidden/)
  assert.ok(rows.every(row => row.length <= 40))
  assert.ok(renderEntry(entry, { ...flags, tools: true }, "niri", 40).length > 25)
})

test("ansi and wide characters wrap within the preview budget, and errors keep their tail", () => {
  const rows = renderEntry(tool("\x1b[32m" + "界".repeat(60) + "\x1b[0m"), flags, "niri", 20).map(strip)
  assert.equal(rows.slice(1, 4).join(""), "界".repeat(30))
  const error = renderEntry(tool("error:\n" + "noise\n".repeat(20) + "final failure"), flags, "niri", 60).map(strip)
  assert.match(error[0]!, /failed/)
  assert.equal(error.at(-1), "final failure")
})

test("execution evidence replaces raw repr with actions and bounded per-cell diffs", () => {
  const entry: Entry = { ...tool("raw python repr"), kind: "tool", name: "python", args: {}, result: "raw python repr", trace: {
    activities: [{ kind: "read", target: "src/app.ts" }, { kind: "search", target: "timer in src" }],
    changes: [{ kind: "diff", path: "app.ts", added: 12, removed: 1, diff: "@@ -1 +1 @@\n-old\n" + "+new\n".repeat(12).trimEnd() }],
  } }
  const rows = renderEntry(entry, flags, "niri", 80).map(strip)
  assert.deepEqual(rows, ["read src/app.ts", "search timer in src", "edited app.ts  +12 −1"])
  assert.equal(rows.includes("raw python repr"), false)
  const expanded = renderEntry(entry, { ...flags, tools: true }, "niri", 80).map(strip)
  assert.ok(expanded.includes("raw python repr"))
  assert.equal(expanded.some(row => row.includes("+new")), false)
  const diffs = renderEntry(entry, { ...flags, diffs: true }, "niri", 80).map(strip)
  assert(diffs.some(row => row.includes("new")))
})

test("read and edit of the same file share one compact row", () => {
  const entry: Entry = { kind: "tool", name: "python", args: {}, result: "ok", trace: {
    activities: [{ kind: "read", target: "file.py" }],
    changes: [{ kind: "diff", path: "file.py", diff: "-old\n+new", added: 1, removed: 1 }],
  } }
  assert.deepEqual(renderEntry(entry, flags, "albedo", 80).map(strip), ["read + edited file.py  +1 −1"])
  assert(renderEntry(entry, { ...flags, tools: true }, "albedo", 80).map(strip).includes("  read file.py"))
  assert(!renderEntry(entry, { ...flags, tools: true }, "albedo", 80).map(strip).some(row => row.includes("+new")))
  assert(renderEntry(entry, { ...flags, tools: true, diffs: true }, "albedo", 80).map(strip).some(row => row.includes("new")))
})

test("compact edits stay one row while expanded diffs preserve ANSI, tabs and wrapping", () => {
  const diff = ["@@ -1 +1 @@", "-old", "+short", "+\tindented", "+" + "界".repeat(40),
    "+\x1b[1mbold\x1b[0m", ...Array.from({ length: 40 }, (_, i) => `+line ${i} ` + "x".repeat(i))].join("\n")
  const entry: Entry = { kind: "tool", name: "python", args: {}, result: "ok", trace: {
    activities: [], changes: [{ kind: "diff", path: "file", diff, added: 45, removed: 1 }],
  } }
  for (const width of [1, 20, 96]) {
    const compact: string[] = renderEntry(entry, flags, "niri", width).map(strip)
    assert.equal(compact.length, 1)
    assert(compact[0]!.length <= width)
    if (width === 96) assert.equal(compact[0], "edited file  +45 −1")
    const expanded = renderEntry(entry, { ...flags, diffs: true }, "niri", width).map(strip)
    assert(expanded.length > compact.length)
    if (width === 96) {
      assert(expanded.some(row => row.includes("1 - old")))
      assert(expanded.some(row => row.includes("1 + short")))
      assert(expanded.some(row => row.includes("indented")))
    }
  }
})


test("live actions occupy exactly one bounded row, including wide filenames and controls", () => {
  const progress = { callId: "1", name: "python", phase: "generating" as const, intent: { kind: "write" as const, target: "页面".repeat(50) + "\n\x1b[31m.html" } }
  const row = strip(renderToolProgress(progress, 30))
  assert.equal(row.split("\n").length, 1)
  assert.match(row, /^writing /)
  assert.match(row, /…$/)
  assert.equal(strip(renderToolProgress(progress, 1)), "…")
})


test("message clocks sit at the viewport edge without widening body text", async () => {
  const { default: stringWidth } = await import("string-width")
  const { messageHeading } = await import("./transcript.js")
  const timestamp = new Date(2026, 8, 21, 0, 58, 30).getTime()
  const rows = renderEntry({ kind: "assistant", text: "word ".repeat(40), timestamp }, flags, "albedo", 40, 120)
  assert.equal(strip(rows[0]!).slice(-8), "00:58:30")
  assert.equal(stringWidth(rows[0]!), 120)
  assert(rows.slice(1).every(row => stringWidth(row) <= 40))
  assert.equal(strip(messageHeading("you", 96, 120)), "you")
  assert.equal(strip(messageHeading("you", 96, 120, NaN)), "you")
  for (const width of [1, 8, 11, 20, 120]) {
    const heading = messageHeading("界é👩‍💻".repeat(12), 96, width, timestamp)
    assert(stringWidth(heading) <= width)
    assert(!strip(heading).includes("\n"))
  }
})

test("images a tool returned are listed by metadata after its output", () => {
  const entry: Entry = { kind: "tool", name: "python", args: {}, result: "ok", images: [{ mimeType: "image/png", width: 640, height: 480, bytes: 2048 }] }
  const rows = renderEntry(entry, flags, "niri", 60).map(strip)
  assert.equal(rows.at(-1), "image PNG 640×480 · 2 KB")
})
