import { useEffect, useRef, useState } from "react"
import { Box, Text, useWindowSize } from "ink"
import { request, type Connection } from "../daemon.js"
import { endpoint, home, profiles, providerName, saveProvider, type OpenAISettings, type Profiles, type Protocol, type Settings } from "../profiles.js"
import { cancelSignIn, openBrowser, pollSignIn, provideSignInInput, removeAccount, selectAccount, signIns, startSignIn, type Account, type Login as SignIn, type SignIns } from "../signin.js"
import { Picker } from "./picker.js"
import { TextInput } from "./text-input.js"

type Step = "loading" | "choose" | "name" | "baseUrl" | "apiKey" | "protocol" | "models" | "model" | "signin" | "signinModels" | "saving"
/** The provider profile a sign-in or account choice will save. */
type Target = { provider: string; protocol: Protocol; profile: string }
type Flow = { id: string; url: string; status: string }

const empty: OpenAISettings = { extension: "openai", baseUrl: "https://api.openai.com/v1", apiKey: "", model: "", protocol: "responses" }
const nothing: SignIns = { logins: [], accounts: [] }
const extension = (settings: Settings): string => settings.extension ?? "openai"
const accountRow = (account: Account): string => `account:${encodeURIComponent(account.provider)}:${encodeURIComponent(account.id)}`
const accountOf = (row: string): [string, string] | undefined => {
  const parts = /^account:([^:]*):(.*)$/.exec(row)
  return parts ? [decodeURIComponent(parts[1]!), decodeURIComponent(parts[2]!)] : undefined
}

