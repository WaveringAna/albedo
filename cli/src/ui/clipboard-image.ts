import { spawnSync } from "node:child_process"
import { createRequire } from "node:module"
import { imageSize } from "image-size"
import type { ImageAttachment } from "../image.js"

export const MAX_CLIPBOARD_IMAGE_BYTES = 5 * 1024 * 1024
export const MAX_CLIPBOARD_IMAGE_EDGE = 16_384
export const MAX_CLIPBOARD_IMAGE_PIXELS = 40_000_000

const METADATA_BYTES = 64 * 1024
const METADATA_TIMEOUT_MS = 1_000
const READ_TIMEOUT_MS = 3_000
const MIME_BY_TYPE = {
  png: "image/png",
  jpg: "image/jpeg",
  webp: "image/webp",
} as const
const PREFERRED_MIME_TYPES = Object.values(MIME_BY_TYPE)

export type ClipboardImageMimeType = typeof PREFERRED_MIME_TYPES[number]
export type ClipboardImage = ImageAttachment

export type ClipboardImageErrorCode = "too_large" | "malformed" | "unsupported" | "dimensions"

export class ClipboardImageError extends Error {
  readonly name = "ClipboardImageError"
  constructor(readonly code: ClipboardImageErrorCode, message: string) { super(message) }
}

type NativeClipboard = { hasImage(): boolean }
type CommandResult = { status: number | null; stdout: Uint8Array; error?: NodeJS.ErrnoException }
type Execute = (command: string, args: readonly string[], maxBuffer: number, timeout: number) => CommandResult

export type ClipboardImageOptions = {
  platform?: NodeJS.Platform
  env?: NodeJS.ProcessEnv
  execute?: Execute
  nativeClipboard?: NativeClipboard | null
  nativeModulePath?: string | null
}

const require = createRequire(import.meta.url)
const nativeModulePath = (() => {
  try { return require.resolve("@mariozechner/clipboard") }
  catch { return null }
})()

const execute: Execute = (command, args, maxBuffer, timeout) => {
  const result = spawnSync(command, [...args], {
    encoding: null,
    timeout,
    maxBuffer,
    windowsHide: true,
    stdio: ["ignore", "pipe", "ignore"],
  })
  return {
    status: result.status,
    stdout: result.stdout instanceof Uint8Array ? result.stdout : Buffer.alloc(0),
    ...(result.error ? { error: result.error } : {}),
  }
}

const remote = (env: NodeJS.ProcessEnv): boolean =>
  Boolean(env.SSH_CONNECTION || env.SSH_CLIENT || env.MOSH_CONNECTION)
const wayland = (env: NodeJS.ProcessEnv): boolean =>
  Boolean(env.WAYLAND_DISPLAY) || env.XDG_SESSION_TYPE === "wayland"
const successful = (result: CommandResult): boolean => result.status === 0 && !result.error
const exceededBuffer = (result: CommandResult): boolean =>
  result.error?.code === "ENOBUFS" || result.stdout.byteLength > MAX_CLIPBOARD_IMAGE_BYTES

const listedMimeTypes = (result: CommandResult): ClipboardImageMimeType[] => {
  if (!successful(result)) return []
  const offered = new Set(Buffer.from(result.stdout).toString("utf8").split(/\r?\n/)
    .map(value => value.split(";", 1)[0]?.trim().toLowerCase()))
  return PREFERRED_MIME_TYPES.filter(type => offered.has(type))
}

const clipboardTypes = (
  platform: NodeJS.Platform,
  env: NodeJS.ProcessEnv,
  run: Execute,
): { source: "wayland" | "x11"; types: ClipboardImageMimeType[] } | null => {
  if (platform !== "linux") return null
  if (wayland(env)) {
    const types = listedMimeTypes(run("wl-paste", ["--list-types"], METADATA_BYTES, METADATA_TIMEOUT_MS))
    if (types.length) return { source: "wayland", types }
  }
  if (env.DISPLAY || wayland(env)) {
    const types = listedMimeTypes(run("xclip", ["-selection", "clipboard", "-t", "TARGETS", "-o"], METADATA_BYTES, METADATA_TIMEOUT_MS))
    if (types.length) return { source: "x11", types }
  }
  return null
}

const configured = (options: ClipboardImageOptions) => ({
  platform: options.platform ?? process.platform,
  env: options.env ?? process.env,
  run: options.execute ?? execute,
  native: options.nativeClipboard ?? null,
  nativePath: options.nativeModulePath === undefined ? nativeModulePath : options.nativeModulePath,
})

