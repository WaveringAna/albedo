import assert from "node:assert/strict"
import test from "node:test"
import { PassThrough } from "node:stream"
import { createElement, type ReactElement } from "react"
import { render } from "ink"
import { ChatScreen } from "./chat.js"
import { WorkspaceMissingError, type StreamEvent, type StreamOptions } from "../client.js"
const NO_CLIPBOARD_IMAGES = { available: () => false, read: async () => null }
const strip = (text: string): string => text.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")
const tick = (): Promise<void> => new Promise((resolve) => { setTimeout(resolve, 5) })
const until = async (ready: () => boolean, what: string): Promise<void> => {
  for (let attempt = 0; attempt < 400; attempt++) { if (ready()) return; await tick() }
  throw new Error(`timed out waiting for ${what}`)
}

type Screen = { last: () => string; all: () => string; raw: () => string; shows: (text: string) => Promise<void>; write: (text: string) => void; flush: () => Promise<void>; unmount: () => void }

/** Mount a screen on injected streams that look like a terminal to Ink. */
const mount = (node: ReactElement, t: { after: (fn: () => void) => void }, columns = 80): Screen => {
  const stdin = Object.assign(new PassThrough(), { isTTY: true, setRawMode: () => stdin, ref: () => stdin, unref: () => stdin }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), { isTTY: true, columns, rows: 24 }) as unknown as NodeJS.WriteStream
  const frames: string[] = []
  ;(stdout as unknown as PassThrough).on("data", (chunk: Buffer) => { frames.push(String(chunk)) })
  const app = render(node, { stdin, stdout, patchConsole: false, exitOnCtrlC: false })
  t.after(() => { app.unmount() })
  // Ink brackets every frame with erase-only writes; the last painted frame is the screen.
  const painted = (): string => strip([...frames].reverse().find((frame) => strip(frame).trim()) ?? "")
  const screen: Screen = {
    last: painted,
    all: () => strip(frames.join("")),
    shows: (text) => until(() => screen.all().includes(text), `screen text ${JSON.stringify(text)}`),
    raw: () => frames.join(""),
    write: (text) => { stdin.write(text) },
    // Two writes in one tick reach Ink as one paste-sized chunk; a person types
    // the text and presses enter in separate turns, so flush between them.
    flush: () => app.waitUntilRenderFlush(),
    unmount: () => app.unmount(),
  }
  return screen
}


