import assert from "node:assert/strict"
import test from "node:test"
import wrapAnsi from "wrap-ansi"
import { MarkdownIndex } from "./markdown-index.js"
import { renderMarkdownAnsi } from "./markdown.js"

test("streamed markdown matches whole-message layout at every chunk boundary and width", () => {
  const documents = [
    "# a heading\n**bold** and *italics*\n> quoted 界界\n- list\n1. ordered\n---\nlast line\n",
    "before\n```js\nconst text = `many\nlines`; /* a\ncomment */\n```\nafter",
    "```python\ndef greet(name):\n    return 'hi'\n```\n```\nunclosed code\n",
    "\x1b[32mansi across\nlines\x1b[0m\n👩‍💻 é 界".repeat(3),
    "\x9b32mansi across\nlines\x9b0m\nlast",
    "```javascript\n// comment\nconst value = \"a\\\"b\";\n```",
    "a very long unbroken " + "word".repeat(60),
    "\n\n```\n```\n\n```js\n```\n",
  ]
  for (const document of documents) {
    for (const chunkSize of [1, 7, 53, document.length]) {
      const index = new MarkdownIndex()
      let source = ""
      for (let offset = 0; offset < document.length; offset += chunkSize) {
        const chunk = document.slice(offset, offset + chunkSize)
        source += chunk
        index.append(chunk)
        assert.equal(index.text(), source)
        for (const width of [37, 9, 1, 37]) {
          const expected = wrapAnsi(renderMarkdownAnsi(source, width), width, { hard: true, trim: false }).split("\n")
          const rows = index.layout(width)
          assert.deepEqual(rows.slice(0, rows.length), expected, JSON.stringify({ source, width, chunkSize }))
          assert.deepEqual(rows.slice(2, 7), expected.slice(2, 7))
        }
      }
    }
  }
})

test("completed sections remain indexed while a message grows", () => {
  const index = new MarkdownIndex()
  index.append("**first**\n".repeat(10_000))
  const before = index.layout(80)
  for (let i = 0; i < 100; i++) {
    index.append(`line ${i}\n`)
    const rows = index.layout(80)
    assert.equal(rows.length, 10_002 + i)
    assert.deepEqual(rows.slice(0, 3), before.slice(0, 3))
    assert.deepEqual(rows.slice(rows.length - 2, rows.length), [`line ${i}`, ""])
  }
})
