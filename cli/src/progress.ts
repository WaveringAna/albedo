import { TreeFragment, type SyntaxNode, type Tree } from "@lezer/common"
import { parser } from "@lezer/python"
import { JSONParser } from "@streamparser/json"
type ToolCallAssembly = { id: string; function: { name: string; arguments: string } }
import type { ToolIntent, ToolProgress } from "./events.js"

const clean = (text: string): string => text.replace(/[\p{Cc}\p{Cf}]/gu, " ").replace(/\s+/g, " ").trim().slice(0, 300)
type Value = { kind: "string" | "path"; text: string }

/** Read syntax, never evaluate code. Unknown/dynamic paths deliberately stay generic. */
export function pythonIntent(code: string, tree = parser.parse(code)): ToolIntent | undefined {
  const text = (node: SyntaxNode | null): string => node ? code.slice(node.from, node.to) : ""
  const bindings = new Map<string, Value>()
  const intents: ToolIntent[] = []
  const args = (call: SyntaxNode): { positional: SyntaxNode[]; named: Map<string, SyntaxNode> } => {
    const positional: SyntaxNode[] = []
    const named = new Map<string, SyntaxNode>()
    let group: SyntaxNode[] = []
    const flush = (): void => {
      if (group.length === 1) positional.push(group[0]!)
      if (group.length === 3 && group[0]!.name === "VariableName" && text(group[1]!) === "=") named.set(text(group[0]!), group[2]!)
      group = []
    }
    for (let node = call.getChild("ArgList")?.firstChild; node; node = node.nextSibling) {
      if ([",", ")"].includes(node.name)) flush()
      else if (node.name !== "(" && !node.type.isError) group.push(node)
    }
    flush()
    return { positional, named }
  }
  const value = (node: SyntaxNode | null | undefined): Value | undefined => {
    if (!node) return
    if (node.name === "VariableName") return bindings.get(text(node))
    if (node.name === "String" && !node.firstChild) {
      // Only complete ordinary/raw literals. Escape sequences we cannot prove stay unknown.
      const match = /^([rR]?)(['"])([\s\S]*)\2$/.exec(text(node))
      if (!match || (!match[1] && /\\[^\\'"]/.test(match[3]!))) return
      return { kind: "string", text: match[1] ? match[3]! : match[3]!.replace(/\\([\\'"])/g, "$1") }
    }
    if (node.name === "CallExpression" && ["Path", "pathlib.Path"].includes(text(node.firstChild))) {
      const path = value(args(node).positional[0])
      if (path) return { kind: "path", text: path.text }
    }
    return
  }
  const add = (kind: ToolIntent["kind"], target?: Value): void => {
    const label = target && clean(target.text)
    if (label) intents.push({ kind, target: label })
  }
  const visit = (node: SyntaxNode): void => {
    // Definitions/control flow do not establish that their body is about to run.
    if (["FunctionDefinition", "ClassDefinition", "IfStatement", "ForStatement", "WhileStatement", "LambdaExpression"].includes(node.name)) return
    if (node.name === "AssignStatement") {
      const name = node.firstChild
      if (name?.name === "VariableName") {
        const assigned = text(name.nextSibling) === "=" ? value(name.nextSibling?.nextSibling) : undefined
        if (assigned) bindings.set(text(name), assigned)
        else bindings.delete(text(name))
      }
    }
    if (node.name === "CallExpression") {
      const callee = node.firstChild
      const name = text(callee)
      const { positional, named } = args(node)
      const first = value(positional[0] ?? named.get("path") ?? named.get("file"))
      if (name === "edit") add("edit", first)
      else if (name === "read") add("read", first)
      else if (name === "sh") add("run", value(positional[0] ?? named.get("command")))
      else if (name === "open") {
        const mode = value(positional[1] ?? named.get("mode"))
        if (mode && /^[rwaxbt+]+$/.test(mode.text)) add(/[wax+]/.test(mode.text) ? "write" : "read", first)
      } else if (callee?.name === "MemberExpression") {
        const path = value(callee.firstChild)
        const method = text(callee.getChild("PropertyName"))
        if (path?.kind === "path") {
          if (["write_text", "write_bytes"].includes(method)) add("write", path)
          if (["read_text", "read_bytes"].includes(method)) add("read", path)
          if (method === "open") {
            const mode = value(positional[0] ?? named.get("mode"))
            if (mode && /^[rwaxbt+]+$/.test(mode.text)) add(/[wax+]/.test(mode.text) ? "write" : "read", path)
          }
        }
      }
    }
    for (let child = node.firstChild; child; child = child.nextSibling) visit(child)
  }
  for (let statement = tree.topNode.firstChild; statement; statement = statement.nextSibling) {
    if (statement.name === "Comment") continue
    intents.length = 0
    visit(statement)
  }
  return intents.at(-1)
}

/** Publish a bounded live code tail. The UI owns terminal-width paging. */
export function createToolProgressReporter(publish: (progress: ToolProgress | null) => void):
  (call: ToolCallAssembly | null, phase: ToolProgress["phase"]) => void {
  let previous: ToolProgress | null = null
  let decoder: JSONParser | undefined
  let raw = ""
  let code = ""
  let invalid = false
  let parsedLength = -1
  let tree: Tree | undefined
  const reset = (): void => {
    decoder = undefined
    raw = code = ""
    invalid = false
    parsedLength = -1
    tree = undefined
  }
  return (call, phase) => {
    if (!call) {
      if (previous) publish(null)
      previous = null
      reset()
      return
    }
    const name = clean(call.function.name).slice(0, 100)
    if (!name) return
    const callId = call.id.slice(0, 200)
    const sameCall = previous?.callId === callId && previous.name === name
    const args = call.function.arguments
    const continued = sameCall && args.startsWith(raw)
    if (!continued) reset()
    if (name === "python" && !invalid && args.length > raw.length) {
      if (!decoder) {
        decoder = new JSONParser({ paths: ["$.code"], keepStack: false, emitPartialTokens: true, emitPartialValues: true })
        decoder.onValue = ({ value }) => { if (typeof value === "string") code = value }
        decoder.onError = () => { invalid = true; code = "" }
      }
      decoder.write(args.slice(raw.length))
      raw = args
    }
    let intent = continued ? previous?.intent : undefined
    // Follow later actions in the same cell, including after a large file body.
    // Reuse the completed syntax prefix; never parse a raw tail inside a string as Python.
    if (code.length !== parsedLength) {
      const fragments = tree && code.length >= parsedLength ? TreeFragment.applyChanges(TreeFragment.addTree(tree), [
        { fromA: parsedLength, toA: parsedLength, fromB: parsedLength, toB: code.length },
      ]) : []
      try {
        tree = parser.parse(code, fragments)
        intent = pythonIntent(code, tree)
      } catch { tree = undefined; intent = undefined }
      parsedLength = code.length
    }
    let offset = Math.max(0, code.length - 512)
    // A tail must not start halfway through a UTF-16 surrogate pair.
    if (/[\uDC00-\uDFFF]/.test(code[offset] ?? "")) offset++
    const preview = code.slice(offset).replace(/[\p{Cc}\p{Cf}]/gu, match => " ".repeat(match.length))
    const next: ToolProgress = {
      callId, name, phase, ...(intent ? { intent } : {}),
      ...(phase === "generating" && preview ? { code: { offset, text: preview } } : {}),
    }
    if (JSON.stringify(next) !== JSON.stringify(previous)) publish(next)
    previous = next
  }
}
