import assert from "node:assert/strict"
import test, { after } from "node:test"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { PassThrough } from "node:stream"
import { createServer } from "node:http"
import { createElement } from "react"
import { render } from "ink"
const directory = await mkdtemp(join(tmpdir(), "albedo-login-"))
process.env.ALBEDO_HOME = directory
const { Login } = await import("./login.js")
const { profiles } = await import("../profiles.js")
after(() => rm(directory, { recursive: true, force: true }))
const until = async (ready: () => boolean): Promise<void> => {
  for (let i = 0; i < 400; i++) { if (ready()) return; await new Promise(resolve => setTimeout(resolve, 5)) }
  throw new Error("login screen did not reach expected state")
}

test("first login masks the key, discovers models and saves a named provider", async t => {
  const key = "private-key-never-painted"
  let authorization = ""
  const server = createServer((req, res) => {
    authorization = req.headers.authorization ?? ""
    res.setHeader("content-type", "application/json")
    res.end(JSON.stringify({ data: [{ id: "fixture-model" }] }))
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.close(); server.closeAllConnections() })
  const address = server.address()
  assert(address && typeof address !== "string")
  const baseUrl = `http://127.0.0.1:${address.port}/v1`
  const stdin = Object.assign(new PassThrough(), { isTTY: true, setRawMode: () => stdin, ref: () => stdin, unref: () => stdin }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), { isTTY: true, columns: 80, rows: 24 }) as unknown as NodeJS.WriteStream
  let painted = ""
  stdout.on("data", (chunk: Buffer) => { painted += chunk.toString() })
  let chosen: string | undefined
  const app = render(createElement(Login, { onDone: name => { chosen = name }, onCancel: () => assert.fail("unexpected cancel") }), { stdin, stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => app.unmount())
  const press = async (keys: string): Promise<void> => { (stdin as unknown as PassThrough).write(keys); await new Promise(resolve => setTimeout(resolve, 20)) }
  await until(() => painted.includes("provider name:"))
  await press("fixture"); await press("\r")
  await until(() => painted.includes("api base url:"))
  await press("\x15"); await press(baseUrl); await press("\r")
  await until(() => painted.includes("api key:"))
  await press(key); await press("\r")
  await until(() => painted.includes("api protocol"))
  await press("\r")
  await until(() => painted.includes("fixture-model"))
  await press("\r")
  await until(() => chosen !== undefined)
  assert.equal(chosen, "fixture")
  assert.equal(authorization, `Bearer ${key}`)
  const saved = await profiles()
  assert.equal(saved.active, "fixture")
  assert.deepEqual(saved.providers.fixture, { baseUrl, apiKey: key, model: "fixture-model", protocol: "responses" })
  assert(!painted.includes(key), "api key appeared in terminal output")
})
