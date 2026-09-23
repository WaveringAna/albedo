/** Manual, fake-clipboard-only PTY driver for the actual TS ChatScreen. Never reads the OS clipboard. */
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { createElement } from "react"
import { render } from "ink"
import { ChatScreen } from "../../src/ui/chat.js"
import type { ImageAttachment } from "../../src/image.js"

if (process.env.ALBEDO_NO_BROWSER !== "1" || !process.env.ALBEDO_HOME?.includes("albedo-visual-home-"))
  throw new Error("manual visual driver requires the isolated fixture environment")
const { port, token } = JSON.parse(readFileSync(join(process.env.ALBEDO_HOME, "daemon.json"), "utf8")) as { port: number; token: string }
const image: ImageAttachment = {
  mimeType: "image/png", width: 2, height: 3, bytes: 42,
  data: Buffer.from("fake-driver-only").toString("base64"),
}
const clipboardImages = { available: () => true, read: async () => image }
const app = render(createElement(ChatScreen, {
  baseUrl: `http://127.0.0.1:${port}`, token, agentId: "deadbeef12345678", agentName: "albedo",
  workspace: "/tmp/albedo-visual-fixture", model: "gpt-4o",
  clipboardImages, copySelection: async () => { if (process.env.ALBEDO_VISUAL_COPY_FAIL === "1") throw new Error("fixture clipboard rejected") },
  onBack: () => app.unmount(), onQuit: () => app.unmount(),
}), { exitOnCtrlC: false, patchConsole: false })
await app.waitUntilExit()
