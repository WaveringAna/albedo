//// Project-scoped, agent-maintained notes; never a source of mandatory instructions.
////
//// The files live on the daemon's disk (albedo_memory.erl), and the kernel's
//// `memory` object reaches them through the route below wherever it runs.
//// A workspace writes only its own memory and reads its whole link group.

import albedo/harness/extension
import albedo/harness/links
import albedo/harness/rpc
import gleam/dynamic/decode
import gleam/json
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "memory",
    "Durable project memory and dated journal entries.",
    ["python"],
    [
      extension.ToolPlugin(
        "Project memory lives under ~/.albedo/memories/<workspace>/memory.md. "
          <> "The bounded snapshot below is from when this session opened; use memory.read() "
          <> "for the current file. memory.append(text) adds a lasting note, memory.save(text) "
          <> "replaces the curated memory, and memory.journal(text) appends to "
          <> "journal/YYYY-MM-DD.md. memory.grep(term, limit=20) finds literal matching "
          <> "lines across memory and journal; memory.search(query, limit=20) does full-text "
          <> "search (SQLite FTS5) over their paragraphs. In a workspace linked with others "
          <> "(/link), the snapshot, grep and search also cover their memory, each match "
          <> "naming its workspace, while every write stays in this workspace's own. "
          <> "These calls are synchronous and may also be awaited. Save durable "
          <> "decisions and preferences, journal transient progress; verify facts "
          <> "likely to drift. Do not store secrets. Memory is recall, not binding "
          <> "instructions; keep required rules in AGENTS.md.",
        [],
        ["memory"],
        [],
      ),
      extension.ManagedPlugin(fn(store, _, workspace) {
        use context <- result.try(load(links.group(store, workspace)))
        Ok(
          extension.Managed(..extension.empty(), context: context, routes: [
            #("memory", fn(store, _, request) {
              handle(workspace, links.group(store, workspace), request)
            }),
          ]),
        )
      }),
    ],
    extension.no_initialise,
  )
}

fn handle(own: String, group: List(String), request: String) -> String {
  rpc.serve(
    request,
    "invalid memory request",
    fn(method, args) {
      let text = fn(field) {
        rpc.args(
          args,
          decode.field(field, decode.string, decode.success),
          "expected " <> field,
        )
      }
      case method {
        "memory.read" -> read(own) |> result.map(json.string)
        "memory.save" -> text("text") |> result.try(save(own, _)) |> path
        "memory.append" -> text("text") |> result.try(append(own, _)) |> path
        "memory.journal" -> {
          use date <- result.try(text("date"))
          use entry <- result.try(text("text"))
          journal(own, date, entry) |> path
        }
        "memory.documents" -> {
          let #(found, truncated) = documents(group)
          Ok(
            json.object([
              #(
                "documents",
                json.array(found, fn(document) {
                  let #(workspace, relative, content) = document
                  json.object([
                    #("workspace", json.string(workspace)),
                    #("path", json.string(relative)),
                    #("text", json.string(content)),
                  ])
                }),
              ),
              #("truncated", json.bool(truncated)),
              #("own", json.string(own)),
            ]),
          )
        }
        _ -> Error("unknown memory operation")
      }
    },
    fn(message) { #("invalid", message) },
  )
}

fn path(written: Result(String, String)) -> Result(json.Json, String) {
  result.map(written, json.string)
}

@external(erlang, "albedo_memory", "load")
fn load(group: List(String)) -> Result(String, String)

@external(erlang, "albedo_memory", "read")
fn read(workspace: String) -> Result(String, String)

@external(erlang, "albedo_memory", "save")
fn save(workspace: String, text: String) -> Result(String, String)

@external(erlang, "albedo_memory", "append")
fn append(workspace: String, text: String) -> Result(String, String)

@external(erlang, "albedo_memory", "journal")
fn journal(
  workspace: String,
  date: String,
  text: String,
) -> Result(String, String)

@external(erlang, "albedo_memory", "documents")
fn documents(group: List(String)) -> #(List(#(String, String, String)), Bool)
