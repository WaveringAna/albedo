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
