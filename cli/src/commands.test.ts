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

  it("validates daemon metadata but survives one malformed row", () => {
    assert.deepEqual(parseCommandCatalog(catalog), catalog)
    // One bad row must not blank the menu.
    assert.deepEqual(parseCommandCatalog([{ ...catalog[0], name: "/bad command" }, catalog[1]]), [catalog[1]])
    assert.deepEqual(parseCommandCatalog([{ ...catalog[0], modelCallable: "yes" }, catalog[2]]), [catalog[2]])
    // Underscored names are producer-valid and must survive too.
    const snake: SessionCommand = { name: "/snake_case", description: "Snake", method: "snake_case", modelCallable: true, userTurn: true, arguments: [] }
    assert.deepEqual(parseCommandCatalog([snake]), [snake])
    // A wholly invalid payload still refuses.
    assert.throws(() => parseCommandCatalog([{ ...catalog[0], arguments: [{ name: "x", description: 1, required: false }] }]), /invalid/)
    assert.throws(() => parseCommandCatalog({ commands: [] }), /invalid/)
  })
})
