#!/usr/bin/env node
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import { spawnSync } from "node:child_process"

const dir = dirname(fileURLToPath(import.meta.url))
const goBinary = join(dir, "albedo")

const isTsTest = process.env.ALBEDO_USE_TS === "1" || process.execArgv.some(arg => arg.includes("terminal.mjs"))

if (existsSync(goBinary) && !isTsTest) {
  const result = spawnSync(goBinary, process.argv.slice(2), { stdio: "inherit" })
  process.exit(result.status ?? 0)
}

import { register } from "tsx/esm/api"
register({ tsconfig: fileURLToPath(new URL("../tsconfig.json", import.meta.url)) })
// Load React's production renderer without changing the environment inherited by
// the daemon or tools. NODE_ENV=development remains an explicit debugging option.
const nodeEnv = process.env.NODE_ENV
process.env.NODE_ENV ??= "production"
const { main } = await import("../src/bin.ts")
if (nodeEnv === undefined) delete process.env.NODE_ENV
await main()
