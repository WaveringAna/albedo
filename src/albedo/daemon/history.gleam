//// Durable prefix forks. These operations never start a session actor.

import albedo/daemon/conversation
import albedo/daemon/message_content as events
import albedo/daemon/operations
import albedo/daemon/session_configuration
import albedo/daemon/store
import albedo/daemon/usage
import albedo/harness/extensions/lcm/graph as lcm_graph
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import sqlight

const incomplete_tool_result = "not executed after branch checkpoint"

type Row {
  Row(seq: Int, input: types.Input, timestamp: Option(Int))
}

/// Create a durable, idle session containing exactly the selected prefix plus
/// protocol-completing results for tool calls interrupted by the checkpoint.
/// Runtime, Python, request-strategy, and usage state are intentionally absent.
pub type ForkCreation {
  ForkCreation(
    source_id: String,
    branch_id: String,
    checkpoint: Int,
    creation: conversation.Creation,
  )
}

pub fn fork_identified(
  ledger: store.Store,
  request: ForkCreation,
) -> Result(operations.Receipt, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(conversation.creation_available_in(
        db,
        request.branch_id,
      ))
      operations.admit_in(
        db,
        request.creation.request,
        201,
        request.creation.submitted,
        None,
        fn(db) {
          use info <- result.try(fork_in(
            db,
            request.source_id,
            request.branch_id,
            request.checkpoint,
          ))
          conversation.record_creation_in(
            db,
            request.branch_id,
            conversation.Creation(
              ..request.creation,
              resolved: json.object([
                  #("workspace", json.string(info.cwd)),
                  #("provider_profile", json.string(info.provider)),
                  #("model", json.string(info.model)),
                  #("effort", json.nullable(info.effort, json.string)),
                ])
                |> json.to_string,
            ),
          )
        },
      )
    })
  })
}

pub fn fork(
  ledger: store.Store,
  source_id: String,
  branch_id: String,
  checkpoint: Int,
) -> Result(conversation.Info, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() { fork_in(db, source_id, branch_id, checkpoint) })
  })
}

fn fork_in(
  db: sqlight.Connection,
  source_id: String,
  branch_id: String,
  checkpoint: Int,
) -> Result(conversation.Info, String) {
  use _ <- result.try(
    case
      source_id != branch_id
      && checkpoint > 0
      && string.byte_size(branch_id) > 0
      && string.byte_size(branch_id) <= 200
    {
      True -> Ok(Nil)
      False -> Error("invalid branch checkpoint or session id")
    },
  )
  use source <- result.try(conversation.read_info(db, source_id))
  use desired <- result.try(session_configuration.read_in(db, source_id))
  let source = conversation.Info(..source, cwd: desired.workspace)
  use rows <- result.try(read_prefix(db, source_id, checkpoint))
  use _ <- result.try(case list.last(rows) {
    Ok(row) if row.seq == checkpoint -> Ok(Nil)
    _ -> Error("checkpoint not found")
  })
  use pending <- result.try(unmatched_calls(rows))
  let title = prefix_title(rows)
  use _ <- result.try(insert_session(db, source, branch_id, title))
  use _ <- result.try(copy_prefix(db, source_id, branch_id, checkpoint, rows))
  use _ <- result.try(lcm_graph.inherit_fork_prefix(
    db,
    source_id,
    branch_id,
    checkpoint,
    list.map(rows, fn(row) { row.seq }),
  ))
  use _ <- result.try(copy_selection(db, source_id, branch_id))
  use _ <- result.try(append_incomplete_results(
    db,
    branch_id,
    source.provider,
    pending,
  ))
  Ok(conversation.Info(
    branch_id,
    title,
    source.cwd,
    source.provider,
    source.model,
    source.protocol,
    conversation.Idle,
    None,
    source.effort,
  ))
}

fn row_decoder() -> decode.Decoder(#(Int, BitArray, Option(Int))) {
  use seq <- decode.field(0, decode.int)
  use payload <- decode.field(1, decode.bit_array)
  use timestamp <- decode.field(2, decode.optional(decode.int))
  decode.success(#(seq, payload, timestamp))
}

fn decode_row(row: #(Int, BitArray, Option(Int))) -> Result(Row, String) {
  let #(seq, payload, timestamp) = row
  use input <- result.try(
    unpack(payload, unread)
    |> result.replace_error("invalid saved transcript item"),
  )
  Ok(Row(seq, input, timestamp))
}

fn read_prefix(
  db: sqlight.Connection,
  id: String,
  checkpoint: Int,
) -> Result(List(Row), String) {
  use rows <- result.try(store.rows(
    db,
    "SELECT seq,payload,timestamp,provider FROM transcript WHERE session=? AND seq<=? ORDER BY seq",
    [sqlight.text(id), sqlight.int(checkpoint)],
    row_decoder(),
  ))
  list.try_map(rows, decode_row)
}

fn prefix_title(rows: List(Row)) -> String {
  rows
  |> list.map(fn(row) { row.input })
  |> conversation.latest_user
  |> conversation.title_or_default
}

fn unmatched_calls(rows: List(Row)) -> Result(List(String), String) {
  list.try_fold(rows, [], fn(pending, row) {
    case row.input {
      types.Replay(_) ->
        list.try_fold(events.calls(row.input), pending, fn(pending, call) {
          case list.contains(pending, call.id) {
            True -> Error("duplicate tool call id before checkpoint")
            False -> Ok(list.append(pending, [call.id]))
          }
        })
      types.ToolOutput(id, _, _) ->
        case list.contains(pending, id) {
          True -> Ok(list.filter(pending, fn(value) { value != id }))
          False -> Error("checkpoint contains a tool result without its call")
        }
      _ -> Ok(pending)
    }
  })
}

fn insert_session(
  db: sqlight.Connection,
  source: conversation.Info,
  id: String,
  title: String,
) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO sessions(id,title,cwd,provider,model,protocol,effort,stage,activity_seq,last_assistant_at,created_at,activity_at) SELECT ?,?,?,?,?,?,?,'idle',COALESCE(MAX(activity_seq),0)+1,NULL,?,? FROM sessions",
    [
      sqlight.text(id),
      sqlight.text(title),
      sqlight.text(source.cwd),
      sqlight.text(source.provider),
      sqlight.text(source.model),
      sqlight.text(conversation.protocol(source.protocol)),
      sqlight.nullable(sqlight.text, source.effort),
      sqlight.int(usage.now()),
      sqlight.int(usage.now()),
    ],
  )
}

