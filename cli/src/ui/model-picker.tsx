import { useEffect, useState } from "react"
import { Box, Text, useWindowSize } from "ink"
import { request, type Connection } from "../daemon.js"
import { profiles, type Profiles, type Settings } from "../profiles.js"
import { Picker } from "./picker.js"
import { TextInput } from "./text-input.js"

type ModelPickerProps = {
  connection: Connection; provider: string; current: string; onSelect: (model: string, provider: string) => Promise<void>; onCancel: () => void
}

export function ModelPicker({ connection, provider, current, onSelect, onCancel }: ModelPickerProps) {
  const [saved, setSaved] = useState<Profiles>()
  const [name, setName] = useState(provider)
  const [choosingProvider, setChoosingProvider] = useState(false)
  const [error, setError] = useState("")
  const sessionProvider = provider || saved?.active
  useEffect(() => {
    let active = true
    void profiles().then(saved => {
      if (active) { setSaved(saved); setName(provider || saved.active || "") }
    }).catch(() => { if (active) setError("could not read providers; check /login") })
    return () => { active = false }
  }, [provider])
  return <Box flexDirection="column">
    <Text>albedo /model · {name || "session provider"}</Text>
    <Text dimColor>changes this idle session and the default for new sessions</Text>
    {!saved ? <>
      <Text color={error ? "red" : undefined} dimColor={!error}>{error || "loading providers…"}</Text>
      <TextInput value="" onChange={() => {}} onKey={(input, key) => {
        if (key.escape || (key.ctrl && ["c", "d"].includes(input))) { onCancel(); return true }
        return false
      }} />
    </> : choosingProvider ? <Picker search title="session provider" initialSelection={name} items={
      Object.entries(saved.providers).map(([id, settings]) => ({ id, label: id, detail: `${settings.protocol}${id === sessionProvider ? " · current" : ""}` }))
    } onSelect={name => { setName(name); setChoosingProvider(false) }} onCancel={() => setChoosingProvider(false)} /> :
      <ProviderModels key={name} connection={connection} provider={name} settings={saved.providers[name]} current={name === sessionProvider ? current : undefined}
        onSelect={onSelect} onCancel={onCancel} onProvider={() => setChoosingProvider(true)} />}
  </Box>
}

function ProviderModels({ connection, provider, settings, current, onSelect, onCancel, onProvider }: Omit<ModelPickerProps, "current"> & {
  settings?: Settings; current?: string; onProvider: () => void
}) {
  const initial = current ?? settings?.model ?? ""
  const [catalog, setCatalog] = useState<{ names: string[]; note?: string }>()
  const [manual, setManual] = useState(false)
  const [value, setValue] = useState(initial)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState("")
  const { columns } = useWindowSize()
  useEffect(() => {
    const controller = new AbortController()
    const provider = settings?.extension ?? "openai"
    const endpoint = settings?.baseUrl ?? ""
    void (settings
      ? request<string[]>(connection, `/models/${encodeURIComponent(provider)}?endpoint=${encodeURIComponent(endpoint)}`)
      : Promise.reject(new Error("session provider missing"))
    ).then(names => {
      if (!controller.signal.aborted) setCatalog({ names, ...(!names.length ? { note: "no models listed; enter a model id manually" } : {}) })
    }).catch(() => {
      if (!controller.signal.aborted) setCatalog({ names: [], note: "could not list models for this provider; enter a model id manually or check /login" })
    })
    return () => controller.abort()
  }, [connection, settings])
  const select = async (value: string): Promise<void> => {
    const model = value.trim()
    if (!model || model.length > 512 || /[\x00-\x1f\x7f]/.test(model)) { setError("enter a model id of 1–512 characters"); return }
    setError(""); setSaving(true)
    try { await onSelect(model, provider) }
    catch (error) { setError(error instanceof Error ? error.message : "could not change model"); setSaving(false) }
  }
  const cancelKey = (input: string, key: { escape: boolean; ctrl: boolean }): boolean => {
    if (key.escape || (key.ctrl && ["c", "d"].includes(input))) { onCancel(); return true }
    return false
  }
  return <Box flexDirection="column">
    {error && <Text color="red">{error}</Text>}
    {saving ? <Text dimColor>switching model…</Text> : manual ? <>
      <Box><Text>model id: </Text><TextInput value={value} onChange={setValue} onSubmit={value => { void select(value) }} onKey={cancelKey} width={Math.max(1, columns - 10)} /></Box>
      <Text dimColor>enter choose · esc cancel</Text>
    </> : <>
      {!catalog && <Text dimColor>loading models…</Text>}
      {catalog?.note && <Text dimColor>{catalog.note}</Text>}
      <Picker search title="session model" initialSelection={`model:${initial}`} items={[
        { id: "provider", label: "change provider", detail: provider },
        ...[...new Set([initial, ...(catalog?.names ?? [])].filter(Boolean))].map(model => ({ id: `model:${model}`, label: model, ...(model === current ? { detail: "current" } : {}) })),
        { id: "manual", label: "enter model id manually" },
      ]} onSelect={id => { if (id === "provider") onProvider(); else if (id === "manual") setManual(true); else void select(id.slice(6)) }} onCancel={onCancel} />
    </>}
  </Box>
}
