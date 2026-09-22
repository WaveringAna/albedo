import { useEffect, useState } from "react"
import { Box, Text } from "ink"
import { ChatScreen } from "./chat.js"
import { Picker } from "./picker.js"
import { Login } from "./login.js"
import { ModelPicker } from "./model-picker.js"
import { ExtensionPicker } from "./extension-picker.js"
import { TreePicker, type TreeCheckpoint, type TreePage } from "./tree-picker.js"
import { ContextInspector } from "./context-inspector.js"
import { request, type Connection, type Session } from "../daemon.js"
import { parseSkillCatalog, parseSkillInvocation, type SkillCatalog } from "../skills.js"

export function App({ connection, initial, workspace, quit, login = false }: { connection: Connection; initial?: Session; workspace: string; quit: () => void; login?: boolean }) {
  const [loggingIn,setLoggingIn]=useState<{ name?: string } | undefined>(login ? {} : undefined)
  const [notice,setNotice]=useState("")
  const [selected,setSelected]=useState(initial)
  const [sessions,setSessions]=useState<Session[]>([])
  const [error,setError]=useState("")
  const [choosing,setChoosing]=useState(!initial)
  const [choosingModel,setChoosingModel]=useState(false)
  const [choosingExtensions,setChoosingExtensions]=useState(false)
  const [choosingTree,setChoosingTree]=useState(false)
  const [choosingContext,setChoosingContext]=useState(false)
  const [treePage,setTreePage]=useState<TreePage>()
  const [treeError,setTreeError]=useState("")
  const [treeLoading,setTreeLoading]=useState(false)
  const [treeCursors,setTreeCursors]=useState([0])
  const [treePageIndex,setTreePageIndex]=useState(0)
  const [treeNextCursor,setTreeNextCursor]=useState<number>()
  const [extensionRevision,setExtensionRevision]=useState(0)
  const [skillCatalog,setSkillCatalog]=useState<SkillCatalog>({ skills: [], diagnostics: [] })
  const listedSessions = selected && !sessions.some(session => session.id === selected.id) ? [selected, ...sessions] : sessions
  const workspaceChanged = (workspace: string): void => {
    setSelected(current => current && { ...current, workspace })
    if (selected) setSessions(current => current.map(session => session.id === selected.id ? { ...session, workspace } : session))
  }
  const changeModel = async (model: string, provider?: string): Promise<void> => {
    if (!selected) return
    if (provider && provider !== selected.provider) {
      const health = await request<{ capabilities?: string[] }>(connection, "/health")
      if (!health.capabilities?.includes("session_provider"))
        throw new Error("daemon upgrade needed to switch providers; when ready, run albedo daemon --stop, then albedo (this clears python variables)")
    }
    const changed = await request<Partial<Pick<Session, "model" | "provider" | "protocol">>>(connection, `/sessions/${selected.id}/model`, { model, provider })
    setSelected({ ...selected, model: changed.model ?? model, provider: changed.provider ?? selected.provider, protocol: changed.protocol ?? selected.protocol })
    setChoosingModel(false); setError("")
  }
  useEffect(() => {
    if (!choosing) return
    const controller = new AbortController()
    void request<Session[]>(connection,"/sessions").then(items => { if (!controller.signal.aborted) setSessions(items) }).catch(error => setError(String(error)))
    return () => controller.abort()
  },[choosing,connection])
  useEffect(() => {
    if (!selected) { setSkillCatalog({ skills: [], diagnostics: [] }); return }
    let active = true
    void request<unknown>(connection, `/sessions/${encodeURIComponent(selected.id)}/skills`)
      .then(value => { if (active) setSkillCatalog(parseSkillCatalog(value)) })
      .catch(() => { if (active) setSkillCatalog({ skills: [], diagnostics: [] }) })
    return () => { active = false }
  }, [connection, selected?.id, selected?.workspace, extensionRevision])
  useEffect(() => {
    if (!choosingTree || !selected) return
    let active = true
    setTreeLoading(true); setTreeError("")
    const after = treeCursors[treePageIndex] ?? 0
    void request<{ capabilities?: string[] }>(connection, "/health").then(health => {
      if (!health.capabilities?.includes("session_tree")) throw new Error("daemon upgrade needed for /tree; when ready, run albedo daemon --stop, then albedo (this clears python variables)")
      return request<{ items: TreeCheckpoint[]; nextCursor?: number | null; hasMore: boolean }>(
        connection,
        `/sessions/${encodeURIComponent(selected.id)}/tree?after=${after}&limit=50`,
      )
    }).then(page => {
      if (!active) return
      setTreePage({ items: page.items, hasPrevious: treePageIndex > 0, hasNext: page.hasMore })
      setTreeNextCursor(typeof page.nextCursor === "number" ? page.nextCursor : undefined)
    }).catch(cause => { if (active) setTreeError(String(cause)) })
      .finally(() => { if (active) setTreeLoading(false) })
    return () => { active = false }
  },[choosingTree, selected?.id, connection, treeCursors, treePageIndex])
  const openTree = (): void => {
    setTreePage(undefined); setTreeError(""); setTreeCursors([0]); setTreePageIndex(0); setTreeNextCursor(undefined); setChoosingTree(true)
  }
  const nextTreePage = (): void => {
    if (treeNextCursor === undefined) return
    setTreeCursors(current => current.slice(0, treePageIndex + 1).concat(treeNextCursor))
    setTreePageIndex(index => index + 1)
  }
  const forkTree = async (checkpoint: TreeCheckpoint): Promise<void> => {
    if (!selected) return
    const branch = await request<Session>(connection, `/sessions/${encodeURIComponent(selected.id)}/fork`, { checkpoint: checkpoint.id })
    setSelected(branch); setSessions(current => [branch, ...current]); setChoosingTree(false); setTreePage(undefined)
  }
  const create = (): void => {
    void request<Session>(connection,"/sessions",{ workspace }).then(session => { setSelected(session); setChoosing(false) }).catch(error => setError(String(error)))
  }
  if (loggingIn) return <Login name={loggingIn.name} onCancel={()=>setLoggingIn(undefined)} onDone={name=>{
    setLoggingIn(undefined); setError("")
    setNotice(`${name} selected for new sessions${selected ? `; use /model to switch this session from ${selected.provider}` : ""}`)
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
    ]} onSelect={id => { if (id==="new") create(); else if (id==="login") setLoggingIn({}); else { setSelected(listedSessions.find(session=>session.id===id));setChoosing(false) } }} onCancel={() => selected ? setChoosing(false) : quit()} /> : selected && <><ChatScreen key={selected.id} visible={!choosingModel && !choosingExtensions && !choosingTree && !choosingContext} usageResetKey={extensionRevision}
      baseUrl={`http://127.0.0.1:${connection.port}`} token={connection.token} agentId={selected.id} agentName="albedo"
      workspace={selected.workspace} model={selected.model} onWorkspaceChanged={workspaceChanged} onBack={()=>setChoosing(true)} onQuit={quit} onCreate={create}
      commands={[{ name:"/login",description:"add or select a named openai-compatible api" },{ name:"/new",description:"new coding session" },{ name:"/sessions",description:"switch session" },{ name:"/model",description:"choose this session's provider and model" },{ name:"/extensions",description:"manage this session's extension plugins" },{ name:"/tree",description:"branch this session from a history checkpoint" },{ name:"/context",description:"inspect the exact prepared model request" },...skillCatalog.skills.map(skill => ({ name:skill.command,description:skill.description }))]}
      onCommand={(value,clear)=> {
        if (value === "/login" || value.startsWith("/login ")) { clear(); setLoggingIn({ name: value.slice(6).trim() || undefined }); return true }
        if (value.startsWith("/model ")) { clear();setError("");void changeModel(value.slice(7).trim()).catch(error=>setError(String(error)));return true }
        if (value==="/model") { clear();setError("");setChoosingModel(true);return true }
        if (["/extensions","/plugins"].includes(value)) { clear();setError("");setChoosingExtensions(true);return true }
        if (value==="/tree") { clear();setError("");openTree();return true }
        if (value==="/context") { clear();setError("");setChoosingContext(true);return true }
        if (["/sessions","/agents","/a"].includes(value)) { clear();setChoosing(true);return true }
        if (value==="/new") { clear();create();return true }
        const skill = parseSkillInvocation(value, skillCatalog)
        if (skill) {
          clear(); setError("")
          void request(connection, `/sessions/${encodeURIComponent(selected.id)}/skills/activate`, { name:skill.skill.name, arguments:skill.arguments })
            .catch(error=>setError(String(error)))
          return true
        }
        return false }}
      />
      {choosingModel && <ModelPicker provider={selected.provider} current={selected.model} onSelect={changeModel} onCancel={()=>setChoosingModel(false)} />}
      {choosingExtensions && <ExtensionPicker connection={connection} sessionId={selected.id} onChanged={()=>setExtensionRevision(value=>value+1)} onCancel={()=>setChoosingExtensions(false)} />}
      {choosingTree && <TreePicker page={treePage} loading={treeLoading} error={treeError} onPrevious={()=>setTreePageIndex(index=>Math.max(0,index-1))} onNext={nextTreePage} onFork={forkTree} onCancel={()=>setChoosingTree(false)} />}
      {choosingContext && <ContextInspector connection={connection} sessionId={selected.id} onCancel={()=>setChoosingContext(false)} />}</>}
  </Box>
}
