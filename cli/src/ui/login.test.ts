import assert from "node:assert/strict"
import { createServer, type IncomingMessage, type ServerResponse } from "node:http"
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { PassThrough } from "node:stream"
import test, { after, type TestContext } from "node:test"
import { createElement } from "react"
import { render } from "ink"
import type { Connection } from "../daemon.js"

const directory = await mkdtemp(join(tmpdir(), "albedo-login-"))
process.env.ALBEDO_HOME = directory
process.env.ALBEDO_NO_BROWSER = "1"
const { Login } = await import("./login.js")
const { profiles } = await import("../profiles.js")
after(() => rm(directory, { recursive: true, force: true }))

const config = join(directory, "config.json")
const saved = { extension: "fixture", model: "fixture-model", protocol: "responses" }
const fixtureLogin = { provider: "fixture", label: "add fixture account", detail: "oauth · supports multiple accounts", protocol: "responses" }
const account = { provider: "fixture", id: "account-user:seat 1/slash", label: "ana@example.test", detail: "plus · seat 1", selected: false }
const escaped = `/auth/fixture/accounts/${encodeURIComponent(account.id)}`
const flow = { id: "flow", url: "https://auth.example/authorize?state=fixture" }

type Call = { method: string; url: string; body?: unknown }

const until = async (ready: () => boolean, what: string): Promise<void> => {
  for (let attempt = 0; attempt < 2000; attempt++) {
    if (ready()) return
    await new Promise(resolve => setTimeout(resolve, 5))
  }
  throw new Error(`login screen did not reach ${what}`)
}

/** A daemon that runs one fixture sign-in: waiting, then done (or failed) once input arrives. */
const fixtureDaemon = async (t: TestContext, options: { accounts?: typeof account[]; startDelayMs?: number; failure?: string } = {}) => {
  const calls: Call[] = []
  let accounts = options.accounts ?? []
  let status = { state: "waiting", message: "waiting for browser authorization" }
  const server = createServer(async (req, res) => {
    let text = ""
    for await (const chunk of req) text += chunk
    const url = req.url ?? ""
    const method = req.method ?? ""
    calls.push({ method, url, body: text ? JSON.parse(text) : undefined })
    res.setHeader("content-type", "application/json")
    const send = (value: unknown, status = 200) => { res.statusCode = status; res.end(JSON.stringify(value)) }
    if (method === "GET" && url === "/auth") return send({ logins: [fixtureLogin], accounts })
    if (method === "POST" && url === "/auth/fixture") {
      if (options.startDelayMs) await new Promise(resolve => setTimeout(resolve, options.startDelayMs))
      return send(flow, 201)
    }
    if (url === "/auth/logins/flow" && method === "GET") return send(status)
    if (url === "/auth/logins/flow" && method === "POST") {
      status = options.failure ? { state: "failed", message: options.failure } : { state: "done", message: "ana@example.test" }
      return send({ ok: true })
    }
    if (url === "/auth/logins/flow" && method === "DELETE") return send({ ok: true })
    if (url.startsWith("/auth/fixture/accounts/")) {
      const id = decodeURIComponent(url.slice("/auth/fixture/accounts/".length))
      accounts = method === "POST" ? accounts.map(entry => ({ ...entry, selected: entry.id === id })) : accounts.filter(entry => entry.id !== id)
      return send({ ok: true })
    }
    if (url.startsWith("/models/")) return send(["fixture-model"])
    res.statusCode = 404
    res.end(JSON.stringify({ error: "not found" }))
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.close(); server.closeAllConnections() })
  const address = server.address()
  assert(address && typeof address !== "string")
  const connection: Connection = { port: address.port, token: "daemon-token", pid: 1, version: 2 }
  return { calls, connection, accounts: () => accounts }
}

const terminal = () => {
  const stdin = Object.assign(new PassThrough(), { isTTY: true, setRawMode: () => stdin, ref: () => stdin, unref: () => stdin }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), { isTTY: true, columns: 80, rows: 24 }) as unknown as NodeJS.WriteStream
  let painted = ""
  stdout.on("data", (chunk: Buffer) => { painted += chunk.toString() })
  return { stdin, stdout, painted: () => painted, clear: () => { painted = "" } }
}

