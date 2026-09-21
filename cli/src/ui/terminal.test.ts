import assert from "node:assert/strict"
import test from "node:test"
import { PassThrough } from "node:stream"
import { setImmediate as immediate } from "node:timers/promises"
import { createElement } from "react"
import { render } from "ink"
import headless from "@xterm/headless"
import type { ChatClient, StreamEvent } from "../client.js"
import { ChatScreen } from "./chat.js"
import { terminalRendering } from "./terminal-rendering.js"

test("incremental terminal output survives reflow with its composer and history anchor intact", async t => {
  const terminal = new headless.Terminal({ cols: 100, rows: 30, allowProposedApi: true, convertEol: true })
  const stdin = Object.assign(new PassThrough(), { isTTY: true, setRawMode: () => stdin, ref: () => stdin, unref: () => stdin }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), { isTTY: true, columns: 100, rows: 30 }) as unknown as NodeJS.WriteStream
  stdout.on("data", (data: Buffer) => terminal.write(data))
  let emit!: (event: StreamEvent) => void
  let connect!: () => void
  const connected = new Promise<void>(resolve => { connect = resolve })
  const transport: ChatClient = {
    send: async () => ({ ok: true }), getStatus: async () => ({ running: false, idle: true }),
    stream: async ({ onEvent, signal, onOpen }) => {
      emit = onEvent; onOpen?.(); connect()
      await new Promise<void>(resolve => signal?.addEventListener("abort", () => resolve(), { once: true }))
    },
  }
  const app = render(createElement(ChatScreen, {
    transport, agentName: "niri", workspace: "/a/very/long/workspace/path", model: "openai-codex/gpt-5.6-luna",
    onBack() {}, onQuit() {}, settleMs: 100_000,
  }), { stdin, stdout, patchConsole: false, exitOnCtrlC: false, ...terminalRendering })
  t.after(() => { app.unmount(); terminal.dispose() })
  const flush = async () => {
    await immediate(); await app.waitUntilRenderFlush(); await immediate(); await app.waitUntilRenderFlush()
    await new Promise<void>(resolve => terminal.write("", resolve))
  }
  const frame = () => Array.from({ length: terminal.rows }, (_, row) => terminal.buffer.active.getLine(terminal.buffer.active.viewportY + row)!.translateToString(true))
  await connected
  for (let id = 0; id < 100; id++) emit({ type: "message", role: "assistant", text: `record ${id}\n` + "context and behavior remain unchanged. ".repeat(4) })
  await flush()
  stdin.write("\x1b[5~"); await flush()
  stdin.write("draft remains"); await flush()
  const anchor = frame().join("\n").match(/record \d+/)?.[0]
  assert.ok(anchor)
  for (const [width, height] of [[52, 30], [80, 40], [40, 20], [100, 30]] as const) {
    terminal.resize(width, height)
    stdout.columns = width
    stdout.rows = height
    stdout.emit("resize")
    await flush()
    const lines = frame()
    assert.match(lines[0]!, /niri/, `header at ${width}: ${lines.join("\n")}`)
    assert.equal(lines[1], "", "reflowed old content cannot survive in the header gap")
    assert.match(lines[height - 2]!, /› draft remains/, `composer at ${width}: ${lines.join("\n")}`)
    assert.match(lines[height - 1]!, /\/ commands/)
    assert.equal(lines.join("\n").match(/record \d+/)?.[0], anchor, `history anchor at ${width}`)
    stdin.write("\x1b[<64;10;8M\x1b[<65;10;8M"); await flush()
    assert.match(frame()[height - 2]!, /› draft remains/, "unchanged rows still occupy their correct positions")
  }
})
