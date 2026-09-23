/** An extension's own screen, as the daemon describes it (see page.gleam). */
export type PageTone = "plain" | "active" | "warning" | "muted"
export type PageRow = { id: string; text: string; badge: string; tone: PageTone }
export type PageInput =
  | { input: "none" }
  | { input: "text"; prompt: string; prefill: boolean }
  | { input: "choice"; options: string[] }
  | { input: "value"; value: string }
export type PageAction = { key: string; label: string; run: string; row: boolean; confirm: boolean } & PageInput
export type Glance = { title: string; rows: PageRow[] }
export type PageDocument = {
  title: string
  summary: string
  empty: string
  rows: PageRow[]
  actions: PageAction[]
  glance?: Glance
}

const tones = new Set(["plain", "active", "warning", "muted"])
const isText = (value: unknown): value is string => typeof value === "string"

function parseRow(value: unknown): PageRow | undefined {
  if (!value || typeof value !== "object") return undefined
  const row = value as Record<string, unknown>
  if (!isText(row.id) || !isText(row.text) || !isText(row.badge)) return undefined
  return { id: row.id, text: row.text, badge: row.badge, tone: tones.has(String(row.tone)) ? row.tone as PageTone : "plain" }
}

function parseAction(value: unknown): PageAction | undefined {
  if (!value || typeof value !== "object") return undefined
  const action = value as Record<string, unknown>
  // One printable key per action; a key the terminal cannot type would be dead.
  if (!isText(action.key) || [...action.key].length !== 1 || !isText(action.label) || !isText(action.run)) return undefined
  const base = { key: action.key, label: action.label, run: action.run, row: action.row === true, confirm: action.confirm === true }
  switch (action.input) {
    case "text": return { ...base, input: "text", prompt: isText(action.prompt) ? action.prompt : action.label, prefill: action.prefill === true }
    case "choice":
      return Array.isArray(action.options) && action.options.length && action.options.every(isText)
        ? { ...base, input: "choice", options: action.options } : undefined
    case "value": return isText(action.value) ? { ...base, input: "value", value: action.value } : undefined
    default: return { ...base, input: "none" }
  }
}

const rows = (value: unknown): PageRow[] =>
  Array.isArray(value) ? value.map(parseRow).filter((row): row is PageRow => row !== undefined) : []

/** A command result that is a page, or undefined. Malformed rows and actions drop out one by one. */
export function parsePage(result: unknown): PageDocument | undefined {
  const page = result && typeof result === "object" ? (result as { page?: unknown }).page : undefined
  if (!page || typeof page !== "object") return undefined
  const document = page as Record<string, unknown>
  if (!isText(document.title)) return undefined
  const glance = document.glance && typeof document.glance === "object" ? document.glance as Record<string, unknown> : undefined
  return {
    title: document.title,
    summary: isText(document.summary) ? document.summary : "",
    empty: isText(document.empty) ? document.empty : "nothing here yet",
    rows: rows(document.rows),
    actions: Array.isArray(document.actions)
      ? document.actions.map(parseAction).filter((action): action is PageAction => action !== undefined) : [],
    ...(glance && isText(glance.title) ? { glance: { title: glance.title, rows: rows(glance.rows) } } : {}),
  }
}

/** How one action runs: the page command with `action` and space-joined `details`. */
export function actionArgs(action: PageAction, row?: PageRow, entered?: string): Record<string, string> {
  const value = action.input === "value" ? action.value : entered?.trim()
  const details = [action.row ? row?.id : undefined, value].filter((part): part is string => Boolean(part)).join(" ")
  return { action: action.run, details }
}
