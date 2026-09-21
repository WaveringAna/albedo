import assert from "node:assert/strict"
import test from "node:test"
import { styledCharsFromTokens, styledCharsToString, tokenize, type StyledChar } from "@alcalzone/ansi-tokenize"

const { styledRuns } = await import(new URL("./styled-runs.js", import.meta.resolve("ink")).href) as {
  styledRuns: (characters: (StyledChar | undefined)[]) => StyledChar[]
}

test("ink style runs preserve exact ANSI serialization without mutating cached cells", () => {
  const styles = ["", "\x1b[31m", "\x1b[1;2;3;4m", "\x1b[38;2;1;99;222m", "\x1b[48;5;23m", "\x1b]8;;https://example.com\x07"]
  const words = ["", "plain text", "界👩‍💻é", "    ", "\x1b[22mnormal", "\x1b[39mdefault", "\x1b]8;;\x07link end"]
  for (const left of styles) for (const right of styles) for (const word of words) {
    const chars = styledCharsFromTokens(tokenize(`${left}${word}${right}${word}\x1b[0m`))
    const expected = styledCharsToString(chars)
    for (const char of chars) { Object.freeze(char.styles); Object.freeze(char) }
    assert.equal(styledCharsToString(styledRuns(chars)), expected)
    // Same style values need not share identity; repeated ANSI tokens stay valid.
    const cloned = chars.map(char => structuredClone(char))
    assert.equal(styledCharsToString(styledRuns(cloned)), expected)
  }
  const chars = styledCharsFromTokens(tokenize("\x1b[32m" + "x".repeat(100)))
  const wide = chars.slice(0, 2)
  wide.splice(1, 0, { ...wide[0]!, value: "" })
  assert.equal(styledCharsToString(styledRuns(wide)), styledCharsToString(wide), "wide-character placeholders stay invisible")
  assert.equal(styledCharsToString(styledRuns([undefined, ...wide, undefined])), styledCharsToString(wide))
})

type Output = {
  write(x: number, y: number, text: string, options: { transformers: ((line: string, index: number) => string)[] }): void
  clip(clip: { x1: number; x2: number; y1: number; y2: number }): void
  unclip(): void
  get(): { output: string; height: number }
}
const { default: Output, OutputCaches } = await import(new URL("./output.js", import.meta.resolve("ink")).href) as {
  default: new (options: { width: number; height: number; caches?: unknown }) => Output
  OutputCaches: new () => {
    nextFrame(): void
  }
}


test("warm ink caches match fresh frames through clipping, style changes and wide-character overlaps", () => {
  const cache = new OutputCaches()
  const text = ["plain", "界界👩‍💻é", "\x1b[31mred\x1b[0m", "\x1b[1;2mboth\x1b[22m", "\x1b]8;;https://example.com\x07linked\x1b]8;;\x07"]
  for (let frame = 0; frame < 200; frame++) {
    cache.nextFrame()
    const width = 10 + frame % 20 + (frame % 3) / 2
    const height = 6 + (frame % 3) / 2
    const draw = (output: Output) => {
      output.write(0, 0, "界界\nbackground\n".repeat(2), { transformers: [] })
      output.clip({ x1: 2, x2: width - 2, y1: 1, y2: 4 })
      output.write(frame % 3 - 1, 0, text.map((_, i) => text[(frame + i) % text.length]).join("\n"), {
        transformers: [line => frame % 2 ? `\x1b[4m${line}\x1b[24m` : line],
      })
      output.unclip()
      output.write(1, 0, "x", { transformers: [] })
      output.write(-2, 2, "界界offscreen", { transformers: [] })
      return output.get()
    }
    assert.deepEqual(draw(new Output({ width, height, caches: cache })), draw(new Output({ width, height })))
  }
})

const { default: TextCache } = await import(new URL("./text-cache.js", import.meta.resolve("ink")).href) as {
  default: new (units: number, entries: number) => { get(key: string): unknown; set(key: string, value: unknown): void }
}

test("ink text caches release old frames and bypass oversized text", () => {
  const cache = new TextCache(20, 2)
  cache.set("a", "first")
  cache.set("b", "second")
  assert.equal(cache.get("a"), "first")
  cache.set("c", "third")
  assert.equal(cache.get("b"), undefined)
  assert.equal(cache.get("a"), "first")
  cache.set("huge", "x".repeat(100))
  assert.equal(cache.get("huge"), undefined)
  assert.equal(cache.get("a"), "first")
  cache.set("c", "x".repeat(17))
  assert.equal(cache.get("a"), undefined, "the text budget applies even with spare entry slots")
  cache.set("c", "")
  assert.equal(cache.get("c"), "")
})

test("ink wrapping and measurement remain correct across frame eviction and widths", async () => {
  const { default: wrap } = await import(new URL("./wrap-text.js", import.meta.resolve("ink")).href) as {
    default: (text: string, width: number, mode: string) => string
  }
  const { default: measure } = await import(new URL("./measure-text.js", import.meta.resolve("ink")).href) as {
    default: (text: string) => { width: number; height: number }
  }
  assert.equal(wrap("hello1", 2, "wrap"), "he\nll\no1")
  assert.equal(wrap("hello", 12, "wrap"), "hello", "text and width must not collide in the cache key")
  for (let frame = 0; frame < 1000; frame++) {
    const line = `frame ${frame}`
    assert.equal(wrap(line, 100, "wrap"), line)
    assert.deepEqual(measure(`${line}\n界界`), { width: line.length, height: 2 })
  }
  assert.equal(wrap("hello1", 2, "wrap"), "he\nll\no1")
  assert.deepEqual(measure(""), { width: 0, height: 0 })
})


test("composed rows stay correct while scrolling and updating overlapping status text", () => {
  const caches = new OutputCaches()
  const history = Array.from({ length: 40 }, (_, i) => `\x1b[${i % 2 ? 31 : 36}mrow ${i} 界👩‍💻é\x1b[0m`)
  for (let frame = 0; frame < 120; frame++) {
    caches.nextFrame()
    const draw = (output: Output) => {
      const top = frame % 30
      output.write(0, 0, history.slice(top, top + 6).join("\n"), { transformers: [] })
      output.write(9, frame % 6, frame % 2 ? "working" : "done", { transformers: [] })
      return output.get()
    }
    assert.deepEqual(draw(new Output({ width: 40, height: 8, caches })), draw(new Output({ width: 40, height: 8 })))
  }
})
