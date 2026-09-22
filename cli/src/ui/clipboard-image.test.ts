import assert from "node:assert/strict"
import test from "node:test"
import {
  ClipboardImageError,
  MAX_CLIPBOARD_IMAGE_BYTES,
  clipboardHasImage,
  readClipboardImage,
  validateClipboardImage,
} from "./clipboard-image.js"

const png = (width = 2, height = 3): Buffer => {
  const bytes = Buffer.alloc(24)
  Buffer.from("89504e470d0a1a0a", "hex").copy(bytes)
  bytes.writeUInt32BE(13, 8)
  bytes.write("IHDR", 12, "ascii")
  bytes.writeUInt32BE(width, 16)
  bytes.writeUInt32BE(height, 20)
  return bytes
}
const ok = (stdout: Uint8Array | string) => ({
  status: 0,
  stdout: typeof stdout === "string" ? Buffer.from(stdout) : stdout,
})
const unavailable = () => ({ status: 1, stdout: Buffer.alloc(0) })

const errorCode = (run: () => unknown): string | undefined => {
  try { run() } catch (error) { return error instanceof ClipboardImageError ? error.code : undefined }
}

test("validates magic-derived MIME, byte count, and dimensions", () => {
  const bytes = png(640, 480)
  assert.deepEqual(validateClipboardImage(bytes), {
    mimeType: "image/png",
    data: bytes.toString("base64"),
    width: 640,
    height: 480,
    bytes: 24,
  })
})

test("rejects malformed, unsupported, oversized, and excessive-pixel headers", () => {
  assert.equal(errorCode(() => validateClipboardImage(Buffer.from("not an image"))), "malformed")
  assert.equal(errorCode(() => validateClipboardImage(Buffer.from("47494638396101000100", "hex"))), "unsupported")
  assert.equal(errorCode(() => validateClipboardImage(Buffer.alloc(MAX_CLIPBOARD_IMAGE_BYTES + 1))), "too_large")
  assert.equal(errorCode(() => validateClipboardImage(png(10_000, 5_000))), "dimensions")
})

test("clipboard hint checks only bounded format metadata", () => {
  const calls: Array<{ command: string; args: readonly string[]; maxBuffer: number }> = []
  const available = clipboardHasImage({
    platform: "linux",
    env: { WAYLAND_DISPLAY: "wayland-0" },
    nativeClipboard: { hasImage: () => { throw new Error("native should not be inspected") } },
    execute: (command, args, maxBuffer) => {
      calls.push({ command, args, maxBuffer })
      return command === "wl-paste" ? ok("text/plain\nimage/png\n") : unavailable()
    },
  })
  assert.equal(available, true)
  assert.deepEqual(calls, [{ command: "wl-paste", args: ["--list-types"], maxBuffer: 64 * 1024 }])
})

test("explicit Wayland paste fetches bounded bytes and trusts the image header over the MIME hint", async () => {
  const bytes = png(8, 9)
  const calls: Array<{ command: string; args: readonly string[]; maxBuffer: number }> = []
  const image = await readClipboardImage({
    platform: "linux",
    env: { WAYLAND_DISPLAY: "wayland-0" },
    execute: (command, args, maxBuffer) => {
      calls.push({ command, args, maxBuffer })
      return args[0] === "--list-types" ? ok("image/jpeg\n") : ok(bytes)
    },
  })
  assert.equal(image?.mimeType, "image/png")
  assert.equal(image?.width, 8)
  assert.deepEqual(calls.map(call => [call.command, call.args]), [
    ["wl-paste", ["--list-types"]],
    ["wl-paste", ["--type", "image/jpeg", "--no-newline"]],
  ])
  assert.equal(calls[1]?.maxBuffer, MAX_CLIPBOARD_IMAGE_BYTES + 1)
})

test("X11 is the Wayland fallback and uses fixed argv", async () => {
  const bytes = png()
  const image = await readClipboardImage({
    platform: "linux",
    env: { WAYLAND_DISPLAY: "wayland-0", DISPLAY: ":0" },
    execute: (command, args) => {
      if (command === "wl-paste") return unavailable()
      if (args.includes("TARGETS")) return ok("image/webp\nimage/png\n")
      assert.deepEqual(args, ["-selection", "clipboard", "-t", "image/png", "-o"])
      return ok(bytes)
    },
  })
  assert.equal(image?.mimeType, "image/png")
})

test("remote sessions neither probe nor read a host clipboard", async () => {
  let calls = 0
  const options = {
    platform: "linux" as const,
    env: { SSH_CONNECTION: "remote" },
    nativeClipboard: { hasImage: () => { calls++; return true } },
    nativeModulePath: "/clipboard.js",
    execute: () => { calls++; return ok(png()) },
  }
  assert.equal(clipboardHasImage(options), false)
  assert.equal(await readClipboardImage(options), null)
  assert.equal(calls, 0)
})

test("an over-limit command result is rejected before base64 retention", async () => {
  await assert.rejects(readClipboardImage({
    platform: "linux",
    env: { WAYLAND_DISPLAY: "wayland-0" },
    execute: (_command, args) => args[0] === "--list-types"
      ? ok("image/png\n")
      : { status: null, stdout: Buffer.alloc(0), error: Object.assign(new Error("maxBuffer"), { code: "ENOBUFS" }) },
  }), (error: unknown) => error instanceof ClipboardImageError && error.code === "too_large")
})
