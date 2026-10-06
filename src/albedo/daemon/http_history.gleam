//// Canonical history projection from captured native transcript facts.

import albedo/daemon/conversation
import albedo/daemon/http_api
import albedo/daemon/mail
import albedo/daemon/message_content as events
import albedo/daemon/note
import albedo/daemon/transcript
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Part {
  Text(field: String, text: String)
  Value(field: String, value: json.Json)
  Image(field: String, image: types.Image)
  Trace(field: String, trace: json.Json)
  Reference(field: String, entry_id: String, bytes: Int)
}

pub type Entry {
  Entry(
    id: String,
    position: Int,
    kind: String,
    turn_id: Option(String),
    input_id: Option(String),
    timestamp: Option(Int),
    parts: List(Part),
    checkpoint: Option(String),
    tool: Option(types.ToolCall),
    thinking_ms: Option(Int),
    turn_type: String,
    letter: Option(mail.Letter),
  )
}

pub fn project(page: conversation.SourcePage) -> List(Entry) {
  let entries =
    list.flat_map(page.entries, fn(row) {
      let ownership =
        list.find(page.ownership, fn(facts) { facts.position == row.source.seq })
        |> result.unwrap(conversation.TranscriptOwnership(
          row.source.seq,
          None,
          None,
          None,
          None,
          None,
        ))
      project_row(row, ownership, page.tools, page.traces)
    })
  let continuations =
    list.map(page.continuations, fn(marker) {
      Entry(
        "continue-" <> marker.input_id,
        marker.position,
        "continuation",
        marker.turn_id,
        Some(marker.input_id),
        marker.timestamp,
        [Text("text", marker.display.text)],
        None,
        None,
        None,
        "continue",
        None,
      )
    })
  list.append(entries, continuations)
  |> list.sort(fn(a, b) { int.compare(a.position, b.position) })
}

