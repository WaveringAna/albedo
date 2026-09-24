import { useState, type ReactNode } from "react"
import { Box, Text, useWindowSize } from "ink"
import { TextInput } from "./text-input.js"

type Row = { id: string; label: ReactNode; detail?: ReactNode }
export type PickerProps = {
  items: { id: string; label: string; detail?: string }[]
  onSelect: (id: string) => void
  onCancel: () => void
  /** Removes the row the remove key points at; an unhandled id leaves the key to the query. */
  onDelete?: (id: string) => boolean
  search?: boolean
  title?: string
  initialQuery?: string
  initialSelection?: string
}

/** The agents list and menus share a marker and a terminal-sized selection window. */
export function SelectableRows({ items, selected, limit }: { items: Row[]; selected: number; limit?: number }) {
  const { rows } = useWindowSize()
  const available = Math.max(1, Math.min(limit ?? rows, rows - 8))
  const first = Math.min(Math.max(0, selected - available + 1), Math.max(0, items.length - available))
  return <Box flexDirection="column">
    {items.slice(first, first + available).map((item, offset) => (
      <Text key={item.id} inverse={first + offset === selected} wrap="truncate-end">
        {first + offset === selected ? "> " : "  "}{item.label}{item.detail && <Text dimColor>  {item.detail}</Text>}
      </Text>
    ))}
    {!items.length && <Text dimColor>no matches</Text>}
  </Box>
}

export function Picker({ items, onSelect, onCancel, onDelete, search = false, title, initialQuery = "", initialSelection }: PickerProps) {
  const [query, setQuery] = useState(initialQuery)
  const [selectedId, setSelectedId] = useState(initialSelection)
  const tokens = query.toLowerCase().trim().split(/\s+/)
  const matches = items.filter((item) => tokens.every((token) => `${item.id} ${item.label} ${item.detail ?? ""}`.toLowerCase().includes(token)))
  const selected = Math.max(0, matches.findIndex((item) => item.id === (selectedId ?? initialSelection)))
  return <Box flexDirection="column">
    {title && <Text>{title}</Text>}
    <SelectableRows items={matches} selected={selected} />
    <Box><Text dimColor>{search ? "search: " : ""}</Text><TextInput multiline value={query} onChange={setQuery} onKey={(input, key) => {
      if (key.escape || (key.ctrl && input === "c")) {
        onCancel()
        return true
      }
      if (key.upArrow || key.downArrow) {
        setSelectedId(matches[Math.max(0, Math.min(matches.length - 1, selected + (key.upArrow ? -1 : 1)))]?.id)
        return true
      }
      if ((input === "d" || key.delete) && onDelete && matches[selected] && onDelete(matches[selected]!.id)) {
        return true
      }
      if (key.return) {
        const choice = matches[selected]
        if (choice) {
          onSelect(choice.id)
        }
        return true
      }
      return !search
    }} /></Box>
    <Text dimColor>↑↓ select · enter choose{onDelete ? " · d remove" : ""} · esc cancel</Text>
  </Box>
}