export function Login({ name: initialName, connection, onDone, onCancel }: {
  name?: string; connection?: Connection; onDone: (name: string) => void | Promise<void>; onCancel: () => void
}) {
  const { columns } = useWindowSize()
  const [saved, setSaved] = useState<Profiles>({ providers: {} })
  const [auth, setAuth] = useState<SignIns>(nothing)
  const [step, setStep] = useState<Step>("loading")
  const [name, setName] = useState("")
  const [target, setTarget] = useState<Target>()
  const [draft, setDraft] = useState<OpenAISettings>(empty)
  const [value, setValue] = useState("")
  const [error, setError] = useState("")
  const [catalog, setCatalog] = useState<{ names: string[]; note?: string }>()
  const [flow, setFlow] = useState<Flow>()
  const settled = useRef(false)
  const generation = useRef(0)
  const field = (step: Step, value = ""): void => { setStep(step); setValue(value); setError("") }
  const fail = (cause: unknown, fallback: string): void => setError(cause instanceof Error ? cause.message : fallback)
  const save = async (profile: string, settings: Settings): Promise<void> => {
    setStep("saving"); setError("")
    try { await saveProvider(profile, settings); await onDone(profile) }
    catch (cause) { fail(cause, "could not save provider"); setStep("choose") }
  }
  const loginFor = (provider: string): SignIn | undefined => auth.logins.find(login => login.provider === provider)
  const accounts = (provider: string): Account[] => auth.accounts.filter(account => account.provider === provider)
  const refresh = async (): Promise<void> => { if (connection) setAuth(await signIns(connection)) }
  const openModels = async (target: Target): Promise<void> => {
    const names = await request<string[]>(connection!, `/models/${encodeURIComponent(target.provider)}`).catch(() => [])
    const current = saved.providers[target.profile]
    setCatalog({ names, ...(!names.length ? { note: `models.dev has no models cached for ${target.provider}; enter a model id` } : {}) })
    setValue(current && extension(current) === target.provider ? current.model : "")
    setTarget(target)
    setStep("signinModels")
  }
  const start = async (login: SignIn, profile: string): Promise<void> => {
    if (!connection) { setError("sign-in requires the albedo daemon"); return }
    const mine = ++generation.current
    setTarget({ provider: login.provider, protocol: login.protocol, profile })
    setName(profile); setFlow(undefined); setCatalog(undefined); setError(""); setValue(""); setStep("signin")
    try {
      const started = await startSignIn(connection, login.provider)
      if (generation.current !== mine) { await cancelSignIn(connection, started.id).catch(() => {}); return }
      settled.current = false
      setFlow({ id: started.id, url: started.url, status: "complete login in the browser, or paste the callback url below" })
      openBrowser(started.url)
    } catch (cause) { if (generation.current === mine) fail(cause, "could not start the sign-in") }
  }
  const use = async (profile: string): Promise<void> => {
    const settings = saved.providers[profile]
    if (!settings) return
    const login = loginFor(extension(settings))
    if (login && !accounts(login.provider).length) { void start(login, profile); return }
    await save(profile, settings)
  }
  const useAccount = async (provider: string, id: string): Promise<void> => {
    if (!connection) { setError("account selection requires the albedo daemon"); return }
    try { await selectAccount(connection, provider, id); await refresh() }
    catch (cause) { fail(cause, "could not select the account") }
  }
  const dropAccount = (row: string): boolean => {
    const account = accountOf(row)
    if (!account || !connection) return false
    void removeAccount(connection, account[0], account[1])
      .then(refresh).catch(cause => fail(cause, "could not remove the account"))
    return true
  }
  useEffect(() => {
    let active = true
    void Promise.all([profiles(), connection ? signIns(connection) : Promise.resolve(nothing)]).then(([saved, auth]) => {
      if (!active) return
      setSaved(saved); setAuth(auth)
      if (initialName) {
        const initial = providerName(initialName)
        if (Object.hasOwn(saved.providers, initial)) { void save(initial, saved.providers[initial]!); return }
        const login = auth.logins.find(login => login.provider === initial)
        if (login) { void start(login, initial); return }
        setName(initial); setTarget(undefined); field("baseUrl", empty.baseUrl)
      } else if (Object.keys(saved.providers).length) field("choose")
      else field("name")
    }).catch(cause => { if (active) { fail(cause, "could not load providers"); setStep("choose") } })
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
    if (step !== "signin" || !flow || !connection || !target) return
    const controller = new AbortController()
    const id = flow.id
    void pollSignIn(connection, id, status => {
      if (!controller.signal.aborted) setFlow(current => current && { ...current, status: status.message })
    }, controller.signal).then(async status => {
      if (controller.signal.aborted || !status) return
      settled.current = true
      if (status.state === "failed") { setError(status.message); return }
      await openModels(target)
    }).catch(cause => { if (!controller.signal.aborted) fail(cause, "could not read the sign-in status") })
    return () => {
      controller.abort()
      if (!settled.current) void cancelSignIn(connection, id).catch(() => {})
    }
  }, [step, flow?.id, connection, target])
  const submit = (value: string): void => {
    try {
      if (step === "name") {
        const profile = providerName(value)
        const settings = saved.providers[profile]
        const login = loginFor(profile)
        if (login && (settings === undefined || extension(settings) === login.provider)) { void start(login, profile); return }
        const openai = settings ?? empty
        setName(profile); setTarget(undefined); setDraft({ ...empty, ...openai, extension: "openai" }); field("baseUrl", openai.baseUrl)
      } else if (step === "baseUrl") {
        const baseUrl = endpoint(value)
        setDraft({ ...draft, baseUrl, apiKey: baseUrl === draft.baseUrl ? draft.apiKey : "" })
        field("apiKey")
      } else if (step === "apiKey") {
        const apiKey = value || draft.apiKey
        if (!apiKey || /[\s\x00-\x1f\x7f]/.test(apiKey)) throw new Error("enter an api key without spaces or control characters")
        setDraft({ ...draft, apiKey }); field("protocol")
      } else if (step === "signin") {
        if (!flow || !connection) throw new Error("the sign-in has not started")
        const input = value.trim()
        if (!input) throw new Error("paste the callback url or code")
        setValue("")
        void provideSignInInput(connection, flow.id, input).catch(cause => fail(cause, "could not send the code"))
      } else if (step === "model") {
        const model = value.trim()
        if (!model || model.length > 512 || /[\x00-\x1f\x7f]/.test(model)) throw new Error("enter a model id of 1–512 characters")
        void save(target ? target.profile : name, target ? { extension: target.provider, model, protocol: target.protocol } : { ...draft, model })
      }
    } catch (cause) { fail(cause, "invalid value") }
  }
  const cancelKey = (input: string, key: { escape: boolean; ctrl: boolean }): boolean => {
    if (key.escape || (key.ctrl && ["c", "d"].includes(input))) { generation.current++; onCancel(); return true }
    return false
  }
  const chooseModel = (id: string): void => {
    if (id === "manual") field("model", value)
    else void save(target ? target.profile : name, target
      ? { extension: target.provider, model: id.slice(6), protocol: target.protocol }
      : { ...draft, model: id.slice(6) })
  }
  return <Box flexDirection="column">
    <Text>albedo /login{ name ? `  ${name}` : "" }</Text>
    <Text dimColor>model auth extensions · saved in {home}</Text>
    {error && <Text color="red">{error}</Text>}
    {step === "choose" ? <Picker initialSelection={`use:${saved.active}`} title="provider for new sessions" onDelete={dropAccount} items={[
      ...Object.entries(saved.providers).map(([profile, settings]) => ({ id: `use:${profile}`, label: profile,
        detail: `${settings.model} · ${extension(settings)}${profile === saved.active ? " · active" : ""}${
          loginFor(extension(settings)) && !accounts(extension(settings)).length ? " · signed out" : ""}` })),
      ...auth.accounts.map(account => ({ id: accountRow(account), label: account.label,
        detail: `${account.detail}${account.selected ? " · selected" : ""}` })),
      ...auth.logins.map(login => ({ id: `add:${login.provider}`, label: login.label, detail: login.detail })),
      { id: "add-openai", label: "add or update openai-compatible provider" },
    ]} onSelect={id => {
      if (id === "add-openai") { setName(""); setTarget(undefined); setDraft(empty); field("name") }
      else if (id.startsWith("add:")) { const login = loginFor(id.slice(4)); if (login) void start(login, login.provider) }
      else if (accountOf(id)) { const [provider, account] = accountOf(id)!; void useAccount(provider, account) }
      else { const profile = id.slice(4); void use(profile) }
    }} onCancel={onCancel} />
    : step === "protocol" ? <Picker initialSelection={draft.protocol} title="api protocol" items={[
      { id: "responses", label: "responses", detail: "openai responses api" },
      { id: "chat_completions", label: "chat completions", detail: "widely supported by compatible endpoints" },
    ]} onSelect={protocol => { setDraft({ ...draft, protocol: protocol as Protocol }); field("models") }} onCancel={() => field("apiKey")} />
    : (step === "models" || step === "signinModels") && catalog ? <>
      {catalog.note && <Text dimColor>{catalog.note}</Text>}
      <Picker initialSelection={`model:${value || draft.model}`} search title="model" items={[
        ...catalog.names.map(model => ({ id: `model:${model}`, label: model })),
        { id: "manual", label: "enter model id manually" },
      ]} onSelect={chooseModel} onCancel={() => step === "signinModels" ? onCancel() : field("baseUrl", draft.baseUrl)} />
    </> : step === "signin" ? <>
      <Text>{flow?.status ?? "starting sign-in…"}</Text>
      {flow && <Text dimColor>{flow.url}</Text>}
      <Box><Text>callback url or code: </Text><TextInput value={value} onChange={setValue} onSubmit={submit} onKey={cancelKey} width={Math.max(8, columns - 24)} /></Box>
      <Text dimColor>browser callback completes automatically · enter pastes manually · esc cancel</Text>
    </> : ["loading", "saving", "models", "signinModels"].includes(step) ? <>
      <Text dimColor>{step === "saving" ? "saving provider…" : step === "models" || step === "signinModels" ? "loading models…" : "loading providers…"}</Text>
      <TextInput value="" onChange={() => {}} onKey={cancelKey} isActive={step !== "saving"} />
    </> : <>
      <Box><Text>{({ name: "provider name", baseUrl: "api base url", apiKey: "api key", model: "model id" } as Partial<Record<Step, string>>)[step]}: </Text>
        <TextInput key={step} value={value} onChange={setValue} onSubmit={submit} onKey={cancelKey} width={Math.max(8, columns - 18)} mask={step === "apiKey" ? "*" : undefined} />
      </Box>
      <Text dimColor>{step === "apiKey" && draft.apiKey ? "enter keeps the saved key · " : ""}{step === "name" && auth.logins.length ? `enter ${auth.logins.map(login => login.provider).join(" or ")} to sign in · ` : ""}enter continue · esc cancel</Text>
    </>}
  </Box>
}
