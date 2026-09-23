import assert from "node:assert/strict"
import { createServer, type ServerResponse } from "node:http"
import { PassThrough } from "node:stream"
import test from "node:test"
import { render } from "ink"
import { App } from "./app.js"

const until = async (ready: () => boolean): Promise<void> => {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (ready()) return
    await new Promise(resolve => setTimeout(resolve, 5))
  }
  throw new Error("session picker did not render")
}

test("session picker shows the user-message title instead of an id hash", async t => {
  const id = "deadbeefcafebabefeedface"
  const title = "fix the unicode session picker"
  const server = createServer((_request, response) => {
    response.setHeader("content-type", "application/json")
    response.end(JSON.stringify([{
      id,
      title,
      workspace: "/tmp/project",
      provider: "fixture",
      model: "fixture-model",
      protocol: "responses",
    }, {
      id: "legacy", workspace: "/tmp/legacy", provider: "fixture", model: "legacy-model", protocol: "responses",
    }]))
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.close(); server.closeAllConnections() })
  const address = server.address()
  assert(address && typeof address !== "string")

  const stdin = Object.assign(new PassThrough(), {
    isTTY: true,
    setRawMode: () => stdin,
    ref: () => stdin,
    unref: () => stdin,
  }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), {
    isTTY: true,
    columns: 100,
    rows: 24,
  }) as unknown as NodeJS.WriteStream
  let painted = ""
  stdout.on("data", (chunk: Buffer) => { painted += chunk.toString() })

  const app = render(
    <App
      connection={{ port: address.port, token: "fixture-token", pid: 1, version: 2 }}
      workspace="/tmp/project"
      quit={() => {}}
    />,
    { stdin, stdout, patchConsole: false, exitOnCtrlC: false },
  )
  t.after(() => app.unmount())

  await until(() => painted.includes(title))
  assert(!painted.includes(id.slice(0, 8)), "session id leaked into the picker label")
  assert(painted.includes(`> ${title}`), "the most recent session should be selected after loading")
  assert(painted.includes("daemon upgrade needed"))
  assert(painted.includes("session · label unavailable"))
  assert(painted.includes("restarting clears python variables"))
})


test("returning to sessions keeps the active row selected before and after a reordered refresh", async t => {
  const current = { id: "current", title: "current conversation", workspace: "/tmp", provider: "fixture", model: "fixture-model", protocol: "responses" }
  const newer = { ...current, id: "newer", title: "another newer conversation" }
  let listReply: ServerResponse | undefined
  const server = createServer((req, res) => {
    if (req.url === "/sessions") listReply = res
    else if (req.url?.includes("/stream")) {
      res.writeHead(200, { "content-type": "text/event-stream" })
      res.write(`data: ${JSON.stringify({ cursor: 1, events: [{ type: "message", text: `chat for ${req.url.split("/")[2]}` }] })}\n\n`)
    } else if (req.url?.endsWith("/status")) res.end(JSON.stringify({ running: false, idle: true }))
    else { res.writeHead(404); res.end("{}") }
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.closeAllConnections(); server.close() })
  const address = server.address()
  assert(address && typeof address !== "string")
  const stdin = Object.assign(new PassThrough(), { isTTY: true, setRawMode: () => stdin, ref: () => stdin, unref: () => stdin }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), { isTTY: true, columns: 120, rows: 40 }) as unknown as NodeJS.WriteStream
  let painted = ""
  stdout.on("data", (chunk: Buffer) => { painted += chunk.toString() })
  const app = render(<App connection={{ port: address.port, token: "fixture", pid: 1, version: 2 }} initial={current} workspace="/tmp" quit={() => {}} />, { stdin, stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => app.unmount())
  const refreshList = (items: typeof current[]): void => {
    assert(listReply)
    listReply.end(JSON.stringify(items)); listReply = undefined
  }
  const openPicker = async (): Promise<void> => {
    painted = ""
    stdin.write("/sessions")
    await app.waitUntilRenderFlush()
    stdin.write("\r")
    await until(() => !!listReply && painted.includes("albedo  sessions"))
  }
  await until(() => painted.includes("chat for current"))
  await openPicker()
  assert(painted.includes(`> ${current.title}`), "active session must be available even while the list is loading")
  assert(!painted.includes("> new coding session"))
  painted = ""
  refreshList([newer, current])
  await until(() => painted.includes(newer.title))
  assert(painted.includes(`> ${current.title}`), "recency reordering must not move the cursor")
  painted = ""
  stdin.write("\x1b[A")
  await app.waitUntilRenderFlush()
  stdin.write("\r")
  await until(() => painted.includes("chat for newer"))
  await openPicker()
  assert(painted.includes(`> ${newer.title}`), "returning must select the session just opened")
  refreshList([current, newer])
})


