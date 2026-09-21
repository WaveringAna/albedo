import assert from "node:assert/strict"
import test from "node:test"
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { createServer } from "node:http"
import { modelNames, profiles, saveProvider } from "./profiles.js"

const fixture = { baseUrl: "https://example.test/v1", apiKey: "fixture-secret", model: "test-model", protocol: "responses" as const }
test("named providers persist privately, preserve other providers and migrate the previous config", async t => {
  const home = await mkdtemp(join(tmpdir(), "albedo-profiles-"))
  t.after(() => rm(home, { recursive: true, force: true }))
  assert.deepEqual(await profiles(home), { providers: {} })
  await writeFile(join(home, "config.json"), JSON.stringify(fixture))
  assert.equal((await profiles(home)).providers.default?.apiKey, fixture.apiKey)
  await saveProvider("local", { ...fixture, model: "local-model" }, home)
  let saved = await profiles(home)
  assert.equal(saved.active, "local")
  assert.equal(saved.providers.default?.model, "test-model")
  assert.equal(saved.providers.local?.model, "local-model")
  await saveProvider("local", { ...fixture, apiKey: "rotated-key" }, home)
  saved = await profiles(home)
  assert.equal(saved.providers.local?.apiKey, "rotated-key")
  assert.equal((await stat(home)).mode & 0o777, 0o700)
  assert.equal((await stat(join(home, "config.json"))).mode & 0o777, 0o600)
  await assert.rejects(saveProvider("bad name", fixture, home))
  await assert.rejects(saveProvider("bad", { ...fixture, baseUrl: "https://secret@example.test/v1" }, home))
  await writeFile(join(home, "config.json"), "broken private config")
  await assert.rejects(saveProvider("new", fixture, home), /invalid provider configuration/)
  assert.equal(await readFile(join(home, "config.json"), "utf8"), "broken private config")
})

test("model discovery sends the key only as a header and rejects redirects", async t => {
  const seen: string[] = []
  const server = createServer((req, res) => {
    seen.push(req.url!)
    assert.equal(req.headers.authorization, "Bearer fixture-secret")
    if (req.url === "/redirect/models") { res.writeHead(302, { location: "/leaked" }); res.end(); return }
    res.setHeader("content-type", "application/json")
    res.end(JSON.stringify({ data: [{ id: "z" }, { id: "a" }, { id: "a" }, { nope: true }, { id: "bad\nname" }] }))
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.close(); server.closeAllConnections() })
  const address = server.address()
  assert(address && typeof address !== "string")
  const base = `http://127.0.0.1:${address.port}`
  assert.deepEqual(await modelNames(base + "/v1/", fixture.apiKey, new AbortController().signal), ["a", "z"])
  await assert.rejects(modelNames(base + "/redirect", fixture.apiKey, new AbortController().signal))
  assert.deepEqual(seen, ["/v1/models", "/redirect/models"])
})
