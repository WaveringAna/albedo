import assert from "node:assert/strict"
import test from "node:test"
import stringWidth from "string-width"
import type { Rows } from "./row-index.js"
import { highlightSelection, selectedText, type Selection } from "./selection.js"

const range = (anchor: [number, number], head: [number, number]): Selection => ({
  anchor: { row: anchor[0], column: anchor[1] },
  head: { row: head[0], column: head[1] },
})
const rows = (lines: string[]): Rows => ({ length: lines.length, slice: (start, end) => lines.slice(start, end) })

test("copies forward, reverse, and multiline terminal-cell ranges", () => {
  const source = rows(["abcd", "efgh", "ijkl"])
  assert.equal(selectedText(source, range([0, 0], [0, 3])), "abc")
  assert.equal(selectedText(source, range([1, 2], [0, 1])), "bcd\nef")
  assert.equal(selectedText(source, range([0, 2], [2, 1])), "cd\nefgh\ni")
  assert.equal(selectedText(source, range([1, 2], [1, 2])), "")
})

test("clips points to the available rows and cells", () => {
  const source = rows(["abc", "de"])
  assert.equal(selectedText(source, range([-20, -5], [20, 99])), "abc\nde")
  assert.equal(selectedText(source, range([0, 99], [1, -4])), "\n")
  assert.equal(selectedText(rows([]), range([0, 0], [1, 1])), "")
})

test("cell intersections copy whole wide and combining graphemes", () => {
  const source = rows(["a界b", "e\u0301x", "👩‍💻!"])
  assert.equal(selectedText(source, range([0, 2], [0, 3])), "界")
  assert.equal(selectedText(source, range([1, 0], [1, 1])), "e\u0301")
  assert.equal(selectedText(source, range([2, 1], [2, 2])), "👩‍💻")
})

test("copied text omits terminal escape sequences", () => {
  const source = rows(["\u001b[31mred\u001b[0m plain", "\u001b]8;;https://example.test\u0007link\u001b]8;;\u0007"])
  assert.equal(selectedText(source, range([0, 0], [0, 3])), "red")
  assert.equal(selectedText(source, range([1, 0], [1, 4])), "link")
})

test("copying asks a row source only for the selected span", () => {
  const calls: [number, number][] = []
  const source: Rows = {
    length: 10_000,
    slice(start, end) {
      calls.push([start, end])
      return Array.from({ length: end - start }, (_, index) => `row ${start + index}`)
    },
  }
  assert.equal(selectedText(source, range([402, 3], [400, 4])), "400\nrow 401\nrow")
  assert.deepEqual(calls, [[400, 403]])
})

test("highlighting preserves untouched rows and cell width", () => {
  const lines = ["outside", "a界b", "e\u0301x", "after"]
  const highlighted = highlightSelection(lines, 7, range([8, 2], [9, 1]))
  assert.equal(highlighted[0], lines[0])
  assert.equal(highlighted[1], `a\u001b[7m界b\u001b[0m`)
  assert.equal(highlighted[2], `\u001b[7me\u0301\u001b[0mx`)
  assert.equal(highlighted[3], lines[3])
  assert.equal(stringWidth(highlighted[1]!), stringWidth(lines[1]!))
  assert.equal(stringWidth(highlighted[2]!), stringWidth(lines[2]!))
})

test("highlighting strips old styling only on a selected row", () => {
  const styled = "\u001b[31mred\u001b[0m"
  assert.deepEqual(
    highlightSelection([styled, styled], 0, range([0, 1], [0, 2])),
    [`r\u001b[7me\u001b[0md`, styled],
  )
  assert.deepEqual(highlightSelection([styled], 0, range([0, 1], [0, 1])), [styled])
})
