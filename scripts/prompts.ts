#!/usr/bin/env bun
// Local-only prompt review: `pull` gathers the model-facing strings from the
// gleam sources into one editable file, `push` writes edited ones back.
//   bun scripts/prompts.ts pull [--min 50]
//   bun scripts/prompts.ts push [--dry] [--force]
import { createHash } from "node:crypto"
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { join, relative, resolve } from "node:path"
import { spawnSync } from "node:child_process"

const root = resolve(import.meta.dir, "..")
const out = join(import.meta.dir, "prompts.txt")
const MARK = "@@@ "

type Unit = { start: number; end: number; text: string; line: number; raw: boolean }

const escapes: Record<string, string> = { n: "\n", r: "\r", t: "\t", f: "\f", '"': '"', "\\": "\\" }

// Every string literal in a gleam source, with `"a" <> "b"` chains of pure
// literals joined into one unit. Comments are skipped, so quoted text inside
// them never counts.
const units = (src: string): Unit[] => {
  const found: Unit[] = []
  let i = 0
  let line = 1
  const skipBlank = (from: number): number => {
    let j = from
    for (;;) {
      if (/\s/.test(src[j] ?? "")) j++
      else if (src.startsWith("//", j)) while (j < src.length && src[j] !== "\n") j++
      else return j
    }
  }
  const readString = (from: number): { end: number; text: string } => {
    let j = from + 1
    let text = ""
    while (src[j] !== '"') {
      if (src[j] !== "\\") text += src[j++]
      else if (src[j + 1] === "u") {
        const close = src.indexOf("}", j)
        text += String.fromCodePoint(parseInt(src.slice(j + 3, close), 16))
        j = close + 1
      } else {
        const mapped = escapes[src[j + 1]]
        if (mapped === undefined) throw new Error(`unknown escape \\${src[j + 1]} at offset ${j}`)
        text += mapped
        j += 2
      }
    }
    return { end: j + 1, text }
  }
  while (i < src.length) {
    if (src.startsWith("//", i)) {
      while (i < src.length && src[i] !== "\n") i++
    } else if (src[i] === '"') {
      const start = i
      let { end, text } = readString(i)
      for (;;) {
        const op = skipBlank(end)
        if (!src.startsWith("<>", op)) break
        const next = skipBlank(op + 2)
        if (src[next] !== '"') break
        const piece = readString(next)
        text += piece.text
        end = piece.end
      }
      found.push({ start, end, text, line: src.slice(0, start).split("\n").length, raw: src.slice(start, end).includes("\n") })
      i = end
    } else i++
  }
  return found
}

const encode = (text: string, raw: boolean): string =>
  '"' +
  [...text]
    .map((ch) => (ch === "\\" ? "\\\\" : ch === '"' ? '\\"' : ch === "\n" ? (raw ? "\n" : "\\n") : ch === "\t" ? "\\t" : ch === "\r" ? "\\r" : ch === "\f" ? "\\f" : ch))
    .join("") +
  '"'

const sources = (dir: string): string[] =>
  readdirSync(dir).flatMap((name) => {
    const path = join(dir, name)
    return statSync(path).isDirectory() ? sources(path) : name.endsWith(".gleam") ? [path] : []
  })

const digest = (text: string) => createHash("sha1").update(text).digest("hex").slice(0, 8)
// A prompt reads as prose: several words, not an identifier or a short label.
const sqlStart = /^\s*(select|insert|create|update|delete|pragma|alter|drop|with|replace)\b/i
const sqlWords = /\b(SELECT|INSERT INTO|CREATE TABLE|WHERE|FROM)\b/
const prose = (text: string, min: number) =>
  text.length >= min && text.trim().split(/\s+/).length >= 5 && !sqlStart.test(text) && !sqlWords.test(text)

