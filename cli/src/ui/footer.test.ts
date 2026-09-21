import assert from "node:assert/strict"
import test from "node:test"
import { cacheExpiry, footerLine } from "./footer.js"

const now = 2_000_000_000_000
const usage = { type: "usage" as const, model: "openai/gpt-5", promptTokens: 10_000, completionTokens: 200, totalTokens: 10_200, cachedPromptTokens: 8000, recordedAt: now }

test("footer aligns compact help left and measured context/cache plus estimated ttl right", () => {
  const line = footerLine(120, usage, usage.model, now)
  assert(line.startsWith("/ commands · drag to copy"))
  assert(line.endsWith("ctx 10.2k · cached 80% · ttl ~30m 0s"))
  assert.equal(line.length, 120)
  assert.equal(cacheExpiry(usage, usage.model), now + 1_800_000)
  assert(footerLine(120, usage, usage.model, now + 60_000).endsWith("ttl ~29m 0s"))
  assert(footerLine(120, usage, usage.model, now + 1_800_000).endsWith("ttl expired"))
  assert.equal(cacheExpiry({ ...usage, model: "deepseek/deepseek-v4.1-flash" }), now + 43_200_000)
})

test("unknown cache, changed models and narrow terminals never invent usage or wrap", () => {
  assert(footerLine(120, undefined, usage.model, now).endsWith("ctx — · cached — · ttl —"))
  assert(footerLine(120, { ...usage, cachedPromptTokens: undefined }, usage.model, now).endsWith("cached — · ttl —"))
  assert(footerLine(120, { ...usage, cachedPromptTokens: 0 }, usage.model, now).endsWith("cached 0% · ttl —"))
  assert(footerLine(120, { ...usage, recordedAt: undefined }, usage.model, now).endsWith("cached 80% · ttl —"))
  assert(footerLine(120, { ...usage, model: "custom" }, "custom", now).endsWith("cached 80% · ttl —"))
  assert(footerLine(120, usage, "different", now).endsWith("ctx — · cached — · ttl —"))
  for (const width of [0, 1, 12, 24, 40, 60, 80, 120]) {
    const line = footerLine(width, usage, usage.model, now)
    assert(line.length <= width)
    assert(!line.includes("\n"))
  }
})


test("footer mode indicators follow thinking and verbose flags and compact without wrapping", () => {
  for (const thinking of [true, false]) for (const tools of [true, false]) {
    const flags = { thinking, tools }
    const line = footerLine(140, usage, usage.model, now, flags)
    assert(line.includes(`thinking ${thinking ? "on" : "off"} · verbose ${tools ? "on" : "off"}`))
    assert(line.endsWith("ttl ~30m 0s"))
    assert.equal(line.length, 140)
    for (const width of [1, 12, 35, 50, 70, 90]) assert(footerLine(width, usage, usage.model, now, flags).length <= width)
  }
})
