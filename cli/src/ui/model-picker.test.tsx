import assert from "node:assert/strict"
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { PassThrough } from "node:stream"
import test from "node:test"
import { render } from "ink"

const until = async (ready: () => boolean, what: string): Promise<void> => {
  for (let attempt = 0; attempt < 400; attempt++) {
    if (ready()) return
    await new Promise(resolve => setTimeout(resolve, 5))
  }
  throw new Error(`timed out: ${what}`)
}

test("/model opens the session provider's picker, saves selections and offers manual fallback without losing chat", { timeout: 15_000 }, async t => {
  const home = await mkdtemp(join(tmpdir(), "albedo-model-"))
  const previousHome = process.env.ALBEDO_HOME
  process.env.ALBEDO_HOME = home
  t.after(async () => {
    if (previousHome === undefined) delete process.env.ALBEDO_HOME
    else process.env.ALBEDO_HOME = previousHome
    await rm(home, { recursive: true, force: true })
  })
  let listed = 0, streams = 0, unavailable = false, rejectChange = false
  const changes: string[] = []
  const session = { id: "session", title: "existing conversation", workspace: "/tmp", provider: "saved", protocol: "responses", model: "old-model" }
  const server = createServer(async (req, res) => {
    if (req.url === "/saved/models") {
      listed++
      assert.equal(req.headers.authorization, "Bearer saved-key")
      res.writeHead(unavailable ? 503 : 200, { "content-type": "application/json" })
      res.end(JSON.stringify({ data: [{ id: "old-model" }, { id: "new-model" }] }))
    } else if (req.url === "/sessions/session/model") {
      let body = ""
      for await (const chunk of req) body += chunk
      const model = (JSON.parse(body) as { model: string }).model
      if (rejectChange) { res.writeHead(409); res.end(JSON.stringify({ error: "session must be idle" })); return }
      changes.push(model); session.model = model
      res.end(JSON.stringify({ ok: true }))
    } else if (req.url?.startsWith("/sessions/session/stream")) {
      streams++
      res.writeHead(200, { "content-type": "text/event-stream" })
      res.write(`data: ${JSON.stringify({ cursor: 1, events: [{ type: "message", text: "keep this conversation visible" }] })}\n\n`)
    } else if (req.url === "/sessions/session/status") res.end(JSON.stringify({ running: false, idle: true }))
    else { res.writeHead(404); res.end("{}"); assert.fail(`unexpected route ${req.url}`) }
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.closeAllConnections(); server.close() })
  const address = server.address()
  assert(address && typeof address !== "string")
  const config = JSON.stringify({ active: "other", providers: {
    saved: { baseUrl: `http://127.0.0.1:${address.port}/saved`, apiKey: "saved-key", model: "old-model", protocol: "responses" },
    other: { baseUrl: `http://127.0.0.1:${address.port}/wrong`, apiKey: "other-key", model: "other-model", protocol: "responses" },
  } })
  await writeFile(join(home, "config.json"), config)
  // profiles captures ALBEDO_HOME on import; this test file has its own process.
  const { App } = await import("./app.js")
  const stdin = Object.assign(new PassThrough(), { isTTY: true, setRawMode: () => stdin, ref: () => stdin, unref: () => stdin }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), { isTTY: true, columns: 120, rows: 40 }) as unknown as NodeJS.WriteStream
  let painted = ""
  stdout.on("data", (chunk: Buffer) => { painted += chunk.toString() })
  const app = render(<App connection={{ port: address.port, token: "fixture", pid: 1, version: 2 }} initial={{ ...session }} workspace="/tmp" quit={() => {}} />, { stdin, stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => app.unmount())
  const enter = async (text: string): Promise<void> => { stdin.write(text); await app.waitUntilRenderFlush(); stdin.write("\r") }
  const open = async (): Promise<void> => {
    painted = ""
    await enter("/model")
    await until(() => painted.includes("session model"), "model picker")
    assert(painted.includes("current"))
  }
  await until(() => painted.includes("keep this conversation visible"), "chat")
  await open()
  painted = ""
  await enter("new-model")
  await until(() => changes.length === 1 && painted.includes("keep this conversation visible"), "selection returns to preserved chat")
  assert.deepEqual(changes, ["new-model"])
  assert(painted.includes("new-model"))
  await open()
  painted = ""
  stdin.write("\x1b")
  await until(() => painted.includes("keep this conversation visible"), "cancel picker")
  assert.equal(changes.length, 1)
  unavailable = true
  await open()
  assert(painted.includes("could not list models"))
  await enter("manually")
  await until(() => painted.includes("model id:"), "manual model entry")
  stdin.write("\x15")
  await app.waitUntilRenderFlush()
  rejectChange = true
  await enter("manual-model")
  await until(() => painted.includes("session must be idle"), "failed switch remains actionable")
  assert.equal(changes.length, 1)
  rejectChange = false
  painted = ""
  stdin.write("\r")
  await until(() => changes.length === 2 && painted.includes("keep this conversation visible"), "retry manual selection")
  assert.deepEqual(changes, ["new-model", "manual-model"])
  assert.equal(listed, 3)
  assert.equal(streams, 1, "switching models must not discard the mounted conversation")
  assert.equal(await readFile(join(home, "config.json"), "utf8"), config, "session selection must not change provider defaults")
})
