import { useEffect, useRef, useState } from "react"
import { Box, Text, useWindowSize } from "ink"
import { loginCodex, saveCodexAccount } from "../codex.js"
import { request, type Connection } from "../daemon.js"
import { endpoint, home, profiles, providerName, saveProvider, type OpenAISettings, type Profiles, type Settings } from "../profiles.js"
import { Picker } from "./picker.js"
import { TextInput } from "./text-input.js"

type Step = "loading" | "choose" | "name" | "baseUrl" | "apiKey" | "protocol" | "models" | "model" | "codexAuth" | "codexModels" | "saving"
const empty: OpenAISettings = { extension: "openai", baseUrl: "https://api.openai.com/v1", apiKey: "", model: "", protocol: "responses" }
export function Login({ name: initialName, connection, onDone, onCancel }: {
  name?: string; connection?: Connection; onDone: (name: string) => void | Promise<void>; onCancel: () => void
}) {
  const { columns } = useWindowSize()
  const [saved, setSaved] = useState<Profiles>({ providers: {} })
  const [step, setStep] = useState<Step>("loading")
  const [name, setName] = useState("")
  const [kind, setKind] = useState<"openai" | "codex">("openai")
  const [draft, setDraft] = useState<OpenAISettings>(empty)
  const [value, setValue] = useState("")
  const [error, setError] = useState("")
  const [catalog, setCatalog] = useState<{ names: string[]; note?: string }>()
  const [oauth, setOauth] = useState<{ url?: string; status?: string }>({})
  const manual = useRef<((value: string) => void) | undefined>(undefined)
  const field = (step: Step, value = ""): void => { setStep(step); setValue(value); setError("") }
  const save = async (name: string, settings: Settings): Promise<void> => {
    setStep("saving"); setError("")
    try { await saveProvider(name, settings); await onDone(name) }
    catch (error) { setError(error instanceof Error ? error.message : "could not save provider"); setStep("choose") }
  }
  const startCodex = (): void => { setKind("codex"); setName("codex"); setOauth({}); field("codexAuth") }
  useEffect(() => {
    let active = true
    void profiles().then(saved => {
      if (!active) return
      setSaved(saved)
      if (initialName) {
        const name = providerName(initialName)
        if (Object.hasOwn(saved.providers, name)) { void save(name, saved.providers[name]!); return }
        if (name === "codex") startCodex()
        else { setName(name); setKind("openai"); field("baseUrl", empty.baseUrl) }
      } else if (Object.keys(saved.providers).length) field("choose")
      else field("name")
    }).catch(error => { if (active) { setError(error instanceof Error ? error.message : "could not load providers"); setStep("choose") } })
    return () => { active = false }
  }, [initialName, connection])
  useEffect(() => {
    if (step !== "models") return
    const controller = new AbortController()
    setCatalog(undefined)
    void (connection
      ? request<string[]>(connection, `/models/openai?endpoint=${encodeURIComponent(draft.baseUrl)}`)
      : Promise.reject(new Error("model catalog requires the albedo daemon"))
    ).then(names => {
      if (!controller.signal.aborted) setCatalog({ names, ...(!names.length ? { note: "models.dev has no matching models; enter a model id" } : {}) })
    }).catch(() => {
      if (!controller.signal.aborted) setCatalog({ names: [], note: "could not read the models.dev catalog; enter a model id" })
    })
    return () => controller.abort()
  }, [step, connection, draft.baseUrl])
  useEffect(() => {
    if (step !== "codexAuth") return
    if (!connection) { setError("codex login requires the albedo daemon"); return }
    const controller = new AbortController()
    const manualInput = new Promise<string>(resolve => { manual.current = resolve })
    void loginCodex({
      signal: controller.signal,
      onAuth: url => setOauth({ url, status: "complete login in the browser, or paste the callback url below" }),
      onProgress: status => setOauth(current => ({ ...current, status })),
      onManualCodeInput: () => manualInput,
    }).then(async credential => {
      if (controller.signal.aborted) return
      await saveCodexAccount(credential)
      const names = await request<string[]>(connection, "/models/codex").catch(() => [])
      if (controller.signal.aborted) return
      const current = saved.providers.codex
      setCatalog({ names, ...(!names.length ? { note: "models.dev has no OpenAI models cached; enter a model id" } : {}) })
      setValue(current?.extension === "codex" ? current.model : "")
      setStep("codexModels")
    }).catch(error => { if (!controller.signal.aborted) setError(error instanceof Error ? error.message : "codex login failed") })
    return () => { manual.current = undefined; controller.abort() }
  }, [step, connection, saved.providers])
  const submit = (value: string): void => {
    try {
      if (step === "name") {
        const name = providerName(value)
        const settings = saved.providers[name]
        if (name === "codex" && !settings) { startCodex(); return }
        if (settings?.extension === "codex") { startCodex(); return }
        const openai = settings ?? empty
        setName(name); setKind("openai"); setDraft({ ...empty, ...openai, extension: "openai" }); field("baseUrl", openai.baseUrl)
      } else if (step === "baseUrl") {
        const baseUrl = endpoint(value)
        setDraft({ ...draft, baseUrl, apiKey: baseUrl === draft.baseUrl ? draft.apiKey : "" })
        field("apiKey")
      } else if (step === "apiKey") {
        const apiKey = value || draft.apiKey
        if (!apiKey || /[\s\x00-\x1f\x7f]/.test(apiKey)) throw new Error("enter an api key without spaces or control characters")
        setDraft({ ...draft, apiKey }); field("protocol")
      } else if (step === "codexAuth") {
        if (!manual.current) throw new Error("codex authorization is not ready")
        manual.current(value); manual.current = undefined; setOauth(current => ({ ...current, status: "exchanging authorization code" }))
      } else if (step === "model") {
        const model = value.trim()
        if (!model || model.length > 512 || /[\x00-\x1f\x7f]/.test(model)) throw new Error("enter a model id of 1–512 characters")
        void save(name, kind === "codex" ? { extension: "codex", model, protocol: "responses" } : { ...draft, model })
      }
    } catch (error) { setError(error instanceof Error ? error.message : "invalid value") }
  }
  const cancelKey = (input: string, key: { escape: boolean; ctrl: boolean }): boolean => {
    if (key.escape || (key.ctrl && ["c", "d"].includes(input))) { onCancel(); return true }
    return false
  }
  const chooseModel = (id: string): void => {
    if (id === "manual") field("model", value)
    else void save(name, kind === "codex"
      ? { extension: "codex", model: id.slice(6), protocol: "responses" }
      : { ...draft, model: id.slice(6) })
  }
  return <Box flexDirection="column">
    <Text>albedo /login{ name ? `  ${name}` : "" }</Text>
    <Text dimColor>model auth extensions · saved in {home}</Text>
    {error && <Text color="red">{error}</Text>}
    {step === "choose" ? <Picker initialSelection={`use:${saved.active}`} title="provider for new sessions" items={[
      ...Object.entries(saved.providers).map(([name, settings]) => ({ id: `use:${name}`, label: name, detail: `${settings.model} · ${settings.extension ?? "openai"}${name === saved.active ? " · active" : ""}` })),
      { id: "add-openai", label: "add or update openai-compatible provider" },
      { id: "add-codex", label: "add chatgpt codex account", detail: "oauth · supports multiple accounts" },
    ]} onSelect={id => {
      if (id === "add-openai") { setName(""); setKind("openai"); setDraft(empty); field("name") }
      else if (id === "add-codex") startCodex()
      else { const selected = id.slice(4); void save(selected, saved.providers[selected]!) }
    }} onCancel={onCancel} />
    : step === "protocol" ? <Picker initialSelection={draft.protocol} title="api protocol" items={[
      { id: "responses", label: "responses", detail: "openai responses api" },
      { id: "chat_completions", label: "chat completions", detail: "widely supported by compatible endpoints" },
    ]} onSelect={protocol => { setDraft({ ...draft, protocol: protocol as OpenAISettings["protocol"] }); field("models") }} onCancel={() => field("apiKey")} />
    : (step === "models" || step === "codexModels") && catalog ? <>
      {catalog.note && <Text dimColor>{catalog.note}</Text>}
      <Picker initialSelection={`model:${value || draft.model}`} search title="model" items={[
        ...catalog.names.map(model => ({ id: `model:${model}`, label: model })),
        { id: "manual", label: "enter model id manually" },
      ]} onSelect={chooseModel} onCancel={() => step === "codexModels" ? onCancel() : field("baseUrl", draft.baseUrl)} />
    </> : step === "codexAuth" ? <>
      <Text>{oauth.status ?? "starting codex oauth…"}</Text>
      {oauth.url && <Text dimColor>{oauth.url}</Text>}
      <Box><Text>callback url or code: </Text><TextInput value={value} onChange={setValue} onSubmit={submit} onKey={cancelKey} width={Math.max(8, columns - 24)} /></Box>
      <Text dimColor>browser callback completes automatically · enter pastes manually · esc cancel</Text>
    </> : ["loading", "saving", "models", "codexModels"].includes(step) ? <>
      <Text dimColor>{step === "saving" ? "saving provider…" : step === "models" || step === "codexModels" ? "loading models…" : "loading providers…"}</Text>
      <TextInput value="" onChange={() => {}} onKey={cancelKey} isActive={step !== "saving"} />
    </> : <>
      <Box><Text>{({ name: "provider name", baseUrl: "api base url", apiKey: "api key", model: "model id" } as Partial<Record<Step, string>>)[step]}: </Text>
        <TextInput key={step} value={value} onChange={setValue} onSubmit={submit} onKey={cancelKey} width={Math.max(8, columns - 18)} mask={step === "apiKey" ? "*" : undefined} />
      </Box>
      <Text dimColor>{step === "apiKey" && draft.apiKey ? "enter keeps the saved key · " : ""}{step === "name" && connection ? "use codex for ChatGPT oauth · " : ""}enter continue · esc cancel</Text>
    </>}
  </Box>
}
