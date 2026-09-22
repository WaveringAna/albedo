import assert from "node:assert/strict"
import { createServer } from "node:http"
import { PassThrough } from "node:stream"
import test from "node:test"
import { render } from "ink"
import { App } from "./app.js"

const until = async (ready: () => boolean, what: string): Promise<void> => {
  for (let attempt = 0; attempt < 400; attempt++) {
    if (ready()) return
    await new Promise(resolve => setTimeout(resolve, 5))
  }
  throw new Error(`timed out: ${what}`)
}

const terminal = () => {
  const stdin = Object.assign(new PassThrough(), { isTTY: true, setRawMode: () => stdin, ref: () => stdin, unref: () => stdin }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), { isTTY: true, columns: 120, rows: 40 }) as unknown as NodeJS.WriteStream
  let painted = ""
  stdout.on("data", (chunk: Buffer) => { painted += chunk.toString() })
  return { stdin, stdout, painted: () => painted, clear: () => { painted = "" } }
}

const session = { id: "session", title: "existing conversation", workspace: "/tmp", provider: "fixture", model: "fixture-model", protocol: "responses" }
const extension = (enabled: boolean) => ({
  name: "memory-kit",
  description: "Adds durable project memory and helper tools",
  enabled,
  context: true,
  plugins: ["context", "tool", "compaction"],
  tools: ["remember", "recall"],
  python_modules: ["memory_store"],
  requires: ["sqlite", "workspace-index"],
})

test("/extensions shows plugin capabilities and confirms retryable session toggles without remounting chat", { timeout: 15_000 }, async t => {
  let streams = 0, posts = 0, enabled = true
  const server = createServer(async (req, res) => {
    res.setHeader("content-type", "application/json")
    if (req.url === "/health") res.end(JSON.stringify({ capabilities: ["session_extensions"] }))
    else if (req.url === "/sessions/session/extensions" && req.method === "GET") res.end(JSON.stringify([extension(enabled)]))
    else if (req.url === "/sessions/session/extensions" && req.method === "POST") {
      let body = ""
      for await (const chunk of req) body += chunk
      assert.deepEqual(JSON.parse(body), { name: "memory-kit", enabled: false })
      posts++
      if (posts === 1) { res.writeHead(409); res.end(JSON.stringify({ error: "cannot reload extensions while a run is active; stop the run and retry" })); return }
      enabled = false
      res.end(JSON.stringify([extension(enabled)]))
    } else if (req.url?.startsWith("/sessions/session/stream")) {
      streams++
      res.writeHead(200, { "content-type": "text/event-stream" })
      res.write(`data: ${JSON.stringify({ cursor: 1, events: [
        { type: "message", text: "preserved conversation" },
        { type: "usage", model: "fixture-model", recordedAt: Date.now(), promptTokens: 100, cachedPromptTokens: 50, totalTokens: 110 },
      ] })}\n\n`)
    } else if (req.url === "/sessions/session/status") res.end(JSON.stringify({ running: false, idle: true }))
    else { res.writeHead(404); res.end(JSON.stringify({ error: `unexpected ${req.method} ${req.url}` })) }
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.closeAllConnections(); server.close() })
  const address = server.address()
  assert(address && typeof address !== "string")
  const tty = terminal()
  const app = render(<App connection={{ port: address.port, token: "fixture", pid: 1, version: 2 }} initial={session} workspace="/tmp" quit={() => {}} />, { stdin: tty.stdin, stdout: tty.stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => app.unmount())
  const write = async (input: string): Promise<void> => { tty.stdin.write(input); await app.waitUntilRenderFlush() }
  const enter = async (input = ""): Promise<void> => { if (input) await write(input); await write("\r") }

  await until(() => tty.painted().includes("preserved conversation") && tty.painted().includes("cached 50%"), "chat and usage")
  tty.clear()
  await enter("/extensions")
  await until(() => tty.painted().includes("memory-kit") && tty.painted().includes("workspace-index"), "extension viewer")
  assert.match(tty.painted(), /on\s+memory-kit/)
  assert(tty.painted().includes("context · tools (remember, recall) · python modules (memory_store)"))
  assert(tty.painted().includes("bust prompt-cache reuse"))
  assert(tty.painted().includes("plugins: context, tool, compaction"))

  tty.clear()
  await enter()
  await until(() => tty.painted().includes("reload this session's workers?"), "toggle confirmation")
  assert.equal(posts, 0, "selecting an extension must not change it before confirmation")
  await enter()
  await until(() => tty.painted().includes("stop the run and retry"), "actionable reload error")
  assert.equal(posts, 1)
  tty.clear()
  await enter()
  await until(() => posts === 2 && tty.painted().includes("off") && tty.painted().includes("memory-kit"), "successful retry")
  assert.equal(streams, 1, "extension changes must keep the chat stream mounted")

  tty.clear()
  await write("\x1b")
  await until(() => tty.painted().includes("preserved conversation") && tty.painted().includes("cached —"), "return to preserved chat with cleared usage")
  assert.equal(streams, 1)
})

test("/extensions preflights old daemons and escape returns to the mounted chat", { timeout: 10_000 }, async t => {
  let streams = 0, extensionRequests = 0
  const server = createServer((req, res) => {
    if (req.url === "/health") res.end(JSON.stringify({ capabilities: [] }))
    else if (req.url === "/sessions/session/extensions") { extensionRequests++; res.end("[]") }
    else if (req.url?.startsWith("/sessions/session/stream")) {
      streams++
      res.writeHead(200, { "content-type": "text/event-stream" })
      res.write(`data: ${JSON.stringify({ cursor: 1, events: [{ type: "message", text: "older daemon chat" }] })}\n\n`)
    } else if (req.url === "/sessions/session/status") res.end(JSON.stringify({ running: false, idle: true }))
    else { res.writeHead(404); res.end("{}") }
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.closeAllConnections(); server.close() })
  const address = server.address()
  assert(address && typeof address !== "string")
  const tty = terminal()
  const app = render(<App connection={{ port: address.port, token: "fixture", pid: 1, version: 2 }} initial={session} workspace="/tmp" quit={() => {}} />, { stdin: tty.stdin, stdout: tty.stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => app.unmount())

  await until(() => tty.painted().includes("older daemon chat"), "chat")
  tty.clear()
  tty.stdin.write("/extensions")
  await app.waitUntilRenderFlush()
  tty.stdin.write("\r")
  await until(() => tty.painted().includes("daemon upgrade needed for /extensions"), "upgrade explanation")
  assert(tty.painted().includes("albedo daemon --stop"))
  assert.equal(extensionRequests, 0, "unsupported daemons must not receive extension requests")
  tty.clear()
  tty.stdin.write("\x1b")
  await until(() => tty.painted().includes("older daemon chat"), "escape returns to chat")
  assert.equal(streams, 1)
})
