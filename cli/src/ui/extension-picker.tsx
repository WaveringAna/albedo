import { useEffect, useState } from "react"
import { Box, Text, useInput } from "ink"
import { request, type Connection } from "../daemon.js"
import { SelectableRows } from "./picker.js"

export type Extension = {
  name: string
  description: string
  enabled: boolean
  context: boolean
  tools: string[]
  python_modules: string[]
  requires: string[]
  plugins?: string[]
}

type ExtensionPickerProps = {
  connection: Connection
  sessionId: string
  onChanged: () => void
  onCancel: () => void
}

const upgrade = "daemon upgrade needed for /extensions; when ready, run albedo daemon --stop, then albedo (this clears python variables)"
const message = (error: unknown): string => error instanceof Error ? error.message : String(error)

const capabilities = (extension: Extension): string[] => [
  ...(extension.context ? ["context"] : []),
  ...(extension.tools.length ? [`tools (${extension.tools.join(", ")})`] : []),
  ...(extension.python_modules.length ? [`python modules (${extension.python_modules.join(", ")})`] : []),
]

export function ExtensionPicker({ connection, sessionId, onChanged, onCancel }: ExtensionPickerProps) {
  const [extensions, setExtensions] = useState<Extension[]>()
  const [selected, setSelected] = useState(0)
  const [confirming, setConfirming] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState("")
  const [revision, retry] = useState(0)
  const index = Math.min(selected, Math.max(0, (extensions?.length ?? 1) - 1))
  const current = extensions?.[index]

  useEffect(() => {
    let active = true
    setExtensions(undefined)
    setError("")
    void request<{ capabilities?: string[] }>(connection, "/health").then(health => {
      if (!health.capabilities?.includes("session_extensions")) throw new Error(upgrade)
      return request<Extension[]>(connection, `/sessions/${sessionId}/extensions`)
    }).then(items => { if (active) setExtensions(items) }).catch(cause => { if (active) setError(message(cause)) })
    return () => { active = false }
  }, [connection, sessionId, revision])

  const toggle = async (): Promise<void> => {
    if (!current || saving) return
    setError("")
    setSaving(true)
    try {
      const updated = await request<Extension[]>(connection, `/sessions/${sessionId}/extensions`, { name: current.name, enabled: !current.enabled })
      setExtensions(updated)
      const next = updated.findIndex(extension => extension.name === current.name)
      if (next >= 0) setSelected(next)
      setConfirming(false)
      onChanged()
    } catch (cause) {
      setError(message(cause))
    } finally {
      setSaving(false)
    }
  }

  useInput((input, key) => {
    if (key.escape || (key.ctrl && ["c", "d"].includes(input))) {
      if (confirming) setConfirming(false)
      else onCancel()
      return
    }
    if (!extensions) {
      if (input.toLowerCase() === "r") retry(value => value + 1)
      return
    }
    if (confirming) {
      if (key.return) void toggle()
      return
    }
    if (key.upArrow || key.downArrow) {
      setSelected(Math.max(0, Math.min(extensions.length - 1, index + (key.upArrow ? -1 : 1))))
    } else if ((key.return || input === " ") && current) {
      setError("")
      setConfirming(true)
    }
  }, { isActive: !saving })

  const facts = current ? capabilities(current) : []
  return <Box flexDirection="column">
    <Text>albedo /extensions · session plugins</Text>
    <Text dimColor>extensions bundle plugins for this session only</Text>
    <Text color="yellow" wrap="wrap">changes reload workers and available plugins, bust prompt-cache reuse, and may reset unsavable python variables</Text>
    {error && <Text color="red" wrap="wrap">{error}</Text>}
    {!extensions ? <Text dimColor>{error ? "r retry · esc return to chat" : "loading extensions…"}</Text> : <>
      <SelectableRows selected={index} items={extensions.map(extension => ({
        id: extension.name,
        label: <><Text color={extension.enabled ? "green" : undefined}>{extension.enabled ? "on " : "off"}</Text>  {extension.name}</>,
        detail: extension.description,
      }))} />
      {!extensions.length && <Text dimColor>no extensions installed for this session</Text>}
      {current && <Box flexDirection="column" marginTop={1}>
        <Text>{current.description}</Text>
        <Text dimColor>plugins: {current.plugins?.join(", ") || "not reported"}</Text>
        <Text dimColor>capabilities: {facts.length ? facts.join(" · ") : "not reported"}</Text>
        <Text dimColor>requires: {current.requires.length ? current.requires.join(", ") : "none"}</Text>
      </Box>}
      {confirming && current && <Text color="yellow" wrap="wrap">
        {current.enabled ? "disable" : "enable"} {current.name} and reload this session's workers? {error ? "enter retry" : "enter confirm"} · esc cancel
      </Text>}
      <Text dimColor>{saving ? `reloading workers for ${current?.name ?? "extension"}…` : confirming ? "waiting for confirmation" : "↑↓ select · enter/space toggle · esc return to chat"}</Text>
    </>}
  </Box>
}
