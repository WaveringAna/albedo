import { useEffect, useState } from "react"
import { Box, Text, useInput, useWindowSize } from "ink"
import { actionArgs, parsePage, type PageAction, type PageDocument, type PageRow, type PageTone } from "../page.js"
import { SelectableRows } from "./picker.js"
import { TextInput } from "./text-input.js"

type PageViewProps = {
  /** The page command, e.g. "/work". */
  command: string
  /** Runs the page command; no arguments answers the page document. */
  run: (args: Record<string, string>) => Promise<Record<string, unknown> | undefined>
  onChanged?: () => void
  onCancel: () => void
}

type Mode =
  | { kind: "browse" }
  | { kind: "text"; action: PageAction; prompt: string; value: string }
  | { kind: "choice"; action: PageAction; options: string[]; index: number }
  | { kind: "confirm"; action: PageAction }

const message = (error: unknown): string => error instanceof Error ? error.message : String(error)

export const toneColor = (tone: PageTone): string | undefined =>
  ({ plain: undefined, active: "green", warning: "yellow", muted: "gray" })[tone]

/** Any extension page: rows, a selection, and the actions the page declares. */
export function PageView({ command, run, onChanged, onCancel }: PageViewProps) {
  const [page, setPage] = useState<PageDocument>()
  // Selection follows a row's id, so a change that reorders rows keeps it.
  const [selectedId, setSelectedId] = useState<string>()
  const [mode, setMode] = useState<Mode>({ kind: "browse" })
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState("")
  const [error, setError] = useState("")
  const [revision, reload] = useState(0)
  const { columns } = useWindowSize()

  useEffect(() => {
    let active = true
    void run({}).then(result => {
      if (!active) return
      const document = parsePage(result)
      if (!document) throw new Error(`${command} did not answer a page`)
      setPage(document)
    }).catch(cause => { if (active) setError(message(cause)) })
    return () => { active = false }
  }, [command, revision])

  const index = Math.max(0, page?.rows.findIndex(item => item.id === selectedId) ?? 0)
  const row: PageRow | undefined = page?.rows[index]

  const apply = (action: PageAction, entered?: string): void => {
    setMode({ kind: "browse" })
    setBusy(true); setError("")
    void run(actionArgs(action, row, entered)).then(result => {
      setNotice(typeof result?.message === "string" ? result.message : `${action.label} done`)
      onChanged?.()
      reload(value => value + 1)
    }).catch(cause => setError(message(cause))).finally(() => setBusy(false))
  }

  const start = (action: PageAction): void => {
    if (action.row && !row) return
    setNotice(""); setError("")
    if (action.confirm) return setMode({ kind: "confirm", action })
    collect(action)
  }

  /** Ask for whatever the action still needs, or run it. */
  const collect = (action: PageAction): void => {
    switch (action.input) {
      case "text": return setMode({ kind: "text", action, prompt: action.prompt, value: action.prefill && row ? row.text : "" })
      case "choice": return setMode({ kind: "choice", action, options: action.options, index: Math.max(0, action.options.indexOf(row?.badge ?? "")) })
      default: return apply(action)
    }
  }

  useInput((input, key) => {
    if (key.escape || (key.ctrl && input === "c")) {
      if (mode.kind === "browse") onCancel()
      else setMode({ kind: "browse" })
      return
    }
    if (!page) {
      if (input.toLowerCase() === "r") { setError(""); reload(value => value + 1) }
      return
    }
    if (mode.kind === "confirm") {
      // A confirmed action still collects its input afterwards.
      if (key.return) collect(mode.action)
      return
    }
    if (mode.kind === "choice") {
      if (key.upArrow || key.downArrow || key.leftArrow || key.rightArrow) {
        const step = key.upArrow || key.leftArrow ? -1 : 1
        setMode({ ...mode, index: (mode.index + step + mode.options.length) % mode.options.length })
      } else if (key.return) apply(mode.action, mode.options[mode.index])
      return
    }
    if (key.upArrow || key.downArrow) {
      setSelectedId(page.rows[Math.max(0, Math.min(page.rows.length - 1, index + (key.upArrow ? -1 : 1)))]?.id)
      return
    }
    const action = page.actions.find(item => item.key === input)
    if (action) start(action)
  }, { isActive: !busy && mode.kind !== "text" })

  const hints = page?.actions.filter(action => !action.row || row).map(action => `${action.key} ${action.label}`) ?? []
  const target = row ? ` ${row.id === row.text ? row.text : `#${row.id} ${row.text}`}` : ""
  return <Box flexDirection="column">
    <Text>albedo {command}{page?.summary ? ` · ${page.summary}` : ""}</Text>
    {error && <Text color="red" wrap="wrap">{error}</Text>}
    {notice && !error && <Text color="cyanBright" wrap="truncate-end">{notice}</Text>}
    {!page ? <Text dimColor>{error ? "r retry · esc return to chat" : `loading ${command}…`}</Text> : <>
      {page.rows.length
        ? <SelectableRows selected={index} items={page.rows.map(item => ({
            id: item.id,
            label: <><Text color={toneColor(item.tone)}>{item.badge.padEnd(9)}</Text> {item.text}</>,
            ...(item.id !== item.text ? { detail: `#${item.id}` } : {}),
          }))} />
        : <Text dimColor>{page.empty}</Text>}
      {mode.kind === "text" && <Box height={1} flexShrink={0}>
        <Text color="cyanBright">{mode.action.label}{mode.action.row ? target : ""} · {mode.prompt} › </Text>
        <TextInput value={mode.value} width={Math.max(10, columns - mode.action.label.length - mode.prompt.length - target.length - 8)}
          onChange={value => setMode({ ...mode, value })}
          onSubmit={value => { if (value.trim()) apply(mode.action, value) }}
          onKey={(_, key) => { if (!key.escape) return false; setMode({ kind: "browse" }); return true }} />
      </Box>}
      {mode.kind === "choice" && <Text wrap="truncate-end">
        <Text color="cyanBright">{mode.action.label}{target} › </Text>
        {mode.options.map((option, position) =>
          <Text key={option} inverse={position === mode.index}>{` ${option} `}</Text>)}
      </Text>}
      {mode.kind === "confirm" && <Text color="yellow" wrap="truncate-end">{mode.action.label}{target}? enter confirm · esc cancel</Text>}
      <Text dimColor wrap="truncate-end">
        {busy ? "working…" : mode.kind === "browse" ? [...(page.rows.length > 1 ? ["↑↓ select"] : []), ...hints, "esc return to chat"].join(" · ")
          : mode.kind === "text" ? "enter save · esc cancel" : mode.kind === "choice" ? "←→ choose · enter apply · esc cancel" : ""}
      </Text>
    </>}
  </Box>
}
