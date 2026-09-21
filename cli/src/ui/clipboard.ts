import { spawn } from "node:child_process"

const nativeCopy = (command: string, args: string[], text: string): Promise<void> => new Promise((resolve, reject) => {
  const child = spawn(command, args, { stdio: ["pipe", "ignore", "ignore"], timeout: 3000, windowsHide: true })
  child.once("error", reject)
  child.once("close", code => code === 0 ? resolve() : reject(new Error("clipboard command failed")))
  child.stdin.on("error", () => {})
  child.stdin.end(text)
})

/** Prefer the local clipboard; SSH/unsupported desktops use the terminal's OSC 52. */
export async function copyText(text: string, write: (data: string) => void): Promise<void> {
  if (!process.env.SSH_CONNECTION && !process.env.SSH_CLIENT && !process.env.MOSH_CONNECTION) {
    const commands: [string, string[]][] = process.platform === "darwin" ? [["/usr/bin/pbcopy", []]]
      : process.platform === "win32" ? [["clip.exe", []]]
      : [...(process.env.WAYLAND_DISPLAY ? [["wl-copy", []] as [string, string[]]] : []),
         ...(process.env.DISPLAY ? [["xclip", ["-selection", "clipboard"]] as [string, string[]], ["xsel", ["--clipboard", "--input"]] as [string, string[]]] : [])]
    for (const [command, args] of commands) {
      try { await nativeCopy(command, args, text); return } catch {}
    }
  }
  const encoded = Buffer.from(text).toString("base64")
  if (encoded.length > 100_000) throw new Error("selection is too large for this terminal's clipboard; select a smaller range")
  write(`\x1b]52;c;${encoded}\x07`)
}