// The definition a string sits in, so a block reads with its context.
const enclosing = (src: string, offset: number): string => {
  let name = "top level"
  for (const m of src.matchAll(/^(?:pub )?(?:fn|const) (\w+)/gm)) {
    if (m.index > offset) break
    name = m[1]
  }
  return name
}

const pull = (min: number) => {
  const blocks: string[] = []
  for (const file of sources(join(root, "src")).sort()) {
    const rel = relative(root, file)
    const text = readFileSync(file, "utf8")
    const picked = units(text).map((unit, ordinal) => ({ unit, ordinal })).filter(({ unit }) => prose(unit.text, min))
    for (const { unit, ordinal } of picked) {
      if (unit.text.split("\n").some((l) => l.startsWith(MARK))) throw new Error(`${rel}:${unit.line} contains a ${MARK.trim()} line`)
      blocks.push(`${MARK}${rel} #${ordinal} @${digest(unit.text)} (line ${unit.line}, in ${enclosing(text, unit.start)})\n${unit.text}\n`)
    }
  }
  const header = `# prompts pulled from src/**/*.gleam. Edit the text under each ${MARK.trim()} header, keep the header lines, then \`bun scripts/prompts.ts push\`.\n# a block is refused if its source string changed since the pull (use --force to override).\n\n`
  writeFileSync(out, header + blocks.join("\n"))
  console.log(`wrote ${blocks.length} prompts to ${relative(root, out)}`)
}

type Edit = { rel: string; ordinal: number; digest: string; text: string }

const parse = (): Edit[] => {
  const edits: Edit[] = []
  let current: { head: RegExpMatchArray; body: string[] } | undefined
  const close = () => {
    if (!current) return
    // The block separator adds exactly one newline after the text.
    const body = current.body.join("\n").replace(/\n$/, "")
    edits.push({ rel: current.head[1], ordinal: Number(current.head[2]), digest: current.head[3], text: body })
  }
  for (const line of readFileSync(out, "utf8").split("\n")) {
    const head = line.startsWith(MARK) ? line.match(/^@@@ (\S+) #(\d+) @(\w+)/) : null
    if (head) {
      close()
      current = { head, body: [] }
    } else current?.body.push(line)
  }
  close()
  return edits
}

const push = (dry: boolean, force: boolean) => {
  const byFile = Map.groupBy(parse(), (edit) => edit.rel)
  let changed = 0
  const touched: string[] = []
  for (const [rel, edits] of byFile) {
    const path = join(root, rel)
    let src = readFileSync(path, "utf8")
    const current = units(src)
    const patches = edits.flatMap((edit) => {
      const unit = current[edit.ordinal]
      if (!unit) throw new Error(`${rel} #${edit.ordinal}: no such string any more`)
      if (unit.text === edit.text) return []
      if (digest(unit.text) !== edit.digest && !force) {
        console.error(`skipped ${rel} #${edit.ordinal}: the source changed since the pull`)
        return []
      }
      return [{ unit, edit }]
    })
    for (const { unit, edit } of patches.sort((a, b) => b.unit.start - a.unit.start)) {
      src = src.slice(0, unit.start) + encode(edit.text, unit.raw) + src.slice(unit.end)
      console.log(`${dry ? "would update" : "updated"} ${rel}:${unit.line}`)
      changed++
    }
    if (patches.length && !dry) {
      writeFileSync(path, src)
      touched.push(path)
    }
  }
  if (touched.length) spawnSync("gleam", ["format", ...touched], { cwd: root, stdio: "inherit" })
  console.log(changed ? `${changed} prompts ${dry ? "differ" : "written back"}` : "no changes")
}

const [command, ...flags] = process.argv.slice(2)
if (command === "pull") {
  const at = flags.indexOf("--min")
  pull(at >= 0 ? Number(flags[at + 1]) : 50)
} else if (command === "push") push(flags.includes("--dry"), flags.includes("--force"))
else console.error("usage: prompts.ts pull [--min N] | push [--dry] [--force]")
