#!/usr/bin/env node
import { register } from "tsx/esm/api"
import { fileURLToPath } from "node:url"
register({ tsconfig: fileURLToPath(new URL("../tsconfig.json", import.meta.url)) })
// Load React's production renderer without changing the environment inherited by
// the daemon or tools. NODE_ENV=development remains an explicit debugging option.
const nodeEnv = process.env.NODE_ENV
process.env.NODE_ENV ??= "production"
const { main } = await import("../src/bin.ts")
if (nodeEnv === undefined) delete process.env.NODE_ENV
await main()
