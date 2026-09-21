import assert from "node:assert/strict"
import test from "node:test"
import { createServer } from "node:http"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { assistantAge, sessionListing } from "./sessions.js"

test("session listing names sessions and ages assistant timestamps without guessing missing dates", () => {
  const now = 2_000_000_000_000
  for (const [seconds, label] of [[0, "just now"], [59, "just now"], [60, "1m ago"], [3599, "59m ago"], [3600, "1h ago"], [86400, "1d ago"], [-10, "just now"]] as const) {
    assert.equal(assistantAge(now / 1000 - seconds, now), label)
  }
  assert.equal(assistantAge(null, now), "time unknown")
  assert.equal(assistantAge(undefined, now), "time unknown")
  assert.equal(assistantAge(NaN, now), "time unknown")
  const session = { id: "deadbeef1234", title: "fix the session picker", workspace: "/tmp", model: "fixture", provider: "fixture", protocol: "responses", last_assistant_at: now / 1000 - 120 }
  assert.equal(sessionListing([session], now), "fix the session picker  [deadbeef]\n  last assistant: 2m ago")
  assert.equal(sessionListing([], now), "no sessions")
  assert(sessionListing([{ ...session, last_assistant_at: null }], now).includes("time unknown"))
  assert(!sessionListing([{ ...session, title: "line\nbreak\x1b" }], now).includes("\x1b"))
  assert(sessionListing([{ ...session, title: "fix 👩‍💻 unicode" }], now).includes("fix 👩‍💻 unicode"))
})


test("albedo sessions defaults to readable names and keeps --json for scripts", async t => {
  const home = await mkdtemp(join(tmpdir(), "albedo-session-list-"))
  t.after(() => rm(home, { recursive: true, force: true }))
  const sessions = [{ id: "abcdef123456", title: "my latest prompt", last_assistant_at: Math.floor(Date.now() / 1000) - 120, workspace: "/tmp", model: "fixture", provider: "fixture", protocol: "responses" }]
  const server = createServer((req, res) => {
    assert.equal(req.headers.authorization, "Bearer fixture")
    res.setHeader("content-type", "application/json")
    res.end(JSON.stringify(req.url === "/health" ? { ok: true, version: 2 } : sessions))
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.closeAllConnections(); server.close() })
  const address = server.address()
  assert(address && typeof address !== "string")
  await writeFile(join(home, "daemon.json"), JSON.stringify({ port: address.port, token: "fixture", pid: 1, version: 2 }))
  const run = (args: string[]) => promisify(execFile)(process.execPath, [fileURLToPath(new URL("../bin/albedo.mjs", import.meta.url)), "sessions", ...args], { env: { ...process.env, ALBEDO_HOME: home }, timeout: 15_000 })
  const [human, machine] = await Promise.all([run([]), run(["--json"])])
  assert(human.stdout.includes("my latest prompt  [abcdef12]"))
  assert(human.stdout.includes("last assistant: 2m ago"))
  assert.deepEqual(JSON.parse(machine.stdout), sessions)
})
