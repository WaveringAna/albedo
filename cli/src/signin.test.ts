import assert from "node:assert/strict"
import { createServer, type IncomingMessage, type ServerResponse } from "node:http"
import test, { type TestContext } from "node:test"
import { cancelSignIn, openBrowser, pollSignIn, provideSignInInput, removeAccount, selectAccount, signInStatus, signIns, startSignIn, type Launcher } from "./signin.js"

type Call = { method: string; url: string; body?: unknown; authorization?: string }
const read = async (req: IncomingMessage): Promise<unknown> => {
  let text = ""
  for await (const chunk of req) text += chunk
  return text ? JSON.parse(text) : undefined
}
const daemon = async (t: TestContext, route: (call: Call, res: ServerResponse) => boolean) => {
  const calls: Call[] = []
  const server = createServer(async (req, res) => {
    const call: Call = { method: req.method ?? "", url: req.url ?? "", body: await read(req), authorization: req.headers.authorization }
    calls.push(call)
    res.setHeader("content-type", "application/json")
    if (!route(call, res)) { res.statusCode = 404; res.end(JSON.stringify({ error: "not found" })) }
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.close(); server.closeAllConnections() })
  const address = server.address()
  assert(address && typeof address !== "string")
  return { calls, connection: { port: address.port, token: "daemon-token", pid: 1, version: 2 } }
}
const send = (res: ServerResponse, value: unknown, status = 200): true => {
  res.statusCode = status
  res.end(JSON.stringify(value))
  return true
}

test("sign-in routes use the daemon token, escaped ids and the documented shapes", async t => {
  const account = "/auth/codex/accounts/account-user%3Aseat%201%2Ftwo"
  const { calls, connection } = await daemon(t, (call, res) =>
    call.method === "GET" && call.url === "/auth"
      ? send(res, {
        logins: [{ provider: "codex", label: "add chatgpt codex account", detail: "oauth · supports multiple accounts", protocol: "responses" }],
        accounts: [{ provider: "codex", id: "account-user:seat 1/two", label: "ana@example.test", detail: "plus", selected: false }],
      })
      : call.method === "POST" && call.url === "/auth/codex" ? send(res, { id: "flow", url: "https://auth.example/authorize?state=x" }, 201)
      : call.method === "GET" && call.url === "/auth/logins/flow" ? send(res, { state: "waiting", message: "waiting for browser authorization" })
      : call.method === "POST" && call.url === "/auth/logins/flow" ? send(res, { ok: true })
      : call.method === "DELETE" && call.url === "/auth/logins/flow" ? send(res, { ok: true })
      : (call.method === "POST" || call.method === "DELETE") && call.url === account ? send(res, { ok: true })
      : false)
  assert.deepEqual(await signIns(connection), {
    logins: [{ provider: "codex", label: "add chatgpt codex account", detail: "oauth · supports multiple accounts", protocol: "responses" }],
    accounts: [{ provider: "codex", id: "account-user:seat 1/two", label: "ana@example.test", detail: "plus", selected: false }],
  })
  assert.deepEqual(await startSignIn(connection, "codex"), { id: "flow", url: "https://auth.example/authorize?state=x" })
  assert.deepEqual(await signInStatus(connection, "flow"), { state: "waiting", message: "waiting for browser authorization" })
  await provideSignInInput(connection, "flow", "http://localhost:1455/auth/callback?code=a&state=b")
  await cancelSignIn(connection, "flow")
  await selectAccount(connection, "codex", "account-user:seat 1/two")
  await removeAccount(connection, "codex", "account-user:seat 1/two")
  assert.deepEqual(calls.map(call => [call.method, call.url]), [
    ["GET", "/auth"],
    ["POST", "/auth/codex"],
    ["GET", "/auth/logins/flow"],
    ["POST", "/auth/logins/flow"],
    ["DELETE", "/auth/logins/flow"],
    ["POST", account],
    ["DELETE", account],
  ])
  assert.deepEqual(calls[3]!.body, { input: "http://localhost:1455/auth/callback?code=a&state=b" })
  assert(calls.every(call => call.authorization === "Bearer daemon-token"), "every route carries the daemon token")
})

test("a daemon that answers something other than the auth object reads as no sign-ins", async t => {
  const { connection } = await daemon(t, (_call, res) => send(res, []))
  assert.deepEqual(await signIns(connection), { logins: [], accounts: [] })
})

test("polling reports every daemon message until the sign-in settles", async t => {
  let polls = 0
  const { connection } = await daemon(t, (call, res) => {
    if (call.url !== "/auth/logins/flow") return false
    polls++
    return polls < 3 ? send(res, { state: "waiting", message: `waiting ${polls}` }) : send(res, { state: "done", message: "ana@example.test" })
  })
  const seen: string[] = []
  const status = await pollSignIn(connection, "flow", status => seen.push(status.message))
  assert.deepEqual(seen, ["waiting 1", "waiting 2", "ana@example.test"])
  assert.equal(status?.state, "done")
  assert.equal(polls, 3)
})

test("aborting the watch stops the polling instead of spinning", async t => {
  let polls = 0
  const { connection } = await daemon(t, (call, res) => {
    if (call.url !== "/auth/logins/flow") return false
    polls++
    return send(res, { state: "waiting", message: "waiting for browser authorization" })
  })
  assert.equal(await pollSignIn(connection, "flow", () => {}, AbortSignal.timeout(400)), undefined)
  assert(polls >= 1 && polls <= 3, `expected about one poll per 300ms, saw ${polls} in 400ms`)
})

test("the browser opens through the platform opener and never under ALBEDO_NO_BROWSER", () => {
  const opened: { command: string; args: string[]; options: unknown }[] = []
  const opener: Launcher = (command, args, options) => { opened.push({ command, args, options }); return { on: () => {}, unref: () => {} } }
  const previous = process.env.ALBEDO_NO_BROWSER
  try {
    process.env.ALBEDO_NO_BROWSER = "1"
    openBrowser("https://auth.example/authorize?state=x", opener)
    assert.equal(opened.length, 0, "ALBEDO_NO_BROWSER must not open a browser")
    delete process.env.ALBEDO_NO_BROWSER
    openBrowser("https://auth.example/authorize?state=x", opener)
    assert.equal(opened.length, 1)
    assert(opened[0]!.args.includes("https://auth.example/authorize?state=x"))
    assert(["open", "cmd", "xdg-open"].includes(opened[0]!.command), opened[0]!.command)
    assert.deepEqual(opened[0]!.options, { detached: true, stdio: "ignore" })
  } finally {
    if (previous === undefined) delete process.env.ALBEDO_NO_BROWSER
    else process.env.ALBEDO_NO_BROWSER = previous
  }
})