fn project_row(
  source: transcript.SourcedEntry,
  ownership: conversation.TranscriptOwnership,
  tools: List(conversation.ToolAssociation),
  traces: List(#(String, json.Json)),
) -> List(Entry) {
  let item = source.entry
  let id = int.to_string(source.source.seq)
  let entry = fn(suffix, kind, parts, checkpoint, tool) {
    let turn_type = case
      option.map(ownership.display, fn(display) { display.source })
    {
      Some("mail") -> "agent"
      Some("webhook") -> "webhook"
      Some("job") -> "scheduled"
      Some("continue") -> "continue"
      _ -> "user"
    }
    Entry(
      id <> suffix,
      source.source.seq,
      kind,
      ownership.turn_id,
      ownership.input_id,
      item.timestamp,
      parts,
      checkpoint,
      tool,
      item.thought_ms,
      turn_type,
      case kind {
        "user" -> ownership.letter
        _ -> None
      },
    )
  }
  case ownership.image_fit {
    Some(fit) -> [
      entry(
        "-fit",
        "image_fit",
        [
          Text("text", fit.note),
          Value("source_image", json.string(fit.source)),
          Image("image", fit.image),
        ],
        None,
        None,
      ),
    ]
    None ->
      case item.input {
        types.User(text) -> {
          let #(kind, text, origin) = case ownership.display {
            Some(display) ->
              case display.source {
                "chat" | "mail" | "webhook" | "continue" -> #(
                  "user",
                  case ownership.letter {
                    Some(letter) if letter.kind != mail.Webhook -> letter.body
                    _ -> display.text
                  },
                  None,
                )
                _ -> #("note", display.text, Some(display.source))
              }
            None ->
              case note.parse(text) {
                Some(#("compaction", body)) -> #(
                  "compaction",
                  body,
                  Some("compaction"),
                )
                Some(#(origin, body)) -> #("note", body, Some(origin))
                None -> #("user", text, None)
              }
          }
          let metadata = case origin {
            Some(origin) -> [Value("origin", json.string(origin))]
            None -> []
          }
          [
            entry(
              "",
              kind,
              [Text("text", text), ..metadata],
              case kind {
                "user" -> Some(id)
                _ -> None
              },
              None,
            ),
          ]
        }
        types.UserImage(text, images) -> [
          entry(
            "",
            "user",
            [
              Text(
                "text",
                option.map(ownership.display, fn(display) { display.text })
                  |> option.unwrap(text),
              ),
              ..list.index_map(images, fn(image, index) {
                Image("image-" <> int.to_string(index), image)
              })
            ],
            Some(id),
            None,
          ),
        ]
        types.Assistant(text) -> [
          entry("", "assistant", [Text("text", text)], Some(id), None),
        ]
        types.ToolOutput(call_id, text, images) -> {
          let association =
            list.find(tools, fn(tool) {
              tool.result_position == source.source.seq
              && tool.call_id == call_id
            })
            |> option.from_result
          let name =
            option.map(association, fn(tool) { tool.name })
            |> option.unwrap("unknown")
          let call = types.ToolCall(call_id, name, "")
          let trace =
            json.parse(
              text,
              decode.field("cell_id", decode.string, decode.success),
            )
            |> result.replace_error(Nil)
            |> result.try(fn(cell) { list.key_find(traces, cell) })
            |> option.from_result
          let arguments = case association {
            None -> []
            Some(tool) ->
              case tool.arguments {
                Some(arguments) -> [
                  Value("arguments", transcript.argument_json(arguments)),
                ]
                None -> [
                  Reference(
                    "arguments",
                    int.to_string(tool.call_position)
                      <> "-call-"
                      <> int.to_string(tool.call_index),
                    tool.arguments_bytes,
                  ),
                ]
              }
          }
          let parts =
            [Value("result", json.string(text)), ..arguments]
            |> list.append(
              list.index_map(images, fn(image, index) {
                Image("image-" <> int.to_string(index), image)
              }),
            )
          let parts = case trace {
            Some(trace) -> list.append(parts, [Trace("trace", trace)])
            None -> parts
          }
          [entry("", "tool_result", parts, None, Some(call))]
        }
        types.Replay(replay) -> {
          let thinking = events.thinking_text(replay)
          let answer = events.output_text(replay)
          let tool_calls = events.calls(item.input)
          let thought = case thinking {
            "" -> []
            _ -> [
              entry(
                "-thinking",
                "thinking",
                [Text("text", thinking)],
                None,
                None,
              ),
            ]
          }
          let tools =
            list.index_map(tool_calls, fn(call, index) {
              entry(
                "-call-" <> int.to_string(index),
                "tool_call",
                [Value("arguments", transcript.argument_json(call.arguments))],
                Some(id),
                Some(call),
              )
            })
          let assistant = case answer {
            "" -> []
            _ -> [
              entry("", "assistant", [Text("text", answer)], Some(id), None),
            ]
          }
          let shown = list.append(thought, tools) |> list.append(assistant)
          case shown {
            [] -> [entry("-provider", "assistant", [], Some(id), None)]
            _ -> shown
          }
        }
      }
  }
}

pub fn encode(session_id: String, entry: Entry, byte_budget: Int) -> json.Json {
  let content =
    list.map(entry.parts, encode_part(
      session_id,
      entry.id,
      _,
      byte_budget / int.max(1, list.length(entry.parts)),
    ))
  let complete = list.all(content, fn(part) { part.1 })
  json.object([
    #("id", json.string(entry.id)),
    #("position", json.int(entry.position)),
    #("kind", json.string(entry.kind)),
    #("turn_type", json.string(entry.turn_type)),
    #("mail", json.nullable(entry.letter, mail_metadata)),
    #("turn_id", json.nullable(entry.turn_id, json.string)),
    #("input_id", json.nullable(entry.input_id, json.string)),
    #(
      "created_at",
      json.nullable(entry.timestamp, fn(at) {
        json.string(http_api.timestamp(at))
      }),
    ),
    #("content", json.array(content, fn(part) { part.0 })),
    #("checkpoint_id", json.nullable(entry.checkpoint, json.string)),
    #("content_complete", json.bool(complete)),
    #(
      "tool",
      json.nullable(entry.tool, fn(call) {
        json.object([
          #("name", json.string(call.name)),
          #("tool_call_id", json.string(call.id)),
          #("progress_call_id", json.null()),
        ])
      }),
    ),
    #("thinking_duration_ms", json.nullable(entry.thinking_ms, json.int)),
  ])
}

