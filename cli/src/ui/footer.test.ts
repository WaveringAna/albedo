import assert from "node:assert/strict"
import test from "node:test"
import { footerLine } from "./footer.js"

const usage = { type: "usage" as const, model: "openai/gpt-5", promptTokens: 10_000, completionTokens: 200, totalTokens: 10_200, cachedPromptTokens: 8000, recordedAt: 2_000_000_000_000 }

test("footer shows provider-reported cached and input token counts", () => {
  const line = footerLine(120, usage, usage.model)
  assert(line.startsWith("/ commands · drag to copy"))
  assert(line.endsWith("ctx 10.2k · cached 8,000/10,000"))
  assert.equal(line.length, 120)
  assert(footerLine(120, { ...usage, promptTokens: 20_000 }, usage.model).endsWith("cached 8,000/20,000"))
})

test("unknown cache, changed models and narrow terminals never invent usage or wrap", () => {
  assert(footerLine(120, undefined, usage.model).endsWith("ctx — · cached —/—"))
  assert(footerLine(120, { ...usage, cachedPromptTokens: undefined }, usage.model).endsWith("cached —/10,000"))
  assert(footerLine(120, { ...usage, cachedPromptTokens: 0 }, usage.model).endsWith("cached 0/10,000"))
  assert(footerLine(120, { ...usage, recordedAt: undefined }, usage.model).endsWith("cached 8,000/10,000"))
  assert(footerLine(120, { ...usage, model: "custom" }, "custom").endsWith("cached 8,000/10,000"))
  assert(footerLine(120, usage, "different").endsWith("ctx — · cached —/—"))
  for (const width of [0, 1, 12, 24, 40, 60, 80, 120]) {
    const line = footerLine(width, usage, usage.model)
    assert(line.length <= width)
    assert(!line.includes("\n"))
  }
})


test("footer mode indicators follow thinking and verbose flags and compact without wrapping", () => {
  for (const thinking of [true, false]) for (const tools of [true, false]) {
    const flags = { thinking, tools }
    const line = footerLine(140, usage, usage.model, flags)
    assert(line.includes(`thinking ${thinking ? "on" : "off"} · verbose ${tools ? "on" : "off"}`))
    assert(line.endsWith("cached 8,000/10,000"))
    assert.equal(line.length, 140)
    for (const width of [1, 12, 35, 50, 70, 90]) assert(footerLine(width, usage, usage.model, flags).length <= width)
  }
})
