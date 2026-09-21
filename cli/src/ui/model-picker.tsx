import { useEffect, useState } from "react"
import { Box, Text, useWindowSize } from "ink"
import { modelNames, profiles } from "../profiles.js"
import { Picker } from "./picker.js"
import { TextInput } from "./text-input.js"

export function ModelPicker({ provider, current, onSelect, onCancel }: {
  provider: string; current: string; onSelect: (model: string) => Promise<void>; onCancel: () => void
}) {
  const [catalog, setCatalog] = useState<{ names: string[]; note?: string }>()
  const [manual, setManual] = useState(false)
  const [value, setValue] = useState(current)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState("")
  const { columns } = useWindowSize()
  useEffect(() => {
    const controller = new AbortController()
    void (async () => {
      const saved = await profiles()
      const name = provider || saved.active
      const settings = name && saved.providers[name]
      if (!settings) throw new Error("session provider missing")
      return modelNames(settings.baseUrl, settings.apiKey, controller.signal)
    })().then(names => {
      if (!controller.signal.aborted) setCatalog({ names, ...(!names.length ? { note: "no models listed; enter a model id manually" } : {}) })
    }).catch(() => {
      if (!controller.signal.aborted) setCatalog({ names: [], note: "could not list models for this provider; enter a model id manually or check /login" })
    })
    return () => controller.abort()
  }, [provider])
  const select = async (value: string): Promise<void> => {
    const model = value.trim()
    if (!model || model.length > 512 || /[\x00-\x1f\x7f]/.test(model)) { setError("enter a model id of 1–512 characters"); return }
    setError(""); setSaving(true)
    try { await onSelect(model) }
    catch (error) { setError(error instanceof Error ? error.message : "could not change model"); setSaving(false) }
  }
  const cancelKey = (input: string, key: { escape: boolean; ctrl: boolean }): boolean => {
    if (key.escape || (key.ctrl && ["c", "d"].includes(input))) { onCancel(); return true }
    return false
  }
  return <Box flexDirection="column">
    <Text>albedo /model · {provider || "session provider"}</Text>
    <Text dimColor>changes this idle session only · endpoint and protocol stay unchanged</Text>
    {error && <Text color="red">{error}</Text>}
    {saving ? <Text dimColor>switching model…</Text> : !catalog ? <>
      <Text dimColor>loading models…</Text>
      <TextInput value="" onChange={() => {}} onKey={cancelKey} />
    </> : manual ? <>
      <Box><Text>model id: </Text><TextInput value={value} onChange={setValue} onSubmit={value => { void select(value) }} onKey={cancelKey} width={Math.max(1, columns - 10)} /></Box>
      <Text dimColor>enter choose · esc cancel</Text>
    </> : <>
      {catalog.note && <Text dimColor>{catalog.note}</Text>}
      <Picker search title="session model" initialSelection={`model:${current}`} items={[
        ...[...new Set([current, ...catalog.names])].map(model => ({ id: `model:${model}`, label: model, ...(model === current ? { detail: "current" } : {}) })),
        { id: "manual", label: "enter model id manually" },
      ]} onSelect={id => { if (id === "manual") setManual(true); else void select(id.slice(6)) }} onCancel={onCancel} />
    </>}
  </Box>
}
