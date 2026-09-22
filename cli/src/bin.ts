import { Command } from "commander"
import { createElement } from "react"
import { render } from "ink"
import { resolve } from "node:path"
import { stdin, stdout } from "node:process"
import { App } from "./ui/app.js"
import { ensure, existing, request, type Session } from "./daemon.js"

import { profiles } from "./profiles.js"
import { Login } from "./ui/login.js"
import { sessionListing } from "./sessions.js"

const cli = new Command().name("albedo").description("persistent coding sessions")
async function open(id?: string, workspace=process.cwd(), fresh=false): Promise<void> {
  const connection=await ensure()
  const sessions=await request<Session[]>(connection,"/sessions")
  const matches=id ? sessions.filter(session=>session.id===id || session.id.startsWith(id)) : []
  if(matches.length>1 && !matches.some(session=>session.id===id)) throw new Error("session prefix is ambiguous")
  const selected=matches.find(session=>session.id===id) ?? matches[0]
  if (id && !selected) throw new Error("session not found")
  const configured=!!(await profiles()).active
  if (!configured && (!stdin.isTTY || !stdout.isTTY)) throw new Error("run albedo login in a terminal to save a provider")
  const initial=selected ?? (configured && (fresh || !sessions.length) ? await request<Session>(connection,"/sessions",{ workspace:resolve(workspace) }) : undefined)
  if (!stdin.isTTY || !stdout.isTTY) { console.log(JSON.stringify({ session:initial?.id,sessions }));return }
  const app=render(createElement(App,{ connection,initial,login:!configured,workspace:resolve(workspace),quit:()=>app.unmount() }),{ exitOnCtrlC:false,patchConsole:false })
  await app.waitUntilExit()
}
cli.action(()=>open())
cli.command("new").argument("[workspace]","workspace",process.cwd()).action(workspace=>open(undefined,workspace,true))
cli.command("resume").argument("<session>").action(id=>open(id))
cli.command("sessions").option("--json", "output session metadata as json").action(async options => {
  const sessions = await request<Session[]>(await ensure(), "/sessions")
  console.log(options.json ? JSON.stringify(sessions, null, 2) : sessionListing(sessions))
})
cli.command("send").argument("<session>").argument("<prompt>").action(async(id,prompt)=>console.log(await request(await ensure(),`/sessions/${encodeURIComponent(id)}/events`,{ content:prompt })))
cli.command("stop").argument("<session>").action(async id=>console.log(await request(await ensure(),`/sessions/${encodeURIComponent(id)}/interrupt`,{})))
cli.command("daemon").option("--stop").action(async options=>{
  if (options.stop) { const current=await existing();if(current) await request(current,"/shutdown",{});return }
  const current=await ensure();console.log(`albedo daemon running on 127.0.0.1:${current.port}`)
})
cli.command("login").argument("[name]", "provider name").action(async name=>{
  if (!stdin.isTTY || !stdout.isTTY) throw new Error("login requires a terminal; keys are entered with hidden input")
  const connection = await ensure()
  const app=render(createElement(Login,{ connection,name,onDone:()=>app.unmount(),onCancel:()=>app.unmount() }),{ exitOnCtrlC:false,patchConsole:false })
  await app.waitUntilExit()
})
export async function main(): Promise<void> {
  try { await cli.parseAsync() } catch(error) { console.error(error instanceof Error ? error.message : String(error));process.exitCode=1 }
}