test("/tree keeps chat mounted, confirms explicitly, cancels, and switches only after a successful fork", async t => {
  const current = { id: "current", title: "current conversation", workspace: "/tmp", provider: "fixture", model: "fixture-model", protocol: "responses" }
  const branch = { ...current, id: "branch", title: "branch checkpoint" }
  let currentStreams = 0
  let branchStreams = 0
  let forks = 0
  const server = createServer((req, res) => {
    res.setHeader("content-type", "application/json")
    if (req.url === "/health") res.end(JSON.stringify({ capabilities: ["session_tree"] }))
    else if (req.url === "/sessions/current/tree?after=0&limit=50") res.end(JSON.stringify({ items: [
      { id: 11, type: "user", preview: "first prompt" },
      { id: 12, type: "assistant", preview: "first answer" },
      { id: 13, type: "tool", preview: "call python" },
    ], nextCursor: 13, hasMore: false }))
    else if (req.url === "/sessions/current/fork" && req.method === "POST") {
      forks += 1
      let body = ""
      req.on("data", chunk => { body += chunk })
      req.on("end", () => {
        assert.deepEqual(JSON.parse(body), { checkpoint: 11 })
        res.end(JSON.stringify(branch))
      })
    } else if (req.url?.includes("/sessions/current/stream")) {
      currentStreams += 1
      res.writeHead(200, { "content-type": "text/event-stream" })
      res.write(`data: ${JSON.stringify({ cursor: 1, events: [{ type: "message", text: "mounted current chat" }] })}\n\n`)
    } else if (req.url?.includes("/sessions/branch/stream")) {
      branchStreams += 1
      res.writeHead(200, { "content-type": "text/event-stream" })
      res.write(`data: ${JSON.stringify({ cursor: 1, events: [{ type: "message", text: "branched chat" }] })}\n\n`)
    } else if (req.url?.endsWith("/status")) res.end(JSON.stringify({ running: false, idle: true }))
    else { res.writeHead(404); res.end(JSON.stringify({ error: "not found" })) }
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.closeAllConnections(); server.close() })
  const address = server.address()
  assert(address && typeof address !== "string")
  const stdin = Object.assign(new PassThrough(), { isTTY: true, setRawMode: () => stdin, ref: () => stdin, unref: () => stdin }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), { isTTY: true, columns: 120, rows: 40 }) as unknown as NodeJS.WriteStream
  let painted = ""
  stdout.on("data", (chunk: Buffer) => { painted += chunk.toString() })
  const app = render(<App connection={{ port: address.port, token: "fixture", pid: 1, version: 2 }} initial={current} workspace="/tmp" quit={() => {}} />, { stdin, stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => app.unmount())

  await until(() => painted.includes("mounted current chat"))
  painted = ""
  stdin.write("/tree")
  await app.waitUntilRenderFlush()
  stdin.write("\r")
  await until(() => painted.includes("first prompt") && painted.includes("call python"))
  assert.equal(currentStreams, 1, "opening tree must not remount the current chat")
  stdin.write("\r")
  await until(() => painted.includes("fresh python namespace"))
  assert.equal(forks, 0, "first enter only confirms")
  stdin.write("\x1b")
  await app.waitUntilRenderFlush()
  assert.equal(forks, 0)
  stdin.write("\x1b")
  await until(() => painted.includes("mounted current chat"))
  assert.equal(currentStreams, 1, "cancel must reveal the still-mounted chat")

  painted = ""
  stdin.write("/tree")
  await app.waitUntilRenderFlush()
  stdin.write("\r")
  await until(() => painted.includes("first prompt"))
  stdin.write("\r")
  await app.waitUntilRenderFlush()
  await new Promise(resolve => setTimeout(resolve, 25))
  for (let attempt = 0; attempt < 10 && forks === 0; attempt++) {
    stdin.write("\r")
    await app.waitUntilRenderFlush()
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  assert.equal(forks, 1, `fork request missing; output: ${painted}`)
  await until(() => painted.includes("branched chat"))
  assert.equal(currentStreams, 1)
  assert.equal(branchStreams, 1)
})


test("/reload suggests models and reports completion in the chat", async t => {
  const current = { id: "current", title: "current", workspace: "/tmp", provider: "fixture", model: "fixture-model", protocol: "responses" }
  let reloads = 0
  const server = createServer((req, res) => {
    res.setHeader("content-type", "application/json")
    if (req.url === "/health") res.end(JSON.stringify({ capabilities: ["session_commands"] }))
    else if (req.url === "/sessions/current/commands" && req.method === "GET") res.end(JSON.stringify([{
      name: "/reload", description: "Reload cached runtime data", method: "reload", modelCallable: false, userTurn: false,
      arguments: [{ name: "target", description: "models, session, or omit for both", required: false, choices: ["models", "session"] }],
    }]))
    else if (req.url === "/sessions/current/commands" && req.method === "POST") {
      let body = ""
      req.on("data", chunk => { body += chunk })
      req.on("end", () => {
        assert.deepEqual(JSON.parse(body), { name: "/reload", arguments: "" })
        reloads++
        setTimeout(() => res.end(JSON.stringify({ result: {
          reloaded: "models+session",
          message: "Models catalog reloaded; extension context, skills catalog, and session commands rescanned.",
        } })), 150)
      })
    } else if (req.url?.includes("/stream")) {
      res.writeHead(200, { "content-type": "text/event-stream" })
      res.write(`data: ${JSON.stringify({ cursor: 1, events: [{ type: "message", text: "ready to reload" }] })}\n\n`)
    } else if (req.url?.endsWith("/status")) res.end(JSON.stringify({ running: false, idle: true }))
    else { res.writeHead(404); res.end(JSON.stringify({ error: "not found" })) }
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.closeAllConnections(); server.close() })
  const address = server.address()
  assert(address && typeof address !== "string")
  const stdin = Object.assign(new PassThrough(), { isTTY: true, setRawMode: () => stdin, ref: () => stdin, unref: () => stdin }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), { isTTY: true, columns: 120, rows: 40 }) as unknown as NodeJS.WriteStream
  let painted = ""
  stdout.on("data", (chunk: Buffer) => { painted += chunk.toString() })
  const app = render(<App connection={{ port: address.port, token: "fixture", pid: 1, version: 2 }} initial={current} workspace="/tmp" quit={() => {}} />, { stdin, stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => app.unmount())

  await until(() => painted.includes("ready to reload"))
  painted = ""
  stdin.write("/reload")
  await until(() => painted.includes("/reload") && painted.includes("Reload cached runtime data"))
  stdin.write("\r")
  await until(() => painted.includes("Reloading…"))
  await until(() => reloads === 1 && painted.includes("Models catalog reloaded; extension context, skills catalog, and session commands rescanned."))
})
