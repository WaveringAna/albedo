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

test("/model switches saved providers and models with manual fallback without losing chat", { timeout: 15_000 }, async t => {
  const home = await mkdtemp(join(tmpdir(), "albedo-model-"))
  const previousHome = process.env.ALBEDO_HOME
  process.env.ALBEDO_HOME = home
  t.after(async () => {
    if (previousHome === undefined) delete process.env.ALBEDO_HOME
    else process.env.ALBEDO_HOME = previousHome
    await rm(home, { recursive: true, force: true })
  })
  let listed = 0, streams = 0, unavailable = false, rejectChange = false, supportsProviders = false
  const changes: { model: string; provider?: string }[] = []
  const session = { id: "session", title: "existing conversation", workspace: "/tmp", provider: "saved", protocol: "responses", model: "old-model" }
  const server = createServer(async (req, res) => {
    if (req.url === "/health") {
      res.end(JSON.stringify({ ok: true, version: 2, ...(supportsProviders ? { capabilities: ["session_provider"] } : {}) }))
    } else if (req.url?.startsWith("/models/openai?endpoint=")) {
      const endpoint = new URL(req.url, "http://localhost").searchParams.get("endpoint") ?? ""
      assert.equal(req.headers.authorization, "Bearer fixture")
      if (endpoint.endsWith("/saved")) {
        listed++
        res.writeHead(unavailable ? 503 : 200, { "content-type": "application/json" })
        res.end(JSON.stringify(["old-model", "new-model"]))
      } else if (endpoint.endsWith("/other")) {
        res.end(JSON.stringify(["other-model"]))
      } else {
        res.writeHead(404); res.end(JSON.stringify({ error: "catalog provider not found" }))
      }
    } else if (req.url === "/sessions/session/commands" && req.method === "POST") {
      let body = ""
      for await (const chunk of req) body += chunk
      const call = JSON.parse(body) as { name: string; args?: { model?: string; provider?: string } }
      assert.equal(call.name, "/model")
      const change = { model: call.args?.model ?? "", ...(call.args?.provider ? { provider: call.args.provider } : {}) }
      if (rejectChange) { res.writeHead(409); res.end(JSON.stringify({ error: "session must be idle" })); return }
      changes.push(change); session.model = change.model
      if (change.provider) { session.provider = change.provider; session.protocol = change.provider === "other" ? "chat_completions" : "responses" }
      const configuration = JSON.parse(await readFile(join(home, "config.json"), "utf8")) as { active: string; providers: Record<string, { model: string }> }
      configuration.active = session.provider
      configuration.providers[session.provider]!.model = session.model
      await writeFile(join(home, "config.json"), JSON.stringify(configuration))
      res.end(JSON.stringify({ result: { model: session.model, provider: session.provider, protocol: session.protocol } }))
    } else if (req.url === "/sessions/session/commands") {
      res.end(JSON.stringify([]))
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
    other: { baseUrl: `http://127.0.0.1:${address.port}/other`, apiKey: "other-key", model: "other-model", protocol: "chat_completions" },
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
    await until(() => painted.includes("session model") && painted.includes("current") && painted.includes(unavailable ? "could not list models" : "new-model"), "model picker")
    assert(painted.includes("current"))
  }
  await until(() => painted.includes("keep this conversation visible"), "chat")
  await open()
  painted = ""
  await enter("new-model")
  await until(() => changes.length === 1 && painted.includes("keep this conversation visible"), "selection returns to preserved chat")
  assert.deepEqual(changes, [{ model: "new-model", provider: "saved" }])
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
  assert.deepEqual(changes, [{ model: "new-model", provider: "saved" }, { model: "manual-model", provider: "saved" }])
  assert.equal(listed, 3)
  await open()
  await enter("change provider")
  await until(() => painted.includes("session provider") && painted.includes("chat_completions"), "provider picker")
  await enter("other")
  await until(() => painted.includes("other-model"), "other provider models")
  painted = ""
  stdin.write("\x1b")
  await until(() => painted.includes("keep this conversation visible"), "cancel provider change")
  assert.equal(changes.length, 2, "browsing providers must not save a change")
  await open()
  await enter("change provider")
  await until(() => painted.includes("chat_completions"), "provider picker again")
  await enter("other")
  await until(() => painted.includes("other-model"), "other provider models again")
  painted = ""
  stdin.write("\r")
  await until(() => painted.includes("daemon upgrade needed"), "old daemon requires upgrade before changing provider")
  assert.equal(changes.length, 2, "old daemon must not receive a model from another provider")
  supportsProviders = true
  rejectChange = true
  stdin.write("\r")
  await until(() => painted.includes("session must be idle"), "busy session rejects provider switch")
  assert.equal(changes.length, 2)
  rejectChange = false
  painted = ""
  stdin.write("\r")
  await until(() => changes.length === 3 && painted.includes("keep this conversation visible"), "provider selection preserves chat")
  assert.deepEqual(changes[2], { model: "other-model", provider: "other" })
  painted = ""
  await enter("/model")
  await until(() => painted.includes("albedo /model · other") && painted.includes("current"), "reopen on selected provider")
  assert(!painted.includes("manual-model"), "old provider's model must not leak into the new catalog")
  stdin.write("\x1b")
  assert.equal(streams, 1, "switching providers must not discard the mounted conversation")
  const defaults = JSON.parse(await readFile(join(home, "config.json"), "utf8")) as { active: string; providers: Record<string, { model: string }> }
  assert.equal(defaults.active, "other")
  assert.equal(defaults.providers.other?.model, "other-model")
  assert.equal(defaults.providers.saved?.model, "manual-model")
})
