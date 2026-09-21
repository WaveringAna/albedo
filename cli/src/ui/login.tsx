import { useEffect, useState } from "react"
import { Box, Text, useWindowSize } from "ink"
import { endpoint, home, modelNames, profiles, providerName, saveProvider, type Profiles, type Settings } from "../profiles.js"
import { Picker } from "./picker.js"
import { TextInput } from "./text-input.js"

type Step = "loading" | "choose" | "name" | "baseUrl" | "apiKey" | "protocol" | "models" | "model" | "saving"
const empty: Settings = { baseUrl: "https://api.openai.com/v1", apiKey: "", model: "", protocol: "responses" }
export function Login({ name: initialName, onDone, onCancel }: {
  name?: string; onDone: (name: string) => void | Promise<void>; onCancel: () => void
}) {
  const { columns } = useWindowSize()
  const [saved, setSaved] = useState<Profiles>({ providers: {} })
  const [step, setStep] = useState<Step>("loading")
  const [name, setName] = useState("")
  const [draft, setDraft] = useState<Settings>(empty)
  const [value, setValue] = useState("")
  const [error, setError] = useState("")
  const [catalog, setCatalog] = useState<{ names: string[]; note?: string }>()
  const field = (step: Step, value = ""): void => { setStep(step); setValue(value); setError("") }
  const save = async (name: string, settings: Settings): Promise<void> => {
    setStep("saving"); setError("")
    try { await saveProvider(name, settings); await onDone(name) }
    catch (error) { setError(error instanceof Error ? error.message : "could not save provider"); setStep("choose") }
  }
  useEffect(() => {
    let active = true
    void profiles().then(saved => {
      if (!active) return
      setSaved(saved)
      if (initialName) {
        const name = providerName(initialName)
        if (Object.hasOwn(saved.providers, name)) { void save(name, saved.providers[name]!); return }
        setName(name); field("baseUrl", empty.baseUrl)
      } else field(Object.keys(saved.providers).length ? "choose" : "name")
    }).catch(error => { if (active) { setError(error instanceof Error ? error.message : "could not load providers"); setStep("choose") } })
    return () => { active = false }
  }, [initialName])
  useEffect(() => {
    if (step !== "models") return
    const controller = new AbortController()
    setCatalog(undefined)
    void modelNames(draft.baseUrl, draft.apiKey, controller.signal).then(names => {
      if (!controller.signal.aborted) setCatalog({ names, ...(!names.length ? { note: "no models listed; enter a model id" } : {}) })
    }).catch(() => {
      if (!controller.signal.aborted) setCatalog({ names: [], note: "could not list models; check the endpoint and key, or enter a model id" })
    })
    return () => controller.abort()
  }, [step, draft.baseUrl, draft.apiKey])
  const submit = (value: string): void => {
    try {
      if (step === "name") {
        const name = providerName(value)
        const settings = Object.hasOwn(saved.providers, name) ? saved.providers[name]! : empty
        setName(name); setDraft(settings); field("baseUrl", settings.baseUrl)
      } else if (step === "baseUrl") {
        const baseUrl = endpoint(value)
        setDraft({ ...draft, baseUrl, apiKey: baseUrl === draft.baseUrl ? draft.apiKey : "" })
        field("apiKey")
      } else if (step === "apiKey") {
        const apiKey = value || draft.apiKey
        if (!apiKey || /[\s\x00-\x1f\x7f]/.test(apiKey)) throw new Error("enter an api key without spaces or control characters")
        setDraft({ ...draft, apiKey }); field("protocol")
      } else if (step === "model") {
        const model = value.trim()
        if (!model || model.length > 512 || /[\x00-\x1f\x7f]/.test(model)) throw new Error("enter a model id of 1–512 characters")
        void save(name, { ...draft, model })
      }
    } catch (error) { setError(error instanceof Error ? error.message : "invalid value") }
  }
  const cancelKey = (input: string, key: { escape: boolean; ctrl: boolean }): boolean => {
    if (key.escape || (key.ctrl && ["c", "d"].includes(input))) { onCancel(); return true }
    return false
  }
  return <Box flexDirection="column">
    <Text>albedo /login{ name ? `  ${name}` : "" }</Text>
    <Text dimColor>openai-compatible api · saved in {home}</Text>
    {error && <Text color="red">{error}</Text>}
    {step === "choose" ? <Picker initialSelection={`use:${saved.active}`} title="provider for new sessions" items={[
      ...Object.entries(saved.providers).map(([name, value]) => ({ id: `use:${name}`, label: name, detail: `${value.model}${name === saved.active ? " · active" : ""}` })),
      { id: "add", label: "add or update provider" },
    ]} onSelect={id => { if (id === "add") { setName(""); setDraft(empty); field("name") } else { const name = id.slice(4); void save(name, saved.providers[name]!) } }} onCancel={onCancel} />
    : step === "protocol" ? <Picker initialSelection={draft.protocol} title="api protocol" items={[
      { id: "responses", label: "responses", detail: "openai responses api" },
      { id: "chat_completions", label: "chat completions", detail: "widely supported by compatible endpoints" },
    ]} onSelect={protocol => { setDraft({ ...draft, protocol: protocol as Settings["protocol"] }); field("models") }} onCancel={() => field("apiKey")} />
    : step === "models" && catalog ? <>
      {catalog.note && <Text dimColor>{catalog.note}</Text>}
      <Picker initialSelection={`model:${draft.model}`} search title="model" items={[
        ...catalog.names.map(model => ({ id: `model:${model}`, label: model })),
        { id: "manual", label: "enter model id manually" },
      ]} onSelect={id => { if (id === "manual") field("model", draft.model); else void save(name, { ...draft, model: id.slice(6) }) }} onCancel={() => field("baseUrl", draft.baseUrl)} />
    </> : ["loading", "saving", "models"].includes(step) ? <>
      <Text dimColor>{step === "saving" ? "saving provider…" : step === "models" ? "loading models…" : "loading providers…"}</Text>
      <TextInput value="" onChange={() => {}} onKey={cancelKey} isActive={step !== "saving"} />
    </> : <>
      <Box><Text>{({ name: "provider name", baseUrl: "api base url", apiKey: "api key", model: "model id" } as Partial<Record<Step, string>>)[step]}: </Text>
        <TextInput key={step} value={value} onChange={setValue} onSubmit={submit} onKey={cancelKey} width={Math.max(8, columns - 18)} mask={step === "apiKey" ? "*" : undefined} />
      </Box>
      <Text dimColor>{step === "apiKey" && draft.apiKey ? "enter keeps the saved key · " : ""}enter continue · esc cancel</Text>
    </>}
  </Box>
}