const nativeAvailable = (path: string, run: Execute): boolean => {
  const result = run(
    process.execPath,
    ["-e", "const c=require(process.argv[1]);try{process.stdout.write(c.hasImage()?'1':'0')}catch{process.exit(1)}", path],
    1,
    METADATA_TIMEOUT_MS,
  )
  return successful(result) && Buffer.from(result.stdout).toString("ascii") === "1"
}

/** Checks clipboard format metadata only. It never fetches the image payload. */
export function clipboardHasImage(options: ClipboardImageOptions = {}): boolean {
  const { platform, env, run, native, nativePath } = configured(options)
  if (env.TERMUX_VERSION || remote(env)) return false
  const types = clipboardTypes(platform, env, run)
  if (types) return true
  if (platform === "linux" && (wayland(env) || !env.DISPLAY)) return false
  try { return native ? native.hasImage() === true : Boolean(nativePath && nativeAvailable(nativePath, run)) }
  catch { return false }
}

const readNative = (path: string, run: Execute): CommandResult => run(
  process.execPath,
  ["-e", "const c=require(process.argv[1]);Promise.resolve(c.getImageBinary()).then(b=>process.stdout.write(Buffer.from(b))).catch(()=>process.exit(1))", path],
  MAX_CLIPBOARD_IMAGE_BYTES + 1,
  READ_TIMEOUT_MS,
)

const readBytes = (options: ClipboardImageOptions): Uint8Array | null => {
  const { platform, env, run, native, nativePath } = configured(options)
  if (env.TERMUX_VERSION || remote(env)) return null
  const offered = clipboardTypes(platform, env, run)
  let result: CommandResult | null = null
  if (offered) {
    const mimeType = offered.types[0]!
    result = offered.source === "wayland"
      ? run("wl-paste", ["--type", mimeType, "--no-newline"], MAX_CLIPBOARD_IMAGE_BYTES + 1, READ_TIMEOUT_MS)
      : run("xclip", ["-selection", "clipboard", "-t", mimeType, "-o"], MAX_CLIPBOARD_IMAGE_BYTES + 1, READ_TIMEOUT_MS)
  } else if (!(platform === "linux" && (wayland(env) || !env.DISPLAY)) && nativePath) {
    try { if (!native || native.hasImage() === true) result = readNative(nativePath, run) }
    catch { return null }
  }
  if (!result) return null
  if (exceededBuffer(result)) throw new ClipboardImageError("too_large", `clipboard image exceeds ${MAX_CLIPBOARD_IMAGE_BYTES} bytes`)
  if (!successful(result) || result.stdout.byteLength === 0) return null
  return result.stdout
}

export function validateClipboardImage(bytes: Uint8Array): ClipboardImage {
  if (bytes.byteLength > MAX_CLIPBOARD_IMAGE_BYTES)
    throw new ClipboardImageError("too_large", `clipboard image exceeds ${MAX_CLIPBOARD_IMAGE_BYTES} bytes`)
  let dimensions: ReturnType<typeof imageSize>
  try { dimensions = imageSize(bytes) }
  catch { throw new ClipboardImageError("malformed", "clipboard image has an invalid header") }
  const mimeType = MIME_BY_TYPE[dimensions.type as keyof typeof MIME_BY_TYPE]
  if (!mimeType) throw new ClipboardImageError("unsupported", "clipboard image must be PNG, JPEG, or WebP")
  const { width, height } = dimensions
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1 ||
      width > MAX_CLIPBOARD_IMAGE_EDGE || height > MAX_CLIPBOARD_IMAGE_EDGE || width * height > MAX_CLIPBOARD_IMAGE_PIXELS)
    throw new ClipboardImageError("dimensions", `clipboard image dimensions exceed ${MAX_CLIPBOARD_IMAGE_EDGE}px or ${MAX_CLIPBOARD_IMAGE_PIXELS} pixels`)
  return { mimeType, data: Buffer.from(bytes).toString("base64"), width, height, bytes: bytes.byteLength }
}

/** Reads bytes only when called for an explicit paste action. */
export async function readClipboardImage(options: ClipboardImageOptions = {}): Promise<ClipboardImage | null> {
  const bytes = readBytes(options)
  return bytes ? validateClipboardImage(bytes) : null
}
