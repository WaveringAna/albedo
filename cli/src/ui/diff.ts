import stringWidth from "string-width"
import wrapAnsi from "wrap-ansi"
import { highlightCode } from "./markdown.js"

const foreground = (code: number, text: string): string => `\x1b[${code}m${text}\x1b[39m`
const background = (tone: "add" | "remove" | "panel"): string => ({
  add: "\x1b[48;2;24;53;39m", remove: "\x1b[48;2;59;35;40m", panel: "\x1b[48;2;37;40;50m",
})[tone]
const language = (path: string): string => ({ ts: "typescript", tsx: "typescript", js: "javascript", jsx: "javascript", py: "python", rs: "rust", sh: "bash" })[path.split(".").at(-1) ?? ""] ?? "text"
const clean = (text: string): string => text.replace(/[\p{Cc}\p{Cf}]/gu, char => char === "\t" ? "   " : " ")

/** Full-width diff rows: a line-number gutter, colored change blocks, wrapped content. */
export function renderDiff(diff: string, path: string, width: number): string[] {
  const columns = Math.max(1, width)
  if (columns < 8) return ["…".slice(0, columns)]
  const rows: string[] = []
  let oldLine = 0
  let newLine = 0
  const lang = language(path)
  const row = (gutter: string, content: string, tone: "add" | "remove" | "panel", syntax = false): void => {
    const available = Math.max(1, columns - stringWidth(gutter))
    const styled = syntax ? highlightCode(content, lang).replaceAll("\x1b[0m", "\x1b[39;22;23m") : foreground(90, content)
    const parts = wrapAnsi(styled, available, { hard: true, trim: false }).split("\n")
    for (const [index, part] of parts.entries()) {
      const prefix = index === 0 ? gutter : " ".repeat(stringWidth(gutter))
      const body = prefix + part
      rows.push(background(tone) + body + " ".repeat(Math.max(0, columns - stringWidth(body))) + "\x1b[0m")
    }
  }
  row(" ", clean(path), "panel")
  for (const line of diff.split("\n")) {
    if (!line) continue
    if (line.startsWith("--- ") || line.startsWith("+++ ")) continue
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)/.exec(line)
    if (hunk) {
      oldLine = Number(hunk[1]); newLine = Number(hunk[2])
      row(" ⋮ ", clean(line), "panel")
    } else if (line.startsWith("+")) {
      row(foreground(32, `${String(newLine++).padStart(4)} + `), clean(line.slice(1)), "add", true)
    } else if (line.startsWith("-")) {
      row(foreground(31, `${String(oldLine++).padStart(4)} - `), clean(line.slice(1)), "remove", true)
    } else if (line.startsWith(" ")) {
      row(foreground(90, `${String(newLine++).padStart(4)}   `), clean(line.slice(1)), "panel", true)
      oldLine++
    } else {
      row(" ⋮ ", clean(line), "panel")
    }
  }
  return rows
}
