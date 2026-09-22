import { useEffect, useState } from "react"
import { Box, Text, useInput } from "ink"
import { SelectableRows } from "./picker.js"

export type TreeCheckpoint = {
  id: number
  type: "user" | "assistant" | "tool"
  preview: string
  timestamp?: number
}

/** Items are ordered from oldest to newest within this bounded page. */
export type TreePage = {
  items: TreeCheckpoint[]
  hasPrevious: boolean
  hasNext: boolean
}

export type TreePickerProps = {
  page?: TreePage
  loading?: boolean
  error?: string
  onPrevious: () => void
  onNext: () => void
  onFork: (checkpoint: TreeCheckpoint) => void | Promise<void>
  onCancel: () => void
}

const previewLimit = 96

const readablePreview = (value: string): string => {
  const clean = value.replace(/[\p{Cc}\p{Cf}\p{Z}]+/gu, " ").trim()
  if (!clean) return "(empty)"
  const characters = [...clean]
  return characters.length <= previewLimit ? clean : `${characters.slice(0, previewLimit - 1).join("")}…`
}

const message = (error: unknown): string => error instanceof Error ? error.message : String(error)

export function TreePicker({ page, loading = false, error = "", onPrevious, onNext, onFork, onCancel }: TreePickerProps) {
  const [selected, setSelected] = useState(0)
  const [confirming, setConfirming] = useState<number>()
  const [forking, setForking] = useState(false)
  const [forkError, setForkError] = useState("")
  const items = page?.items ?? []
  const index = Math.min(selected, Math.max(0, items.length - 1))
  const current = items[index]

  useEffect(() => {
    setSelected(0)
    setConfirming(undefined)
    setForkError("")
  }, [page])

  const fork = async (): Promise<void> => {
    if (!current || forking) return
    setForkError("")
    setForking(true)
    try {
      await onFork(current)
    } catch (cause) {
      setForkError(message(cause))
      setForking(false)
    }
  }

  useInput((input, key) => {
    if (key.escape || (key.ctrl && ["c", "d"].includes(input))) {
      if (confirming !== undefined) {
        setConfirming(undefined)
        setForkError("")
      } else onCancel()
      return
    }
    if (forking || loading) return
    if (confirming !== undefined) {
      if (key.return && current && confirming === current.id) void fork()
      return
    }
    if (key.leftArrow || key.pageUp) {
      if (page?.hasPrevious) onPrevious()
      return
    }
    if (key.rightArrow || key.pageDown) {
      if (page?.hasNext) onNext()
      return
    }
    if (key.upArrow || key.downArrow) {
      setSelected(Math.max(0, Math.min(items.length - 1, index + (key.upArrow ? -1 : 1))))
      return
    }
    if (key.return && current) {
      setForkError("")
      setConfirming(current.id)
    }
  })

  const confirmingCheckpoint = confirming === current?.id
  return <Box flexDirection="column">
    <Text>albedo /tree · branch history</Text>
    <Text dimColor>choose the checkpoint the new session should end after</Text>
    {error && <Text color="red" wrap="wrap">{error}</Text>}
    {loading || (!page && !error) ? <Text dimColor>loading history…</Text> : page && <>
      {items.length ? <SelectableRows selected={index} items={items.map(checkpoint => ({
        id: String(checkpoint.id),
        label: <><Text dimColor>{checkpoint.type.padEnd(9)}</Text> {readablePreview(checkpoint.preview)}</>,
      }))} /> : <Text dimColor>no branchable history in this session</Text>}
      {confirmingCheckpoint && current && <Box flexDirection="column" marginTop={1}>
        <Text color="yellow" wrap="wrap">branch after {current.type} · {readablePreview(current.preview)}?</Text>
        <Text>new session · fresh python namespace · workspace files stay unchanged</Text>
        {forkError && <Text color="red" wrap="wrap">{forkError}</Text>}
      </Box>}
    </>}
    <Text dimColor>{forking ? "creating branch…" : confirmingCheckpoint ? `${forkError ? "enter retry" : "enter confirm"} · esc cancel` : "↑↓ select · ←→/pgup/pgdn page · enter branch · esc return to chat"}</Text>
  </Box>
}
