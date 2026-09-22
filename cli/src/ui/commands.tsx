import { useState } from "react"
import { Box, Text } from "ink"
import type { TextInputProps } from "./text-input.js"

export type ChatCommand = { name: string; description: string }
const common: ChatCommand[] = [
  { name: "/a", description: "browse sessions" },
  { name: "/t", description: "show or hide thinking" },
  { name: "/v", description: "expand or collapse code, output and diffs" },
  { name: "/status", description: "show state, workspace and usage" },
  { name: "/q", description: "quit" },
]

export function useCommandMenu(value: string, submit: (value: string) => void, extra: ChatCommand[] = []) {
  const [selected, select] = useState(0)
  const [dismissed, dismiss] = useState("")
  // One row per name: the last occurrence wins, so chat's own builtins stay
  // authoritative over catalog entries with the same name.
  const matches = /^\/\S*$/.test(value) && value !== dismissed
    ? [...extra, ...common]
        .filter((item, index, all) => all.findLastIndex((other) => other.name === item.name) === index)
        .filter((item) => item.name.startsWith(value)) : []
  const index = Math.min(selected, Math.max(0, matches.length - 1))
  const onKey: NonNullable<TextInputProps["onKey"]> = (_, key, replace) => {
    const choice = matches[index]
    if (!choice) {
      return false
    }
    if (key.escape) {
      dismiss(value)
    } else if (key.upArrow || key.downArrow) {
      select(Math.max(0, Math.min(matches.length - 1, index + (key.upArrow ? -1 : 1))))
    } else if (key.tab) {
      replace(choice.name)
    } else if (key.return && !key.shift) {
      submit(choice.name)
    } else {
      select(0)
      return false
    }
    return true
  }
  const shown = matches.slice(Math.max(0, index - 3), Math.max(4, index + 1))
  return {
    onKey,
    rows: shown.length,
    view: <Box flexDirection="column">{shown.map((item) => (
      <Text key={item.name} inverse={item === matches[index]} wrap="truncate-end">
        {item.name}  {item.description}
      </Text>
    ))}</Box>,
  }
}
