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
  assert.equal(rows[0], "explored")
  assert.ok(rows.includes("  read src/app.ts"))
  assert.ok(rows.includes("edited app.ts  +12 −1"))
  assert.match(rows.at(-1)!, /rows hidden/)
  assert.equal(rows.includes("raw python repr"), false)
  const expanded = renderEntry(entry, { ...flags, tools: true }, "niri", 80).map(strip)
  assert.ok(expanded.includes("raw python repr"))
  assert.equal(expanded.includes("+new"), true)
})

test("diff previews count hidden rows without changing ANSI, tab, or wide-text wrapping", () => {
  const diff = ["@@ -1 +1 @@", "-old", "+short", "+\tindented", "+" + "界".repeat(40),
    "+\x1b[1mbold\x1b[0m", ...Array.from({ length: 40 }, (_, i) => `+line ${i} ` + "x".repeat(i))].join("\n")
  const entry: Entry = { kind: "tool", name: "python", args: {}, result: "ok", trace: {
    activities: [], changes: [{ kind: "diff", path: "file", diff, added: 45, removed: 1 }],
  } }
  for (const width of [1, 20, 96]) {
    const full = diff.split("\n").flatMap(line => wrap(color(line.startsWith("+") ? 32 : line.startsWith("-") ? 31 : 90, line), width))
    const heading = wrap(`${color(1, "edited file")}  ${color(32, "+45")} ${color(31, "−1")}`, width)
    const expected = [...heading, ...full.slice(0, 8), ...wrap(color(90, `… ${full.length - 8} rows hidden · /v expand`), width)]
    assert.deepEqual(renderEntry(entry, flags, "niri", width), expected)
    const expanded = renderEntry(entry, { ...flags, tools: true }, "niri", width)
    const outputRows = wrap("ok", width).length
    assert.deepEqual(expanded.slice(-full.length - outputRows, -outputRows), full)
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
