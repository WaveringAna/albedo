import assert from "node:assert/strict"
import { createServer } from "node:http"
import { PassThrough } from "node:stream"
import test from "node:test"
import { render } from "ink"
import { App } from "./app.js"
import { actionArgs, parsePage } from "../page.js"

const until = async (ready: () => boolean, what: string): Promise<void> => {
  for (let attempt = 0; attempt < 400; attempt++) {
    if (ready()) return
    await new Promise(resolve => setTimeout(resolve, 5))
  }
  throw new Error(`timed out: ${what}`)
}

const plain = (text: string): string => text.replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, "")

const terminal = (columns: number) => {
  const stdin = Object.assign(new PassThrough(), { isTTY: true, setRawMode: () => stdin, ref: () => stdin, unref: () => stdin }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), { isTTY: true, columns, rows: 30 }) as unknown as NodeJS.WriteStream
  let painted = ""
  stdout.on("data", (chunk: Buffer) => { painted += chunk.toString() })
  return { stdin, stdout, painted: () => plain(painted), clear: () => { painted = "" } }
}

const session = { id: "session", title: "work", workspace: "/tmp", provider: "fixture", model: "fixture-model", protocol: "responses" }

type Item = { id: number; title: string; status: string }

/** A daemon with one page command, /work, over an in-memory ledger. */
const daemon = async (items: Item[]) => {
  const calls: Record<string, unknown>[] = []
  const tone = (status: string) => ({ active: "active", blocked: "warning", done: "muted", cancelled: "muted" })[status] ?? "plain"
  const page = () => ({ page: {
    title: "work", summary: `${items.length} items`, empty: "nothing tracked yet",
    rows: items.map(item => ({ id: String(item.id), text: item.title, badge: item.status, tone: tone(item.status) })),
    actions: [
      { key: "a", label: "add", run: "add", row: false, confirm: false, input: "text", prompt: "title", prefill: false },
      { key: "d", label: "done", run: "status", row: true, confirm: false, input: "value", value: "done" },
      { key: "x", label: "remove", run: "remove", row: true, confirm: true, input: "none" },
    ],
    glance: { title: "work", rows: items.filter(item => item.status !== "done").map(item => ({ id: String(item.id), text: item.title, badge: item.status, tone: tone(item.status) })) },
  } })
  const server = createServer(async (req, res) => {
    res.setHeader("content-type", "application/json")
    if (req.url === "/health") return res.end(JSON.stringify({ capabilities: ["session_commands"] }))
    if (req.url === "/sessions/session/commands" && req.method === "GET")
      return res.end(JSON.stringify([{ name: "/work", description: "the work ledger", method: "work", arguments: [], modelCallable: false, userTurn: false, page: true }]))
    if (req.url === "/sessions/session/commands" && req.method === "POST") {
      let body = ""
      for await (const chunk of req) body += chunk
      const call = JSON.parse(body) as { args?: Record<string, string> }
      const args = call.args ?? {}
      if (args.action) calls.push(args)
      const [first, ...rest] = (args.details ?? "").split(" ")
      if (args.action === "add") items.push({ id: items.length + 1, title: args.details!, status: "open" })
      if (args.action === "status") items.find(item => String(item.id) === first)!.status = rest.join(" ")
      if (args.action === "remove") items.splice(items.findIndex(item => String(item.id) === first), 1)
      return res.end(JSON.stringify({ result: args.action ? { message: `${args.action} ok; the agent will be told` } : page() }))
    }
    if (req.url?.startsWith("/sessions/session/stream")) {
      res.writeHead(200, { "content-type": "text/event-stream" })
      return void res.write(`data: ${JSON.stringify({ cursor: 1, events: [{ type: "message", text: "a reply worth timestamping", timestamp: new Date(2026, 0, 1, 12, 34, 56).getTime() }] })}\n\n`)
    }
    if (req.url === "/sessions/session/status") return res.end(JSON.stringify({ running: false, idle: true }))
    res.writeHead(404); res.end("{}")
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  const address = server.address()
  assert(address && typeof address !== "string")
  return { port: address.port, calls, close: () => { server.closeAllConnections(); server.close() } }
}

test("page documents parse defensively and actions join row id and input", () => {
  assert.equal(parsePage({ message: "not a page" }), undefined)
  const page = parsePage({ page: { title: "work", rows: [{ id: "1", text: "a", badge: "open", tone: "shiny" }, { id: 2 }],
    actions: [{ key: "ab", label: "bad", run: "x" }, { key: "c", label: "pick", run: "status", row: true, input: "choice", options: [] },
      { key: "d", label: "done", run: "status", row: true, input: "value", value: "done" }] } })!
  assert.deepEqual(page.rows, [{ id: "1", text: "a", badge: "open", tone: "plain" }])
  assert.deepEqual(page.actions.map(action => action.key), ["d"])
  assert.deepEqual(actionArgs(page.actions[0]!, page.rows[0]), { action: "status", details: "1 done" })
  assert.deepEqual(actionArgs({ key: "a", label: "add", run: "add", row: false, confirm: false, input: "text", prompt: "title", prefill: false }, page.rows[0], "  buy milk "),
    { action: "add", details: "buy milk" })
})

test("a page command opens its page, runs its actions, and feeds the sidebar glance", { timeout: 15_000 }, async t => {
  const fake = await daemon([{ id: 1, title: "fix the flaky test", status: "active" }])
  t.after(fake.close)
  const tty = terminal(140)
  const app = render(<App connection={{ port: fake.port, token: "fixture", pid: 1, version: 2 }} initial={session} workspace="/tmp" quit={() => {}} />,
    { stdin: tty.stdin, stdout: tty.stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => app.unmount())
  const write = async (input: string): Promise<void> => { tty.stdin.write(input); await app.waitUntilRenderFlush() }

  // The glance sits in the margin beside the 100-column body, and the clock
  // moves in beside it instead of sitting under it.
  await until(() => tty.painted().includes("fix the flaky test") && tty.painted().includes("12:34:56"), "sidebar glance")
  const frame = tty.painted().split("\n")
  const clockLine = frame.findLast(line => line.includes("12:34:56"))!
  assert(clockLine.indexOf("12:34:56") < 140 - 2 - 16, clockLine)
  assert(frame.some(line => /work · 1/.test(line)))

  await write("/work"); await write("\r")
  await until(() => tty.painted().includes("albedo /work · 1 items"), "work page")
  assert(tty.painted().includes("a add · d done · x remove · esc return to chat"))

  tty.clear()
  await write("a"); await write("write the docs"); await write("\r")
  await until(() => tty.painted().includes("add ok; the agent will be told") && tty.painted().includes("write the docs"), "added row")
  assert.deepEqual(fake.calls.at(-1), { action: "add", details: "write the docs" })

  await write("d")
  await until(() => fake.calls.length === 2, "done action")
  assert.deepEqual(fake.calls.at(-1), { action: "status", details: "1 done" })

  tty.clear()
  await write("x")
  await until(() => tty.painted().includes("remove #1 fix the flaky test? enter confirm"), "remove confirmation")
  await write("\r")
  await until(() => fake.calls.length === 3, "remove action")
  assert.deepEqual(fake.calls.at(-1), { action: "remove", details: "1" })

  tty.clear()
  await write("\u001b")
  await until(() => tty.painted().includes("write the docs") && tty.painted().includes("a reply worth timestamping"), "back to chat with a fresh glance")
})

test("without margin room the glance collapses to a header count", { timeout: 15_000 }, async t => {
  const fake = await daemon([{ id: 1, title: "fix the flaky test", status: "open" }])
  t.after(fake.close)
  const tty = terminal(100)
  const app = render(<App connection={{ port: fake.port, token: "fixture", pid: 1, version: 2 }} initial={session} workspace="/tmp" quit={() => {}} />,
    { stdin: tty.stdin, stdout: tty.stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => app.unmount())
  await until(() => /work 1/.test(tty.painted()) && tty.painted().includes("12:34:56"), "header count")
  assert(!tty.painted().includes("fix the flaky test"))
})