fn reference(
  session: String,
  id: String,
  field: String,
  bytes: Int,
) -> json.Json {
  json.object([
    #("url", json.string("/sessions/" <> session <> "/history/" <> id)),
    #("field", json.string(field)),
    #("bytes", json.int(bytes)),
  ])
}

fn encode_part(
  session: String,
  id: String,
  part: Part,
  budget: Int,
) -> #(json.Json, Bool) {
  case part {
    Reference(field, entry_id, bytes) -> #(
      json.object([
        #("kind", json.string("reference")),
        #("reference", reference(session, entry_id, field, bytes)),
      ]),
      False,
    )
    Text(field, text) -> {
      let bytes = string.byte_size(text)
      // Escaping cannot shorten UTF-8. An oversized body needs no encoded
      // copy merely to decide that the client must fetch its reference.
      let value = case bytes > budget {
        True -> None
        False -> {
          let value = json.string(text)
          case http_api.encoded_size(value) <= budget {
            True -> Some(value)
            False -> None
          }
        }
      }
      case value {
        Some(value) -> #(
          json.object([
            #("kind", json.string("text")),
            #("text", value),
          ]),
          True,
        )
        None -> #(
          json.object([
            #("kind", json.string("reference")),
            #("reference", reference(session, id, field, bytes)),
          ]),
          False,
        )
      }
    }
    Value(field, value) -> {
      let bytes = http_api.encoded_size(value)
      case bytes <= budget {
        True -> #(
          json.object([
            #("kind", json.string("json")),
            #("field", json.string(field)),
            #("value", value),
          ]),
          True,
        )
        False -> #(
          json.object([
            #("kind", json.string("reference")),
            #("reference", reference(session, id, field, bytes)),
          ]),
          False,
        )
      }
    }
    Trace(field, value) -> {
      let bytes = http_api.encoded_size(value)
      case bytes <= budget {
        True -> #(
          json.object([#("kind", json.string("trace")), #("trace", value)]),
          True,
        )
        False -> #(
          json.object([
            #("kind", json.string("reference")),
            #("reference", reference(session, id, field, bytes)),
          ]),
          False,
        )
      }
    }
    Image(field, image) -> {
      let #(mime, width, height, bytes) = types.image_meta(image)
      #(
        json.object([
          #("kind", json.string("image")),
          #(
            "image",
            json.object([
              #("mime_type", json.string(mime)),
              #("width", json.int(width)),
              #("height", json.int(height)),
              #("original_bytes", json.int(bytes)),
              #(
                "reference",
                json.object([
                  #(
                    "url",
                    json.string(
                      "/sessions/"
                      <> session
                      <> "/history/"
                      <> id
                      <> "/"
                      <> field,
                    ),
                  ),
                  #("field", json.string(field)),
                  #("bytes", json.int(bytes)),
                ]),
              ),
            ]),
          ),
        ]),
        False,
      )
    }
  }
}

pub fn checkpoint(entry: Entry) -> Option(json.Json) {
  use _ <- option.then(case entry.kind {
    "user" -> Some(Nil)
    _ -> None
  })
  option.map(entry.checkpoint, fn(checkpoint) {
    let text =
      list.find_map(entry.parts, fn(part) {
        case part {
          Text(_, text) -> Ok(text)
          _ -> Error(Nil)
        }
      })
      |> result.unwrap("")
    let title = http_api.scalar_prefix(text, 4096)
    json.object([
      #("position", json.int(entry.position)),
      #("checkpoint_id", json.string(checkpoint)),
      #("title", json.string(title)),
      #("turn_type", json.string(entry.turn_type)),
      #(
        "preview",
        json.object([
          #("text", json.string(http_api.scalar_prefix(text, 256))),
          #("transcript_count", json.int(1)),
          #("truncated", json.bool(string.length(text) > 256)),
        ]),
      ),
    ])
  })
}

fn mail_metadata(letter: mail.Letter) -> json.Json {
  json.object([
    #("mail_id", json.string(letter.id)),
    #("sender_session_id", json.nullable(letter.sender, json.string)),
    #("sender_label", json.string(letter.sender_name)),
    #("kind", json.string(mail.kind_name(letter.kind))),
  ])
}
