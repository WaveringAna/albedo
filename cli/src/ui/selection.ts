import { stripVTControlCharacters } from "node:util"
import stringWidth from "string-width"
import type { Rows } from "./row-index.js"

export type Point = { row: number; column: number }
export type Selection = { anchor: Point; head: Point }

type Grapheme = { text: string; start: number; end: number }
type PlainRow = { width: number; graphemes: Grapheme[] }

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" })
const inverse = "\u001b[7m"
const reset = "\u001b[0m"

function coordinate(value: number): number {
  return Number.isFinite(value) ? Math.trunc(value) : value === Infinity ? Number.MAX_SAFE_INTEGER : 0
}

function clamp(value: number, maximum: number): number {
  return Math.min(maximum, Math.max(0, coordinate(value)))
}

function plainRow(line: string): PlainRow {
  const text = stripVTControlCharacters(line)
  const graphemes: Grapheme[] = []
  let column = 0
  for (const { segment } of segmenter.segment(text)) {
    const start = column
    column += stringWidth(segment)
    graphemes.push({ text: segment, start, end: column })
  }
  return { width: column, graphemes }
}

function ordered(a: Point, b: Point): [Point, Point] {
  return a.row < b.row || (a.row === b.row && a.column <= b.column) ? [a, b] : [b, a]
}

function selected(row: PlainRow, from: number, to: number): string {
  return row.graphemes
    .filter(({ start, end }) => end > from && start < to)
    .map(({ text }) => text)
    .join("")
}

/** Copies a terminal-cell range without ANSI styling or flattening the row source. */
export function selectedText(rows: Rows, selection: Selection): string {
  if (selection.anchor.row === selection.head.row && selection.anchor.column === selection.head.column) return ""
  if (rows.length === 0) return ""

  const lastRow = rows.length - 1
  const anchorRow = clamp(selection.anchor.row, lastRow)
  const headRow = clamp(selection.head.row, lastRow)
  const firstRow = Math.min(anchorRow, headRow)
  const finalRow = Math.max(anchorRow, headRow)
  const source = rows.slice(firstRow, finalRow + 1).map(plainRow)
  if (source.length === 0) return ""

  const point = (candidate: Point, row: number): Point => {
    const local = source[row - firstRow]
    return { row, column: clamp(candidate.column, local?.width ?? 0) }
  }
  const [start, end] = ordered(
    point(selection.anchor, anchorRow),
    point(selection.head, headRow),
  )
  if (start.row === end.row && start.column === end.column) return ""

  return source.map((row, offset) => {
    const rowNumber = firstRow + offset
    const from = rowNumber === start.row ? start.column : 0
    const to = rowNumber === end.row ? end.column : row.width
    return selected(row, from, to)
  }).join("\n")
}

/** Adds inverse video to the selected cells of a visible row window. */
export function highlightSelection(lines: string[], startRow: number, selection: Selection): string[] {
  const [start, end] = ordered(selection.anchor, selection.head)
  if (start.row === end.row && start.column === end.column) return lines

  return lines.map((line, offset) => {
    const rowNumber = startRow + offset
    if (rowNumber < start.row || rowNumber > end.row) return line

    const row = plainRow(line)
    const from = clamp(rowNumber === start.row ? start.column : 0, row.width)
    const to = clamp(rowNumber === end.row ? end.column : row.width, row.width)
    const chosen = row.graphemes.map(({ start, end }) => end > from && start < to)
    if (!chosen.some(Boolean)) return line

    let result = ""
    let highlighted = false
    row.graphemes.forEach(({ text }, index) => {
      if (chosen[index] !== highlighted) {
        result += chosen[index] ? inverse : reset
        highlighted = chosen[index]!
      }
      result += text
    })
    return result + (highlighted ? reset : "")
  })
}