fn copy_prefix(
  db: sqlight.Connection,
  source_id: String,
  branch_id: String,
  checkpoint: Int,
  rows: List(Row),
) -> Result(Nil, String) {
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO transcript(session,payload,timestamp,provider,thought_ms,row_class,turn_id) SELECT ?,payload,timestamp,provider,thought_ms,row_class,turn_id FROM transcript WHERE session=? AND seq<=? ORDER BY seq",
      [
        sqlight.text(branch_id),
        sqlight.text(source_id),
        sqlight.int(checkpoint),
      ],
    ),
  )
  use positions <- result.try(store.rows(
    db,
    "SELECT seq FROM transcript WHERE session=? ORDER BY seq",
    [sqlight.text(branch_id)],
    decode.field(0, decode.int, decode.success),
  ))
  list.try_each(list.zip(rows, positions), fn(pair) {
    use _ <- result.try(conversation.index_entry_in(
      db,
      branch_id,
      pair.1,
      pair.0.input,
    ))
    use _ <- result.try(copy_input_metadata(
      db,
      source_id,
      branch_id,
      #(pair.0.seq, pair.1),
      checkpoint,
    ))
    case pair.0.input {
      types.ToolOutput(_, output, _) -> {
        case
          json.parse(
            output,
            decode.field("cell_id", decode.string, decode.success),
          )
        {
          Error(_) -> Ok(Nil)
          Ok(cell_id) -> {
            use traces <- result.try(
              conversation.traces_in(db, source_id, [cell_id]),
            )
            list.try_each(traces, fn(trace) {
              store.run(
                db,
                "INSERT OR IGNORE INTO transcript_traces(session,cell_id,payload) VALUES(?,?,?)",
                [
                  sqlight.text(branch_id),
                  sqlight.text(trace.0),
                  sqlight.text(json.to_string(trace.1)),
                ],
              )
            })
          }
        }
      }
      _ -> Ok(Nil)
    }
  })
}

fn copy_input_metadata(
  db: sqlight.Connection,
  source_id: String,
  branch_id: String,
  positions: #(Int, Int),
  checkpoint: Int,
) -> Result(Nil, String) {
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO submission_events(session,seq,operation_id,payload) SELECT ?,?,operation_id,payload FROM submission_events WHERE session=? AND seq=? ORDER BY rowid",
      [
        sqlight.text(branch_id),
        sqlight.int(positions.1),
        sqlight.text(source_id),
        sqlight.int(positions.0),
      ],
    ),
  )
  // A marker follows its anchor row. Markers at the checkpoint itself are
  // later inputs and do not belong to that inclusive transcript prefix.
  store.run(
    db,
    "INSERT INTO continuation_markers(operation_id,session,seq,payload,timestamp,turn_id) SELECT operation_id,?,?,payload,timestamp,turn_id FROM continuation_markers WHERE session=? AND seq=? AND seq<? ORDER BY rowid",
    [
      sqlight.text(branch_id),
      sqlight.int(positions.1),
      sqlight.text(source_id),
      sqlight.int(positions.0),
      sqlight.int(checkpoint),
    ],
  )
}

fn copy_selection(
  db: sqlight.Connection,
  source_id: String,
  branch_id: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO session_selection(session,kind,candidate,preference_key,enabled) SELECT ?,kind,candidate,preference_key,enabled FROM session_selection WHERE session=?",
      [sqlight.text(branch_id), sqlight.text(source_id)],
    ),
  )
  store.run(
    db,
    "INSERT INTO session_extensions(session,name,enabled) SELECT ?,name,enabled FROM session_extensions WHERE session=?",
    [sqlight.text(branch_id), sqlight.text(source_id)],
  )
}

fn append_incomplete_results(
  db: sqlight.Connection,
  branch_id: String,
  provider: String,
  pending: List(String),
) -> Result(Nil, String) {
  list.try_each(pending, fn(call_id) {
    store.run(
      db,
      "INSERT INTO transcript(session,payload,timestamp,provider,row_class) VALUES(?,?,NULL,?,'other')",
      [
        sqlight.text(branch_id),
        sqlight.blob(
          pack(types.ToolOutput(call_id, incomplete_tool_result, [])),
        ),
        sqlight.text(provider),
      ],
    )
  })
}

@external(erlang, "albedo_conversation", "pack")
fn pack(input: types.Input) -> BitArray

@external(erlang, "albedo_conversation", "unpack")
fn unpack(
  bytes: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Result(types.Input, Nil)

/// History rows are previews and fork bookkeeping (a fork copies payload bytes,
/// references included); none is sent to a model, so none reads an image.
fn unread(_hash: String) -> Result(String, Nil) {
  Error(Nil)
}
