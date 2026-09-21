import assert from "node:assert/strict"
import test from "node:test"
import { MouseInput } from "./mouse.js"

test("mouse decoding preserves wheel, drag, release and fragmented reports", () => {
  const mouse = new MouseInput()
  assert.equal(mouse.read("hello"), null)
  assert.deepEqual(mouse.read("[<64;2;10M"), [{ button: 64, x: 2, y: 10, press: true, motion: false }])
  assert.deepEqual(mouse.read("\x1b[<81;2;10M"), [{ button: 65, x: 2, y: 10, press: true, motion: false }])
  assert.deepEqual(mouse.read("[<32;2"), [])
  assert.deepEqual(mouse.read(";10M\x1b[<0;4;11m"), [
    { button: 0, x: 2, y: 10, press: true, motion: true },
    { button: 0, x: 4, y: 11, press: false, motion: false },
  ])
  assert.deepEqual(mouse.read("[<64;0;10M"), [])
  assert.equal(mouse.read("ordinary text"), null)
})