const screen = (t: TestContext, connection: Connection, handlers: { onDone?: (name: string) => void; onCancel?: () => void } = {}) => {
  const tty = terminal()
  const app = render(createElement(Login, { connection, onDone: name => handlers.onDone?.(name), onCancel: () => handlers.onCancel?.() }),
    { stdin: tty.stdin, stdout: tty.stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => { try { app.unmount() } catch {} })
  const press = async (keys: string): Promise<void> => {
    await app.waitUntilRenderFlush()
    ;(tty.stdin as unknown as PassThrough).write(keys)
    await app.waitUntilRenderFlush()
  }
  return { ...tty, app, press }
}

test("first login masks the key, discovers models and saves a named provider", async t => {
  await rm(config, { force: true })
  const key = "private-key-never-painted"
  let authorization = "", requested = ""
  const server = createServer((req, res) => {
    authorization = req.headers.authorization ?? ""
    requested = req.url ?? ""
    res.setHeader("content-type", "application/json")
    res.end(JSON.stringify(["fixture-model"]))
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.close(); server.closeAllConnections() })
  const address = server.address()
  assert(address && typeof address !== "string")
  const baseUrl = `http://127.0.0.1:${address.port}/v1`
  let chosen: string | undefined
  const { painted, press } = screen(t, { port: address.port, token: "daemon-token", pid: 1, version: 2 }, { onDone: name => { chosen = name }, onCancel: () => assert.fail("unexpected cancel") })
  await until(() => painted().includes("provider name:"), "the provider name step")
  await press("fixture"); await press("\r")
  await until(() => painted().includes("api base url:"), "the base url step")
  await press("\x15"); await press(baseUrl); await press("\r")
  await until(() => painted().includes("api key:"), "the api key step")
  await press(key); await press("\r")
  await until(() => painted().includes("api protocol"), "the protocol step")
  await press("\r")
  await until(() => painted().includes("fixture-model"), "the model list")
  await press("\r")
  await until(() => chosen !== undefined, "the save")
  assert.equal(chosen, "fixture")
  assert.equal(authorization, "Bearer daemon-token")
  assert.match(requested, /^\/models\/openai\?endpoint=/)
  assert.deepEqual((await profiles()).providers.fixture, { extension: "openai", baseUrl, apiKey: key, model: "fixture-model", protocol: "responses" })
  assert(!painted().includes(key), "api key appeared in terminal output")
})

test("a login provider typed as a name signs in through the daemon, pastes input, lists models and saves the profile", { timeout: 20_000 }, async t => {
  await rm(config, { force: true })
  const { calls, connection } = await fixtureDaemon(t)
  let chosen: string | undefined, cancelled = false
  const { painted, press } = screen(t, connection, { onDone: name => { chosen = name }, onCancel: () => { cancelled = true } })
  await until(() => painted().includes("provider name:"), "the provider name step")
  await until(() => painted().includes("fixture to sign in"), "the sign-in hint")
  await press("fixture"); await press("\r")
  await until(() => painted().includes(flow.url), "the authorization url")
  assert(calls.some(call => call.method === "POST" && call.url === "/auth/fixture"), "the daemon starts the sign-in")
  await until(() => painted().includes("waiting for browser authorization"), "the daemon status")
  await press("fixture-code"); await press("\r")
  await until(() => painted().includes("fixture-model"), "the model list")
  assert.deepEqual(calls.find(call => call.method === "POST" && call.url === "/auth/logins/flow")?.body, { input: "fixture-code" })
  assert(calls.some(call => call.method === "GET" && call.url === "/models/fixture"), "the models come from the daemon")
  await press("\r")
  await until(() => chosen !== undefined, "the save")
  assert.equal(chosen, "fixture")
  assert.deepEqual((await profiles()).providers.fixture, saved)
  assert(!cancelled && !calls.some(call => call.method === "DELETE" && call.url === "/auth/logins/flow"), "a finished sign-in is not cancelled")
})

test("login <provider> starts that provider's sign-in through the daemon", { timeout: 20_000 }, async t => {
  await rm(config, { force: true })
  const { calls, connection } = await fixtureDaemon(t)
  const tty = terminal()
  const app = render(createElement(Login, { connection, name: "fixture", onDone: () => assert.fail("unexpected save"), onCancel: () => assert.fail("unexpected cancel") }),
    { stdin: tty.stdin, stdout: tty.stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => { try { app.unmount() } catch {} })
  await until(() => tty.painted().includes(flow.url), "the authorization url")
  assert(calls.some(call => call.method === "POST" && call.url === "/auth/fixture"), "the named provider's sign-in starts")
})

test("the chooser lists daemon sign-ins and accounts, reads a provider without accounts signed out, and signs it in when chosen", { timeout: 20_000 }, async t => {
  await writeFile(config, JSON.stringify({ active: "work", providers: { work: saved } }))
  const { calls, connection } = await fixtureDaemon(t)
  let chosen: string | undefined, cancelled = false
  const { painted, press } = screen(t, connection, { onDone: name => { chosen = name }, onCancel: () => { cancelled = true } })
  await until(() => painted().includes("add fixture account"), "the sign-in row")
  assert(painted().includes("oauth · supports multiple accounts"), "the daemon detail is shown verbatim")
  assert(painted().includes("· signed out"), "a profile whose provider has no accounts reads signed out")
  await press("\r")
  await until(() => painted().includes(flow.url), "the authorization url")
  assert(calls.some(call => call.method === "POST" && call.url === "/auth/fixture"), "choosing it starts the sign-in")
  assert.equal(chosen, undefined, "starting a sign-in must not save a provider")
  await press("\x1b")
  await until(() => cancelled, "the cancel")
  assert.deepEqual(JSON.parse(await readFile(config, "utf8")).providers, { work: saved })
})

test("account rows select and remove through the daemon with escaped ids", { timeout: 20_000 }, async t => {
  await writeFile(config, JSON.stringify({ active: "work", providers: { work: saved } }))
  const { calls, connection, accounts } = await fixtureDaemon(t, { accounts: [account] })
  const { painted, clear, press } = screen(t, connection)
  await until(() => painted().includes(account.label), "the account row")
  assert(painted().includes(account.detail), "the daemon detail is shown verbatim")
  assert(!painted().includes("· selected"), "no account is selected yet")
  await press("\x1b[B"); await press("\r")
  await until(() => calls.some(call => call.method === "POST" && call.url === escaped), "the account selection")
  await until(() => painted().includes("· selected"), "the selection marker")
  assert(accounts()[0]!.selected)
  clear()
  await press("d")
  await until(() => calls.some(call => call.method === "DELETE" && call.url === escaped), "the account removal")
  await until(() => painted().includes("add fixture account") && !painted().includes(account.label), "the row to disappear")
  assert.deepEqual(accounts(), [])
})

test("a sign-in that starts after cancel is dropped, cancelled in the daemon and never polled", { timeout: 20_000 }, async t => {
  await rm(config, { force: true })
  const { calls, connection } = await fixtureDaemon(t, { startDelayMs: 800 })
  let cancelled = false
  const { painted, press } = screen(t, connection, { onCancel: () => { cancelled = true } })
  await until(() => painted().includes("provider name:"), "the provider name step")
  await press("fixture"); await press("\r")
  await until(() => painted().includes("starting sign-in"), "the sign-in step")
  await press("\x1b")
  await until(() => cancelled, "the cancel")
  await until(() => calls.some(call => call.method === "DELETE" && call.url === "/auth/logins/flow"), "the dropped sign-in to be cancelled")
  assert(!calls.some(call => call.method === "GET" && call.url === "/auth/logins/flow"), "a dropped sign-in is not polled")
  assert(!painted().includes(flow.url), "a dropped sign-in shows no authorization url")
})

test("unmounting a waiting sign-in cancels it in the daemon", { timeout: 20_000 }, async t => {
  await rm(config, { force: true })
  const { calls, connection } = await fixtureDaemon(t)
  const { painted, press, app } = screen(t, connection)
  await until(() => painted().includes("provider name:"), "the provider name step")
  await press("fixture"); await press("\r")
  await until(() => painted().includes("waiting for browser authorization"), "the daemon status")
  app.unmount()
  await until(() => calls.some(call => call.method === "DELETE" && call.url === "/auth/logins/flow"), "the cancel on unmount")
})

test("a failed sign-in shows the daemon reason and saves nothing", { timeout: 20_000 }, async t => {
  await rm(config, { force: true })
  const { calls, connection } = await fixtureDaemon(t, { failure: "fixture rejected the authorization code" })
  const { painted, press } = screen(t, connection)
  await until(() => painted().includes("provider name:"), "the provider name step")
  await press("fixture"); await press("\r")
  await until(() => painted().includes(flow.url), "the authorization url")
  await press("fixture-code"); await press("\r")
  await until(() => painted().includes("fixture rejected the authorization code"), "the failure reason")
  assert(!calls.some(call => call.url.startsWith("/models/")), "a failed sign-in lists no models")
  assert.deepEqual(await profiles(), { providers: {} })
})
