import { useEffect, useState } from "react"
import { Box, Text } from "ink"
import { ChatScreen } from "./chat.js"
import { Picker } from "./picker.js"
import { Login } from "./login.js"
import { ModelPicker } from "./model-picker.js"
import { request, type Connection, type Session } from "../daemon.js"

export function App({ connection, initial, workspace, quit, login = false }: { connection: Connection; initial?: Session; workspace: string; quit: () => void; login?: boolean }) {
  const [loggingIn,setLoggingIn]=useState<{ name?: string } | undefined>(login ? {} : undefined)
  const [notice,setNotice]=useState("")
  const [selected,setSelected]=useState(initial)
  const [sessions,setSessions]=useState<Session[]>([])
  const [error,setError]=useState("")
  const [choosing,setChoosing]=useState(!initial)
  const [choosingModel,setChoosingModel]=useState(false)
  const listedSessions = selected && !sessions.some(session => session.id === selected.id) ? [selected, ...sessions] : sessions
  const changeModel = async (model: string): Promise<void> => {
    if (!selected) return
    await request(connection, `/sessions/${selected.id}/model`, { model })
    setSelected({ ...selected, model }); setChoosingModel(false); setError("")
  }
  useEffect(() => {
    if (!choosing) return
    const controller = new AbortController()
    void request<Session[]>(connection,"/sessions").then(items => { if (!controller.signal.aborted) setSessions(items) }).catch(error => setError(String(error)))
    return () => controller.abort()
  },[choosing,connection])
  const create = (): void => {
    void request<Session>(connection,"/sessions",{ workspace }).then(session => { setSelected(session); setChoosing(false) }).catch(error => setError(String(error)))
  }
  if (loggingIn) return <Login name={loggingIn.name} onCancel={()=>setLoggingIn(undefined)} onDone={name=>{
    setLoggingIn(undefined); setError("")
    setNotice(`${name} selected for new sessions${selected ? `; this session keeps ${selected.provider}` : ""}`)
    if (!selected && !sessions.length) create()
  }} />
  return <Box flexDirection="column">
    {notice && <Text dimColor>{notice}</Text>}
    {error && <Text color="red">{error}</Text>}
    {choosing && sessions.some(session => typeof session.title !== "string") && <Text color="yellow" wrap="wrap">
      daemon upgrade needed for prompt labels and recent ordering. when ready, run albedo daemon --stop, then albedo. restarting clears python variables.
    </Text>}
    {choosing ? <Picker search title="albedo  sessions" initialSelection={selected?.id ?? listedSessions[0]?.id} items={[
      { id:"new",label:"new coding session",detail:workspace },
      { id:"login",label:"/login",detail:"add or select an api provider" },
      ...listedSessions.map(session => ({ id:session.id,label:typeof session.title === "string" ? session.title.trim() || "new session" : "session · label unavailable",detail:`${session.model} · ${session.workspace}` })),
    ]} onSelect={id => { if (id==="new") create(); else if (id==="login") setLoggingIn({}); else { setSelected(listedSessions.find(session=>session.id===id));setChoosing(false) } }} onCancel={() => selected ? setChoosing(false) : quit()} /> : selected && <><ChatScreen key={selected.id} visible={!choosingModel}
      baseUrl={`http://127.0.0.1:${connection.port}`} token={connection.token} agentId={selected.id} agentName="albedo"
      workspace={selected.workspace} model={selected.model} onBack={()=>setChoosing(true)} onQuit={quit} onCreate={create}
      commands={[{ name:"/login",description:"add or select a named openai-compatible api" },{ name:"/new",description:"new coding session" },{ name:"/sessions",description:"switch session" },{ name:"/model",description:"choose this session's model" }]}
      onCommand={(value,clear)=> {
        if (value === "/login" || value.startsWith("/login ")) { clear(); setLoggingIn({ name: value.slice(6).trim() || undefined }); return true }
        if (value.startsWith("/model ")) { clear();setError("");void changeModel(value.slice(7).trim()).catch(error=>setError(String(error)));return true }
        if (value==="/model") { clear();setError("");setChoosingModel(true);return true } if (["/sessions","/agents","/a"].includes(value)) { clear();setChoosing(true);return true } if (value==="/new") { clear();create();return true } return false }}
      />
      {choosingModel && <ModelPicker provider={selected.provider} current={selected.model} onSelect={changeModel} onCancel={()=>setChoosingModel(false)} />}</>}
  </Box>
}
