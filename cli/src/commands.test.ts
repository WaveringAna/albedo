import assert from "node:assert/strict"
import { describe, it } from "node:test"
import { parseCommandCatalog, parseCommandInvocation, type SessionCommand } from "./commands.js"

const catalog: SessionCommand[] = [
  { name: "/review", description: "Review", method: "review", modelCallable: true, userTurn: true,
    arguments: [{ name: "arguments", description: "arguments for the skill", required: false }] },
  { name: "/skill:model", description: "No hijack", method: "skill_model", modelCallable: true, userTurn: true,
    arguments: [{ name: "arguments", description: "arguments for the skill", required: false }] },
  { name: "/model", description: "Switch models", method: "model", modelCallable: true, userTurn: false,
    arguments: [{ name: "model", description: "model id", required: false }, { name: "provider", description: "provider", required: false }] },
]

describe("session command invocations", () => {
  it("preserves trailing argument text after one command separator", () => {
    assert.deepEqual(parseCommandInvocation("/review one  two ", catalog), { name: "/review", arguments: "one  two " })
    assert.equal(parseCommandInvocation("/review   indented", catalog)?.arguments, "  indented")
  })

  it("matches exact commands and keeps namespaced collision fallback", () => {
    assert.equal(parseCommandInvocation("/reviewing nope", catalog), undefined)
    assert.equal(parseCommandInvocation("/skill:model args", catalog)?.name, "/skill:model")
    assert.equal(parseCommandInvocation("/model gpt-5", catalog)?.arguments, "gpt-5")
  })

  it("validates daemon metadata", () => {
    assert.deepEqual(parseCommandCatalog(catalog), catalog)
    assert.throws(() => parseCommandCatalog([{ ...catalog[0], name: "/bad command" }]), /invalid/)
    assert.throws(() => parseCommandCatalog([{ ...catalog[0], modelCallable: "yes" }]), /invalid/)
    assert.throws(() => parseCommandCatalog([{ ...catalog[0], arguments: [{ name: "x", description: 1, required: false }] }]), /invalid/)
    assert.throws(() => parseCommandCatalog({ commands: [] }), /invalid/)
  })
})
