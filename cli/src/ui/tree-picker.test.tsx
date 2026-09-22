import assert from "node:assert/strict"
import { PassThrough } from "node:stream"
import test from "node:test"
import { render } from "ink"
import { TreePicker, type TreePage, type TreePickerProps } from "./tree-picker.js"

const stripAnsi = (value: string): string => value.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")

const terminal = () => {
  const stdin = Object.assign(new PassThrough(), {
    isTTY: true,
    setRawMode: () => stdin,
    ref: () => stdin,
    unref: () => stdin,
  }) as unknown as NodeJS.ReadStream
  const stdout = Object.assign(new PassThrough(), {
    isTTY: true,
    columns: 200,
    rows: 30,
  }) as unknown as NodeJS.WriteStream
  return { stdin, stdout }
}

const page: TreePage = {
  items: [
    { id: 10, type: "user", preview: "first request" },
    { id: 11, type: "assistant", preview: "a careful answer" },
    { id: 12, type: "tool", preview: "read src/main.gleam" },
  ],
  hasPrevious: true,
  hasNext: true,
}

const callbacks = (overrides: Partial<TreePickerProps> = {}): TreePickerProps => ({
  page,
  onPrevious: () => {},
  onNext: () => {},
  onFork: () => {},
  onCancel: () => {},
  ...overrides,
})

const mount = (props: TreePickerProps) => {
  const tty = terminal()
  let painted = ""
  tty.stdout.on("data", (chunk: Buffer) => { painted += chunk.toString() })
  const app = render(<TreePicker {...props} />, {
    stdin: tty.stdin,
    stdout: tty.stdout,
    patchConsole: false,
    exitOnCtrlC: false,
  })
  const frame = (): string => stripAnsi(painted)
  const clear = (): void => { painted = "" }
  const write = async (input: string): Promise<void> => {
    clear()
    tty.stdin.write(input)
    await app.waitUntilRenderFlush()
  }
  return { app, frame, clear, write }
}

test("tree rows stay chronological and turn untrusted long text into a bounded one-line preview", t => {
  const long = `line one\nline two ${"x".repeat(140)}`
  const view = mount(callbacks({ page: {
    ...page,
    items: [
      page.items[0]!,
      { id: 11, type: "assistant", preview: long },
      page.items[2]!,
    ],
  } }))
  t.after(() => view.app.unmount())

  const screen = view.frame()
  assert(screen.indexOf("user") < screen.indexOf("assistant"))
  assert(screen.indexOf("assistant") < screen.indexOf("tool"))
  assert(screen.includes("line one line two"))
  assert(screen.includes("…"), "a long preview should visibly disclose truncation")
  assert(!screen.includes("x".repeat(100)), "a long preview leaked past its bound")
})

test("enter asks before forking and the second enter confirms the selected checkpoint", async t => {
  const forked: number[] = []
  const view = mount(callbacks({ onFork: checkpoint => { forked.push(checkpoint.id) } }))
  t.after(() => view.app.unmount())

  await view.write("\x1b[B")
  assert(view.frame().includes("> assistant"))
  await view.write("\r")
  assert.deepEqual(forked, [], "the first enter must not fork")
  assert(view.frame().includes("branch after assistant · a careful answer?"))
  assert(view.frame().includes("new session · fresh python namespace · workspace files stay unchanged"))
  await view.write("\r")
  assert.deepEqual(forked, [11])
  assert(view.frame().includes("creating branch…"))
})

test("escape cancels confirmation before a second escape closes the overlay", async t => {
  let cancelled = 0
  const view = mount(callbacks({ onCancel: () => { cancelled++ } }))
  t.after(() => view.app.unmount())

  await view.write("\r")
  assert(view.frame().includes("enter confirm · esc cancel"))
  await view.write("\x1b")
  assert.equal(cancelled, 0)
  assert(!view.frame().includes("new session · fresh python namespace"))
  await new Promise(resolve => setTimeout(resolve, 20))
  await view.write("\x1b")
  await new Promise(resolve => setTimeout(resolve, 20))
  assert.equal(cancelled, 1)
})

test("left and right request only available history pages", async t => {
  let previous = 0, next = 0
  const view = mount(callbacks({
    onPrevious: () => { previous++ },
    onNext: () => { next++ },
  }))
  t.after(() => view.app.unmount())

  await view.write("\x1b[C")
  await view.write("\x1b[D")
  assert.deepEqual({ previous, next }, { previous: 1, next: 1 })

  view.app.rerender(<TreePicker {...callbacks({ page: { ...page, hasPrevious: false, hasNext: false },
    onPrevious: () => { previous++ }, onNext: () => { next++ } })} />)
  await view.app.waitUntilRenderFlush()
  await view.write("\x1b[C")
  await view.write("\x1b[D")
  assert.deepEqual({ previous, next }, { previous: 1, next: 1 })
})

test("loading, request failure, and an empty history each have a distinct state", async t => {
  const base = callbacks({ page: undefined, loading: true })
  const view = mount(base)
  t.after(() => view.app.unmount())
  assert(view.frame().includes("loading history…"))

  view.clear()
  view.app.rerender(<TreePicker {...base} loading={false} error="history request failed; retry /tree" />)
  await view.app.waitUntilRenderFlush()
  assert(view.frame().includes("history request failed; retry /tree"))
  assert(!view.frame().includes("loading history…"))

  view.clear()
  view.app.rerender(<TreePicker {...base} loading={false} error="" page={{ items: [], hasPrevious: false, hasNext: false }} />)
  await view.app.waitUntilRenderFlush()
  assert(view.frame().includes("no branchable history in this session"))
})
