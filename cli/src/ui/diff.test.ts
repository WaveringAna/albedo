import assert from "node:assert/strict"
import test from "node:test"
import stringWidth from "string-width"
import { stripVTControlCharacters as strip } from "node:util"
import { renderDiff } from "./diff.js"

test("rich diff keeps numbered colored blocks at terminal width, wrapping long changes", () => {
  const rows = renderDiff(`@@ -7,2 +7,3 @@\n context\n-old\n+const value = ${"wide 界".repeat(4)}\n+extra`, "file.ts", 24)
  assert(rows.every(row => stringWidth(row) === 24))
  assert(rows.some(row => row.includes("\x1b[48;2;24;53;39m")))
  assert(rows.some(row => row.includes("\x1b[48;2;59;35;40m")))
  assert(rows.map(strip).some(row => row.includes("   8 - old")))
  assert(rows.map(strip).some(row => row.includes("   9 + extra")))
  assert(rows.length > 6)
  assert.deepEqual(renderDiff("@@ -1 +1 @@\n-old\n+new", "file", 1), ["…"])
})
