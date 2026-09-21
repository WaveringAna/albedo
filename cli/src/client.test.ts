import assert from "node:assert/strict"
import test from "node:test"
import { createChatClient, type StreamEvent } from "./client.js"

const page=(cursor:number,events:unknown[]) => `data: ${JSON.stringify({cursor,events})}\n\n`
test("daemon thinking events stay a distinct type from assistant text",async()=>{
  const page=`data: ${JSON.stringify({cursor:1,events:[{type:"thinking",text:"weighing options"},{type:"text",text:"answer"},{type:"message",role:"assistant",text:"answer"}]})}\n\n`
  const events:StreamEvent[]=[]
  const client=createChatClient({baseUrl:"http://localhost",agentId:"session",fetchImpl:async()=>new Response(page,{headers:{"content-type":"text/event-stream"}})})
  await client.stream({onEvent:event=>events.push(event)})
  assert.deepEqual(events,[{type:"thinking",text:"weighing options"},{type:"text",text:"answer"},{type:"message",role:"assistant",text:"answer"}])
})

test("daemon pages preserve live Python previews, native tool args, traces and reconnect cursors",async()=>{
  const urls:string[]=[]
  const code="from pathlib import Path\nPath('demo.py').write_text('hello')"
  const args=JSON.stringify({code,timeout_ms:1000})
  const frames=page(1,[{type:"reset"},{type:"user",text:"work",source:"chat",triggeredAt:""}])
    +page(2,[{type:"arguments_delta",callId:"call",text:args.slice(0,40)}])
    +page(3,[{type:"arguments_delta",callId:"call",text:args.slice(40)}])
    +page(4,[{type:"tool",name:"python",args,result:"ok",trace:{activities:[{kind:"read",target:"demo.py"}],changes:[]}},{type:"message",role:"assistant",text:"done"}])
  const events:StreamEvent[]=[]
  const client=createChatClient({baseUrl:"http://localhost",agentId:"session",fetchImpl:async url=>{
    urls.push(String(url))
    return new Response(urls.length===1?frames:page(4,[]),{headers:{"content-type":"text/event-stream"}})
  }})
  await client.stream({onEvent:event=>events.push(event)})
  await client.stream({onEvent:event=>events.push(event)})
  assert.equal(events[0]?.type,"reset")
  assert.ok(events.some(event=>event.type==="tool_progress" && event.progress?.code?.text.includes("demo.py")))
  const tool=events.find(event=>event.type==="tool")
  assert.equal(tool?.type==="tool" && tool.args.code,code)
  assert.equal(tool?.type==="tool" && tool.trace?.activities[0]?.target,"demo.py")
  assert.deepEqual(events.at(-1),{type:"message",role:"assistant",text:"done"})
  assert.match(urls[1]!,/sessions\/session\/stream\?after_seq=4$/)
})

test("completed call previews release state without losing another call or reconnecting deltas", async () => {
  const a = JSON.stringify({ code: "read('first.py')" })
  const b = JSON.stringify({ code: "read('second.py')" })
  let requests = 0
  const frames = [page(1, [
    { type: "arguments_delta", callId: "a", text: a },
    { type: "arguments_delta", callId: "b", text: b.slice(0, 15) },
    { type: "tool", callId: "a", name: "python", args: a, result: "done" },
  ]), page(2, [
    { type: "arguments_delta", callId: "b", text: b.slice(15) },
    { type: "tool_progress", progress: { callId: "b", name: "python", phase: "running" } },
    { type: "tool", callId: "b", name: "python", args: b, result: "done" },
  ])]
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session",
    fetchImpl: async () => new Response(frames[requests++], { headers: { "content-type": "text/event-stream" } }),
  })
  const events: StreamEvent[] = []
  const options = { onEvent: (event: StreamEvent) => { events.push(event) } }
  await client.stream(options)
  await client.stream(options)
  assert(events.some(event => event.type === "tool_progress" && event.progress?.code?.text === "read('second.py')"))
  const running = events.findIndex(event => event.type === "tool_progress" && event.progress?.phase === "running")
  assert.deepEqual(events[running-1], { type: "tool_progress", progress: null })
  assert.equal(events.at(-1)?.type, "tool")
})


test("usage preserves the original completion time and model through a reset snapshot", async () => {
  const usage = { type: "usage", model: "gpt-5", promptTokens: 1000, completionTokens: 100, totalTokens: 1100, cachedPromptTokens: 800, recordedAt: 1_700_000_000_000 }
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async () => new Response(page(3, [{ type: "reset" }, usage]), { headers: { "content-type": "text/event-stream" } }) })
  const events: StreamEvent[] = []
  await client.stream({ onEvent: event => events.push(event) })
  const observed = events.find(event => event.type === "usage")
  assert.equal(observed?.recordedAt, usage.recordedAt)
  assert.equal(observed?.model, usage.model)
  assert.equal(observed?.cachedPromptTokens, 800)
  assert.equal(observed?.promptTokens, 1000)
})


test("message timestamps survive the wire without inventing missing or invalid dates", async () => {
  const message = { type: "message", role: "assistant", text: "answer" }
  const user = { type: "user", text: "question", source: "chat", triggeredAt: "", clientId: "sender", timestamp: 1_700_000_000_000 }
  const events: StreamEvent[] = []
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async () => new Response(page(1, [user, { ...message, timestamp: user.timestamp + 1000 }, message, { ...message, timestamp: "wrong" }]), { headers: { "content-type": "text/event-stream" } }) })
  await client.stream({ onEvent: event => events.push(event) })
  assert.deepEqual(events, [user, { ...message, timestamp: user.timestamp + 1000 }, message, message])
})
