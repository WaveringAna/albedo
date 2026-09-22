import assert from "node:assert/strict"
import { describe, it } from "node:test"
import { parseSkillCatalog, parseSkillInvocation, type SkillCatalog } from "./skills.js"

const catalog: SkillCatalog = { skills: [
  { name: "review", description: "Review", command: "/review", source: "/tmp/review/SKILL.md" },
  { name: "model", description: "No hijack", command: "/skill:model", source: "/tmp/model/SKILL.md" },
], diagnostics: [] }

describe("skill slash commands", () => {
  it("preserves trailing argument text after one command separator", () => {
    assert.deepEqual(parseSkillInvocation("/review one  two ", catalog), { skill: catalog.skills[0], arguments: "one  two " })
    assert.equal(parseSkillInvocation("/review   indented", catalog)?.arguments, "  indented")
  })

  it("matches exact commands and keeps namespaced collision fallback", () => {
    assert.equal(parseSkillInvocation("/reviewing nope", catalog), undefined)
    assert.equal(parseSkillInvocation("/model built-in", catalog), undefined)
    assert.equal(parseSkillInvocation("/skill:model args", catalog)?.skill.name, "model")
  })

  it("validates daemon metadata", () => {
    assert.deepEqual(parseSkillCatalog(catalog), catalog)
    assert.throws(() => parseSkillCatalog({ skills: [{ ...catalog.skills[0], command: "/bad command" }], diagnostics: [] }), /invalid/)
  })
})
