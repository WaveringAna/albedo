import assert from "node:assert/strict"
import test from "node:test"
import { spawn } from "node:child_process"
import { createServer } from "node:http"
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
test("installed launcher renders login outside the cli without changing the workspace", { timeout: 20_000 }, async t => {
  const temporary = await mkdtemp(join(tmpdir(), "albedo-launcher-"))
  t.after(() => rm(temporary, { recursive: true, force: true }))
  const home = join(temporary, "home")
  await mkdir(home)
  const terminal = join(temporary, "terminal.mjs")
  await writeFile(terminal, `
    import { createRequire } from "node:module";
    const require = createRequire(import.meta.url);
    process.on("exit", () => {
      const production = Object.keys(require.cache).some(path => path.endsWith("/react.production.js"));
      console.log("renderer:" + (production ? "production" : "development") + ";env:" + (process.env.NODE_ENV ?? "unset"));
    });
    Object.defineProperty(process.stdin, "isTTY", { value: true });
    Object.assign(process.stdin, { setRawMode() { return this } });
    Object.assign(process.stdout, { isTTY: true, columns: 120, rows: 24 });
  `)
  // A caller's JSX config must not override the installed CLI's compiler settings.
  await writeFile(join(temporary, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react" } }))
  const server = createServer((req, res) => {
    res.setHeader("content-type", "application/json")
    res.end(JSON.stringify(req.url === "/health" ? { version: 2 } : []))
  })
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
  t.after(() => { server.close(); server.closeAllConnections() })
  const address = server.address()
  assert(address && typeof address !== "string")
  await writeFile(join(home, "daemon.json"), JSON.stringify({ port: address.port, token: "fixture-token", pid: process.pid, version: 2 }))
  for (const [cwd, nodeEnv] of [[root, undefined], [temporary, "development"]] as const) {
    const env: NodeJS.ProcessEnv = { ...process.env, ALBEDO_HOME: home, TSX_DISABLE_CACHE: "1" }
    if (nodeEnv === undefined) delete env.NODE_ENV
    else env.NODE_ENV = nodeEnv
    const child = spawn(process.execPath, ["--import", terminal, join(root, "cli/bin/albedo.mjs")], {
      cwd, env, stdio: "pipe",
    })
    t.after(() => { if (child.exitCode === null) child.kill() })
    let output = ""
    let phase = "login"
    child.stdout.on("data", (chunk: Buffer) => {
      output += chunk.toString()
      if (phase === "login" && output.includes("provider name:")) {
        phase = "sessions"
        child.stdin.write("\x1b")
      } else if (phase === "sessions" && output.includes("new coding session") && output.includes(cwd)) {
        phase = "done"
        child.stdin.write("\x03")
      }
    })
    child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString() })
    const code = await new Promise<number | null>((resolve, reject) => {
      child.on("error", reject)
      child.on("close", resolve)
    })
    assert.equal(code, 0, output)
    assert.equal(phase, "done", output)
    assert(output.includes(`renderer:${nodeEnv ?? "production"};env:${nodeEnv ?? "unset"}`), output)
    assert(!output.includes("React is not defined"), output)
  }
})