test("ctrl+j toggles rich edit diffs without submitting the composer", async t => {
  let stream: StreamOptions | undefined
  let sends = 0
  const screen = mount(createElement(ChatScreen, {
    clipboardImages: NO_CLIPBOARD_IMAGES,
    transport: { send: async () => { sends++; return { ok: true as const } }, getStatus: async () => ({ running: false, idle: true }),
      stream: async options => { stream = options; options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) } },
    model: "fixture", onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t, 100)
  await until(() => stream !== undefined, "connected")
  stream!.onEvent({ type: "tool", name: "python", args: {}, result: "ok", trace: {
    activities: [{ kind: "read", target: "sample.py" }],
    changes: [{ kind: "diff", path: "sample.py", added: 1, removed: 1, diff: "@@ -1 +1 @@\n-old\n+new" }],
  } })
  await until(() => screen.last().includes("read + edited sample.py") && !screen.last().includes("1 + new"), "compact edit")
  screen.write("\n") // Legacy Ctrl+J sends LF; Return sends CR.
  await until(() => screen.last().includes("1 + new"), "diff expanded")
  assert.equal(sends, 0)
  screen.write("\n")
  await until(() => !screen.last().includes("1 + new"), "diff collapsed")
})

test("copied chat screen renders Python activity and reset replaces history",async t=>{
  let stream:StreamOptions|undefined
  let running=true
  const screen=mount(createElement(ChatScreen,{
    transport:{ clientId:"test",send:async()=>({ok:true as const}),getStatus:async()=>({running,idle:!running}),
      stream:async options=>{stream=options;options.onOpen?.();await new Promise<void>(resolve=>options.signal?.addEventListener("abort",()=>resolve(),{once:true}))}},
    agentName:"albedo",workspace:"/workspace",model:"fixture",onBack:()=>{},onQuit:()=>{},settleMs:20,
  }),t)
  await until(()=>stream!==undefined,"stream connected")
  const emit=(event:StreamEvent):void=>stream!.onEvent(event)
  emit({type:"tool_progress",progress:{callId:"cell",name:"python",phase:"generating",code:{offset:0,text:"Path('example.py').read_text()"},intent:{kind:"read",target:"example.py"}}})
  await screen.shows("example.py")
  emit({type:"tool",name:"python",args:{code:"Path('example.py').read_text()"},result:"ok",trace:{activities:[{kind:"read",target:"example.py"}],changes:[]}})
  emit({type:"message",role:"assistant",text:"old history"})
  running=false
  await screen.shows("old history")
  emit({type:"reset"})
  emit({type:"message",role:"assistant",text:"restored history"})
  await screen.shows("restored history")
  await until(()=>!screen.last().includes("old history"),"old history removed")
})

test("history scrolls with arrows, pages and wheel without losing its place to new output",async t=>{
  let stream:StreamOptions|undefined
  const screen=mount(createElement(ChatScreen,{
    transport:{ clientId:"test",send:async()=>({ok:true as const}),getStatus:async()=>({running:false,idle:true}),
      stream:async options=>{stream=options;options.onOpen?.();await new Promise<void>(resolve=>options.signal?.addEventListener("abort",()=>resolve(),{once:true}))}},
    agentName:"albedo",onBack:()=>{},onQuit:()=>{},settleMs:20,
  }),t)
  await until(()=>stream!==undefined,"stream connected")
  for(let i=0;i<60;i++) stream!.onEvent({type:"message",role:"assistant",text:`history record ${String(i).padStart(2,"0")}`})
  await until(()=>screen.last().includes("history record 59"),"tail visible")
  screen.write("\x1b[A")
  await until(()=>screen.last().includes("history · 1 rows below"),"up arrow scrolls a row")
  screen.write("\x1b[B")
  await until(()=>!screen.last().includes("rows below"),"down arrow follows the tail again")
  screen.write("\x1b[5~")
  await until(()=>screen.last().includes("rows below"),"page up")
  const before=screen.last().match(/history record \d+/g)
  const distance=Number(screen.last().match(/history · (\d+) rows below/)?.[1])
  assert(before?.length)
  stream!.onEvent({type:"message",role:"assistant",text:"new incoming record"})
  await until(()=>Number(screen.last().match(/history · (\d+) rows below/)?.[1])>distance,"append rendered")
  assert.deepEqual(screen.last().match(/history record \d+/g),before,"new output moved the anchored viewport")
  screen.write("\x1b[1;5F")
  await until(()=>screen.last().includes("new incoming record") && !screen.last().includes("rows below"),"ctrl-end follows live output")
  assert(screen.raw().includes("\x1b[?1002h"),"drag and wheel reporting is enabled by default")
  screen.write("\x1b[<64;10;10M")
  await until(()=>screen.last().includes("history · 3 rows below"),"wheel up")
  screen.write("\x1b[<65;10;10M")
  await until(()=>!screen.last().includes("rows below"),"wheel down")
  assert(!screen.last().includes("64;10;10"),"wheel report reached the draft")
})

test("drag highlights and copies text while wheel scrolling stays enabled",async t=>{
  let stream:StreamOptions|undefined
  const copied:string[]=[]
  const screen=mount(createElement(ChatScreen,{
    transport:{ clientId:"test",send:async()=>({ok:true as const}),getStatus:async()=>({running:false,idle:true}),
      stream:async options=>{stream=options;options.onOpen?.();await new Promise<void>(resolve=>options.signal?.addEventListener("abort",()=>resolve(),{once:true}))}},
    copySelection:async text=>{copied.push(text)},
    agentName:"albedo",onBack:()=>{},onQuit:()=>{},settleMs:20,
  }),t)
  await until(()=>stream!==undefined,"stream connected")
  stream!.onEvent({type:"message",role:"assistant",text:"select this exact text"})
  await until(()=>screen.last().includes("select this exact text"),"text visible")
  // Header row 1, spacer row 2, speaker row 3, message row 4; two columns of padding.
  screen.write("\x1b[<0;3;4M")
  screen.write("\x1b[<32;9;4M")
  await until(()=>screen.raw().includes("\x1b[7m"),"selection highlight")
  stream!.onEvent({type:"message",role:"assistant",text:"later streaming content"})
  await tick()
  assert(!screen.last().includes("later streaming content"),"stream moved text during a drag")
  screen.write("\x1b[<0;9;4m")
  await until(()=>copied.length===1,"copy on release")
  assert.deepEqual(copied,["select"])
  await until(()=>screen.last().includes("later streaming content"),"stream continues after release")
  for(let i=0;i<30;i++) stream!.onEvent({type:"message",role:"assistant",text:`following row ${i}`})
  screen.write("\x1b[1;5F")
  await until(()=>screen.last().includes("following row 29"),"tail after selection")
  screen.write("\x1b[<64;8;10M")
  await until(()=>screen.last().includes("rows below"),"wheel still scrolls without a toggle")
})


test("chat footer shows only command/copy hints and restores usage after a snapshot reset", async t => {
  let stream: StreamOptions | undefined
  const screen = mount(createElement(ChatScreen, {
    clipboardImages: NO_CLIPBOARD_IMAGES,
    transport: { send: async () => ({ ok: true as const }), getStatus: async () => ({ running: false, idle: true }),
      stream: async options => { stream = options; options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) } },
    model: "gpt-5", onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t, 120)
  await until(() => stream !== undefined, "connected")
  const usage: StreamEvent = { type: "usage", model: "gpt-5", promptTokens: 10000, completionTokens: 200, totalTokens: 10200, cachedPromptTokens: 8000, recordedAt: Date.now() }
  stream!.onEvent(usage)
  await until(() => screen.last().includes("cached 8,000/10,000"), "footer usage")
  assert(screen.last().includes("/ commands · drag to copy"))
  assert(screen.last().includes("ctx 10.2k"))
  assert(!screen.last().includes("wheel/"))
  assert(!screen.last().includes("ctrl-d detach"))
  stream!.onEvent({ type: "reset" })
  await until(() => screen.last().includes("cached —"), "old usage removed")
  stream!.onEvent(usage)
  await until(() => screen.last().includes("cached 8,000/10,000"), "usage restored")
})


test("confirmed user and streamed assistant headings get clocks without duplicates, including replay", async t => {
  let stream: StreamOptions | undefined
  const screen = mount(createElement(ChatScreen, {
    clipboardImages: NO_CLIPBOARD_IMAGES,
    transport: { clientId: "clock-client", send: async () => ({ ok: true as const }), getStatus: async () => ({ running: false, idle: true }),
      stream: async options => { stream = options; options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) } },
    agentName: "albedo", onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t, 140)
  await until(() => stream !== undefined, "connected")
  screen.write("question")
  await tick()
  screen.write("\r")
  await until(() => screen.last().includes("you"), "optimistic question")
  const timestamp = new Date(2026, 8, 21, 0, 58, 30).getTime()
  const user: StreamEvent = { type: "user", text: "question", source: "chat", triggeredAt: "", clientId: "clock-client", timestamp }
  stream!.onEvent(user)
  stream!.onEvent({ type: "text", text: "the answer" })
  await until(() => screen.last().includes("the answer"), "streamed answer")
  const assistant: StreamEvent = { type: "message", role: "assistant", text: "the answer", timestamp: timestamp + 1000 }
  stream!.onEvent(assistant)
  await until(() => screen.last().includes("00:58:31"), "confirmed answer clock")
  assert.equal(screen.last().split("question").length - 1, 1)
  assert.equal(screen.last().split("the answer").length - 1, 1)
  for (const clock of ["00:58:30", "00:58:31"]) {
    const line = screen.last().split("\n").find(line => line.includes(clock))!
    assert.equal(line.indexOf(clock), 130) // 140 columns minus two padding cells and 8 clock cells
  }
  screen.write("/t")
  await tick()
  screen.write("\r")
  await until(() => screen.last().includes("thinking off"), "thinking disabled")
  screen.write("/v")
  await tick()
  screen.write("\r")
  await until(() => screen.last().includes("verbose on"), "verbose enabled")
  stream!.onEvent({ type: "reset" })
  stream!.onEvent(user)
  stream!.onEvent(assistant)
  await until(() => screen.last().includes("00:58:31") && screen.last().includes("question"), "replayed clocks and own user")
  assert.equal(screen.last().split("question").length - 1, 1)
  assert.equal(screen.last().split("the answer").length - 1, 1)
})

test("missing workspace asks for a replacement and retries only after confirmation", async t => {
  const sent: string[] = []
  const replacements: string[] = []
  const updated: string[] = []
  const screen = mount(createElement(ChatScreen, {
    clipboardImages: NO_CLIPBOARD_IMAGES,
    transport: {
      send: async content => {
        sent.push(content)
        if (sent.length === 1) throw new WorkspaceMissingError("/old/missing")
        return { ok: true as const }
      },
      replaceWorkspace: async workspace => { replacements.push(workspace); return { workspace: `${workspace}/` } },
      getStatus: async () => ({ running: false, idle: true }),
      stream: async options => { options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) },
    },
    workspace: "/old/missing", agentName: "albedo", onWorkspaceChanged: workspace => { updated.push(workspace) },
    onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t)

  await until(() => screen.last().includes("ready"), "chat ready")
  screen.write("finish the task")
  await screen.flush()
  screen.write("\r")
  await until(() => screen.last().includes("workspace not found: /old/missing"), "workspace recovery form")
  assert.deepEqual(sent, ["finish the task"])
  assert.deepEqual(replacements, [])
  screen.write("\u0015")
  await screen.flush()
  screen.write("/new/workspace")
  await screen.flush()
  screen.write("\r")
  await until(() => sent.length === 2, "original prompt retried")
  assert.deepEqual(replacements, ["/new/workspace"])
  assert.deepEqual(updated, ["/new/workspace/"], "session metadata comes from the daemon")
  assert.deepEqual(sent, ["finish the task", "finish the task"])
  await until(() => !screen.last().includes("workspace not found"), "recovery form closed")
})

test("canceling workspace recovery preserves the chat and unsent prompt", async t => {
  let stream: StreamOptions | undefined
  let replacements = 0
  const screen = mount(createElement(ChatScreen, {
    clipboardImages: NO_CLIPBOARD_IMAGES,
    transport: {
      send: async () => { throw new WorkspaceMissingError("/gone") },
      replaceWorkspace: async workspace => { replacements++; return { workspace } },
      getStatus: async () => ({ running: false, idle: true }),
      stream: async options => { stream = options; options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) },
    },
    workspace: "/gone", agentName: "albedo", onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t)
  await until(() => stream !== undefined, "stream connected")
  stream!.onEvent({ type: "message", role: "assistant", text: "existing chat stays here" })
  await screen.shows("existing chat stays here")
  await until(() => screen.last().includes("ready"), "chat ready")
  screen.write("unsent work")
  await screen.flush()
  screen.write("\r")
  await until(() => screen.last().includes("workspace not found: /gone"), "workspace recovery form")
  screen.write("\u001b")
  await until(() => !screen.last().includes("workspace not found"), "recovery canceled")
  assert(screen.last().includes("existing chat stays here"))
  assert(screen.last().includes("unsent work"))
  assert.equal(replacements, 0)
})

test("a rejected workspace stays open with the daemon's reason and the typed path", async t => {
  const attempts: string[] = []
  const screen = mount(createElement(ChatScreen, {
    clipboardImages: NO_CLIPBOARD_IMAGES,
    transport: {
      send: async () => { throw new WorkspaceMissingError("/gone") },
      replaceWorkspace: async workspace => {
        attempts.push(workspace)
        throw new Error("workspace must be an existing absolute directory")
      },
      getStatus: async () => ({ running: false, idle: true }),
      stream: async options => { options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) },
    },
    workspace: "/gone", agentName: "albedo", onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t)
  await until(() => screen.last().includes("ready"), "chat ready")
  screen.write("retry me")
  await screen.flush()
  screen.write("\r")
  await until(() => screen.last().includes("workspace not found: /gone"), "workspace recovery form")
  screen.write("\u0015")
  await screen.flush()
  screen.write("/relative")
  await screen.flush()
  screen.write("\r")
  await until(() => screen.last().includes("workspace must be an existing absolute directory"), "daemon reason")
  assert(screen.last().includes("new workspace › /relative"))
  screen.write("\u0015")
  await screen.flush()
  screen.write("/absolute/path")
  await screen.flush()
  screen.write("\r")
  await until(() => attempts.length === 2, "corrected path retried")
  assert.deepEqual(attempts, ["/relative", "/absolute/path"])
})

test("mouse reports never edit the workspace path while recovery is open", async t => {
  const screen = mount(createElement(ChatScreen, {
    clipboardImages: NO_CLIPBOARD_IMAGES,
    transport: {
      send: async () => { throw new WorkspaceMissingError("/gone") },
      replaceWorkspace: async workspace => ({ workspace }),
      getStatus: async () => ({ running: false, idle: true }),
      stream: async options => { options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) },
    },
    workspace: "/gone", agentName: "albedo", onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t)
  await until(() => screen.last().includes("ready"), "chat ready")
  screen.write("retry me")
  await screen.flush()
  screen.write("\r")
  await until(() => screen.last().includes("workspace not found: /gone"), "workspace recovery form")
  screen.write("\u001b[<64;10;10M")
  await screen.flush()
  screen.write("x")
  await until(() => screen.last().includes("new workspace › /gonex"), "path holds only typed text")
})

test("unmount aborts a hung status request", async t => {
  let requested = false
  let aborted = false
  const screen = mount(createElement(ChatScreen, {
    clipboardImages: NO_CLIPBOARD_IMAGES,
    transport: {
      send: async () => ({ ok: true as const }),
      getStatus: signal => new Promise((_resolve, reject) => {
        requested = true
        signal?.addEventListener("abort", () => { aborted = true; reject(signal.reason) }, { once: true })
      }),
      stream: async options => { options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) },
    },
    agentName: "albedo", onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t)
  await until(() => requested, "status request")
  screen.unmount()
  await until(() => aborted, "status abort")
})


test("ctrl-v previews a clipboard image, escape removes it, and submit sends it without auto-submit", async t => {
  const image = { mimeType: "image/png" as const, data: "aGVsbG8=", width: 2, height: 3, bytes: 5 }
  const sent: Array<{ content: string; image: typeof image | undefined }> = []
  let reads = 0
  const screen = mount(createElement(ChatScreen, {
    transport: {
      send: async (content, _signal, attachment) => { sent.push({ content, image: attachment as typeof image | undefined }); return { ok: true as const } },
      getStatus: async () => ({ running: false, idle: true }),
      stream: async options => { options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) },
    },
    clipboardImages: { available: () => true, read: async () => { reads++; return image } },
    onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t)
  await screen.shows("ctrl+v to paste image")
  screen.write("\x16")
  await screen.shows("PNG 2×3 · 5 B attached · esc remove")
  assert.equal(reads, 1)
  assert.equal(sent.length, 0, "pasting must not submit")
  screen.write("\x1b")
  await screen.shows("image removed")
  screen.write("\x16")
  await until(() => reads === 2, "second clipboard image read")
  await screen.shows("PNG 2×3 · 5 B attached · esc remove")
  screen.write("describe this")
  await screen.flush()
  screen.write("\r")
  await until(() => sent.length === 1, "image submission")
  assert.deepEqual(sent, [{ content: "describe this", image }])
  await screen.shows("[image · PNG 2×3 · 5 B]")
})

test("ordinary pasted text remains text when clipboard image metadata is absent", async t => {
  const sent: string[] = []
  const screen = mount(createElement(ChatScreen, {
    transport: {
      send: async content => { sent.push(content); return { ok: true as const } },
      getStatus: async () => ({ running: false, idle: true }),
      stream: async options => { options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) },
    },
    clipboardImages: { available: () => false, read: async () => { throw new Error("must not read image bytes") } },
    onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t)
  screen.write("pasted text")
  await screen.flush()
  screen.write("\r")
  await until(() => sent.length === 1, "text submission")
  assert.deepEqual(sent, ["pasted text"])
})


test("submit waits for an in-flight image read and uses the resolved attachment", async t => {
  const image = { mimeType: "image/png" as const, data: "aGVsbG8=", width: 2, height: 3, bytes: 5 }
  let resolveRead!: (value: typeof image | null) => void
  const reading = new Promise<typeof image | null>(resolve => { resolveRead = resolve })
  const sent: Array<{ content: string; image: typeof image | undefined }> = []
  const screen = mount(createElement(ChatScreen, {
    transport: {
      send: async (content, _signal, attachment) => { sent.push({ content, image: attachment as typeof image | undefined }); return { ok: true as const } },
      getStatus: async () => ({ running: false, idle: true }),
      stream: async options => { options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) },
    },
    clipboardImages: { available: () => true, read: () => reading },
    onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t)
  await screen.shows("ctrl+v to paste image")
  screen.write("\x16")
  await screen.shows("reading clipboard image…")
  screen.write("describe this")
  await screen.flush()
  screen.write("\r")
  await tick()
  assert.equal(sent.length, 0, "enter must wait for explicit paste acquisition")
  resolveRead(image)
  await until(() => sent.length === 1, "deferred image submission")
  assert.deepEqual(sent, [{ content: "describe this", image }])
})

test("image paste failure preserves draft text and ordinary submission", async t => {
  const sent: Array<{ content: string; image: unknown }> = []
  const screen = mount(createElement(ChatScreen, {
    transport: {
      send: async (content, _signal, image) => { sent.push({ content, image }); return { ok: true as const } },
      getStatus: async () => ({ running: false, idle: true }),
      stream: async options => { options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) },
    },
    clipboardImages: { available: () => true, read: async () => { throw new Error("clipboard permission denied") } },
    onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t)
  screen.write("keep this text")
  await screen.flush()
  screen.write("\x16")
  await screen.shows("image paste failed: clipboard permission denied")
  assert(screen.last().includes("keep this text"))
  screen.write("\r")
  await until(() => sent.length === 1, "text submission after image failure")
  assert.deepEqual(sent, [{ content: "keep this text", image: undefined }])
})

test("retry discards partial response previews without clearing the conversation", async t => {
  let stream: StreamOptions | undefined
  const screen = mount(createElement(ChatScreen, {
    clipboardImages: NO_CLIPBOARD_IMAGES,
    transport: { send: async () => ({ ok: true as const }), getStatus: async () => ({ running: true, idle: false }),
      stream: async options => { stream = options; options.onOpen?.(); await new Promise<void>(resolve => options.signal?.addEventListener("abort", () => resolve(), { once: true })) } },
    model: "gpt-5", onBack: () => {}, onQuit: () => {}, settleMs: 20,
  }), t, 120)
  await until(() => stream !== undefined, "connected")
  stream!.onEvent({ type: "text", text: "old partial" })
  stream!.onEvent({ type: "thinking", text: "old reasoning" })
  await until(() => screen.last().includes("old reasoning"), "partial")
  stream!.onEvent({ type: "retry" })
  stream!.onEvent({ type: "text", text: "new answer" })
  await until(() => screen.last().includes("new answer"), "retry answer")
  assert(!screen.last().includes("old partial"))
  assert(!screen.last().includes("old reasoning"))
})
