import assert from "node:assert/strict"
import test from "node:test"
import { performance } from "node:perf_hooks"

// Test the installed patch, not a second implementation of its scheduler.
const { frameThrottle } = await import(new URL("./frame-throttle.js", import.meta.resolve("ink")).href) as {
  frameThrottle: (render: () => void, interval: number) => (() => void) & { flush(): void; cancel(): void }
}

test("ink's frame deadline is not postponed by continuous input", t => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 })
  t.mock.method(performance, "now", () => Date.now())
  const paints: { at: number; value: number }[] = []
  let value = 0
  const frame = frameThrottle(() => paints.push({ at: Date.now(), value }), 17)
  frame()
  for (let i = 0; i < 4; i++) { t.mock.timers.tick(4); value++; frame() }
  assert.deepEqual(paints, [{ at: 0, value: 0 }])
  t.mock.timers.tick(1)
  assert.deepEqual(paints, [{ at: 0, value: 0 }, { at: 17, value: 4 }])
  t.mock.timers.tick(100)
  assert.equal(paints.length, 2, "idle screens do not keep a frame timer alive")
  value++; frame()
  assert.deepEqual(paints.at(-1), { at: 117, value: 5 }, "first input after idle is immediate")
})

test("ink flush and cancel settle the latest frame exactly once", t => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 })
  t.mock.method(performance, "now", () => Date.now())
  let paints = 0
  const frame = frameThrottle(() => { paints++ }, 17)
  frame(); frame(); frame()
  frame.flush(); frame.flush()
  t.mock.timers.tick(100)
  assert.equal(paints, 2)
  frame(); frame(); frame.cancel()
  t.mock.timers.tick(100)
  frame.flush()
  assert.equal(paints, 3, "unmount cannot paint a cancelled frame later")
  frame()
  assert.equal(paints, 4)
})
