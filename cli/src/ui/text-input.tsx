import { useState } from "react"
import { Text, useInput, type Key } from "ink"

export type TextInputProps = {
  value: string
  onChange: (value: string) => void
  onSubmit?: (value: string) => void
  onKey?: (input: string, key: Key, replace: (value: string) => void) => boolean
  mask?: string
  multiline?: boolean
  width?: number
  /** The left arrow is an edit inside a buffer and a navigation gesture when the buffer is empty. */
  onLeftWhenEmpty?: () => void
  isActive?: boolean
}

/** Control characters never reach the buffer; pasted text arrives as one chunk. */
const typed = (input: string): string => [...input].filter((char) => char >= " " && char !== "\u007f").join("")

/**
 * Minimal controlled line editor. The buffer belongs to the caller, so the
 * prompt beside it lives in the render tree and no keystroke can erase it.
 */
export function TextInput({ value, onChange, onSubmit, onKey, onLeftWhenEmpty, isActive = true, mask, multiline, width }: TextInputProps) {
  const [offset, setOffset] = useState(value.length)
  const cursor = Math.min(offset, value.length)
  const edit = (next: string, at: number): void => { onChange(next); setOffset(at) }

  useInput((input, key) => {
    if (onKey?.(input, key, (next) => edit(next, next.length))) {
      return
    }
    if (multiline && ((key.return && key.shift) || (input.length > 1 && /[\r\n]/.test(input)))) {
      const pasted = key.return ? "\n" : input.replace(/\r\n?/g, "\n")
      const insert = pasted.split("\n").map(typed).join("\n")
      edit(value.slice(0, cursor) + insert + value.slice(cursor), cursor + insert.length)
      return
    }
    if (key.return) { setOffset(0); onSubmit?.(value); return }
    if (key.leftArrow) { if (!value) onLeftWhenEmpty?.(); else setOffset(Math.max(0, cursor - 1)); return }
    if (key.rightArrow) return setOffset(Math.min(value.length, cursor + 1))
    if (key.home) return setOffset(0)
    if (key.end) return setOffset(value.length)
    if (key.backspace) return cursor === 0 ? undefined : edit(value.slice(0, cursor - 1) + value.slice(cursor), cursor - 1)
    if (key.delete) return cursor >= value.length ? undefined : edit(value.slice(0, cursor) + value.slice(cursor + 1), cursor)
    if (key.ctrl) return input === "u" ? edit("", 0) : undefined
    if (key.meta || key.escape || key.tab || key.upArrow || key.downArrow) return
    // A terminal can deliver several keystrokes in one chunk (paste, fast
    // input, pipe-fed tests). Ink classifies the whole chunk as one keypress,
    // so an embedded \r or \n is never "the return key" — split it ourselves
    // and submit each terminated line, like readline did.
    const segments = input.split(/[\r\n]/)
    if (segments.length === 1) {
      const insert = typed(input)
      if (insert) edit(value.slice(0, cursor) + insert + value.slice(cursor), cursor + insert.length)
      return
    }
    let buffer = value
    let at = cursor
    for (const [index, segment] of segments.entries()) {
      const insert = typed(segment)
      if (insert) { buffer = buffer.slice(0, at) + insert + buffer.slice(at); at += insert.length }
      if (index < segments.length - 1) { onChange(buffer); onSubmit?.(buffer); buffer = ""; at = 0 }
      else { onChange(buffer); setOffset(at) }
    }
  }, { isActive })

  const shown = mask ? mask.repeat(value.length) : value.replace(/\n/g, " ")
  const first = Math.max(0, cursor - (width ?? shown.length + 1) + 1)
  return (
    <Text>
      {shown.slice(first, cursor)}
      <Text inverse>{shown.slice(cursor, cursor + 1) || " "}</Text>
      {shown.slice(cursor + 1, first + (width ?? shown.length + 1))}
    </Text>
  )
}
