//// One durable row per provider request: every attempt albedo sends.
////
//// The transcript keeps what a turn said; it cannot say what the request
//// looked like when the provider saw it. Each row records what later cache
//// and quota analysis cannot recover: which account served, how long the
//// call took, what it cost in tokens (cached reads, cache writes split by
//// TTL, reasoning), how it ended (an HTTP status turns a 429 into a quota
//// reading), and a prefix identity — a hash of the request head plus the
//// projection that stands in for replaced history — so two rows can be told
//// apart as a warm append or a cache-busting rewrite without storing any
//// request body. Requests are never stored, only hashed.

import albedo/clock

import albedo/daemon/store
import albedo/daemon/stream_trace
import albedo/harness/compaction
import albedo/openai_api/types
import albedo/text_scalars
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub const schema =
  "CREATE TABLE IF NOT EXISTS provider_requests(id INTEGER PRIMARY KEY AUTOINCREMENT,session TEXT NOT NULL REFERENCES sessions(id),seq INTEGER,kind TEXT NOT NULL,profile TEXT NOT NULL,provider TEXT NOT NULL,account TEXT,model TEXT NOT NULL,started_ms INTEGER NOT NULL,finished_ms INTEGER NOT NULL,outcome TEXT NOT NULL,status INTEGER,error TEXT,input_tokens INTEGER,cached_input_tokens INTEGER,cache_creation_tokens INTEGER,cache_write_5m_tokens INTEGER,cache_write_1h_tokens INTEGER,output_tokens INTEGER,reasoning_tokens INTEGER,head_hash TEXT NOT NULL,inputs INTEGER NOT NULL,replaced INTEGER,projection_hash TEXT,strategy TEXT,cache_marks TEXT NOT NULL DEFAULT '[]'); CREATE INDEX IF NOT EXISTS provider_requests_session ON provider_requests(session,id); CREATE INDEX IF NOT EXISTS provider_requests_head ON provider_requests(head_hash,model,id);"

/// What the call was for. A turn is the model loop; a summarizer is the
/// compaction summary call `loop.summarize` makes; a background call is one
/// an extension sent on the idle session, such as a cache-warming ping.
pub type Kind {
  Turn
  Summarizer
  Background
}

fn kind_name(kind: Kind) -> String {
  case kind {
    Turn -> "turn"
    Summarizer -> "summarizer"
    Background -> "background"
  }
}

/// How a call ended: completed, or failed with the HTTP status when there was
/// one and a bounded detail that keeps an error body readable, not whole.
pub type Outcome {
  Completed
  Failed(status: Option(Int), detail: String)
}

pub fn outcome(result: Result(a, types.Error)) -> Outcome {
  case result {
    Ok(_) -> Completed
    Error(types.HttpError(status, body)) -> Failed(Some(status), bounded(body))
    Error(types.ProviderError(message)) -> Failed(None, bounded(message))
    Error(types.Timeout(phase, waited_ms)) ->
      Failed(
        None,
        "Timeout "
          <> types.phase_name(phase)
          <> " after "
          <> int.to_string(waited_ms)
          <> " ms",
      )
    Error(error) -> Failed(None, string.inspect(error))
  }
}

/// Error bodies are truncated so one huge response cannot bloat the table.
const detail_limit = 2000

fn bounded(text: String) -> String {
  case text_scalars.length(text) > detail_limit {
    True -> text_scalars.take(text, detail_limit) <> "…[truncated]"
    False -> text
  }
}

/// What makes cache analysis possible without storing requests: the request
/// head (instructions and tools) as a hash, how many projected inputs the
/// request carries, and a projection identity that changes exactly when
/// compaction changes what precedes the verbatim tail — the count of original
/// inputs the projection replaced and a hash of the replacement part. Within
/// one projection the request is append-only, so these tell a warm prefix
/// from a rewrite.
pub type Prefix {
  Prefix(
    head_hash: String,
    inputs: Int,
    replaced: Option(Int),
    projection_hash: Option(String),
    strategy: Option(String),
  )
}

/// The prefix identity of a projected request: `projected` is the history the
/// request carries, `original` the durable history it stands in for, and
/// `strategy` the compaction strategy that prepared it, when one did.
pub fn prefix(
  instructions: String,
  tools: List(types.Tool),
  projected: List(types.Input),
  original: List(types.Input),
  strategy: Option(String),
) -> Prefix {
  let suffix = compaction.common_suffix(original, projected)
  let replaced = list.length(original) - suffix
  Prefix(
    head_hash: head_hash(instructions, tools),
    inputs: list.length(projected),
    replaced: Some(replaced),
    projection_hash: case replaced {
      0 -> None
      _ ->
        Some(inputs_hash(list.take(projected, list.length(projected) - suffix)))
    },
    strategy: strategy,
  )
}

/// The prefix identity of a request outside the session projection, whose
/// history is exactly what it says: nothing replaced anything.
pub fn direct_prefix(
  instructions: String,
  tools: List(types.Tool),
  inputs: List(types.Input),
) -> Prefix {
  Prefix(
    head_hash: head_hash(instructions, tools),
    inputs: list.length(inputs),
    replaced: None,
    projection_hash: None,
    strategy: None,
  )
}

/// The hash of a request head: its instructions and the tools it offers.
fn head_hash(instructions: String, tools: List(types.Tool)) -> String {
  json.object([
    #("instructions", json.string(instructions)),
    #("tools", tools_json(tools)),
  ])
  |> json.to_string
  |> hash
}

/// The hash of the tools a request offers, as its head hash encodes them.
pub fn tools_hash(tools: List(types.Tool)) -> String {
  tools_json(tools) |> json.to_string |> hash
}

fn tools_json(tools: List(types.Tool)) -> Json {
  json.array(tools, fn(tool) {
    json.object([
      #("name", json.string(tool.name)),
      #("description", json.string(tool.description)),
      #("parameters", tool.parameters),
      #("strict", json.bool(tool.strict)),
    ])
  })
}

/// The hash of a run of inputs, as request rows identify them.
fn inputs_hash(inputs: List(types.Input)) -> String {
  inputs
  |> list.map(input_identity)
  |> string.join("\n")
  |> hash
}

/// A cumulative hash over the whole request, kept at a few positions so two
/// rows can be compared without a stored body: head, then each input folded
/// in order. The row keeps the running hash after every `chain_stride`th
/// input and after each of the last `chain_tail`, as `position:hash` pairs,
/// shortened to 12 hex digits. A request that extends an earlier one agrees
/// with it at every position they share, so the first position where two
/// rows disagree bounds where their prefixes drifted, and an append-only
/// request equals its predecessor's last position at the same position.
pub fn input_chain(
  instructions: String,
  tools: List(types.Tool),
  inputs: List(types.Input),
) -> String {
  let total = list.length(inputs)
  let start = bit_array.from_string(head_hash(instructions, tools))
  let #(_, marks) =
    list.index_fold(inputs, #(start, []), fn(state, input, index) {
      let #(running, marks) = state
      let running =
        bit_array.append(running, bit_array.from_string(input_identity(input)))
        |> crypto.hash(crypto.Sha256, _)
      let position = index + 1
      case position % chain_stride == 0 || position > total - chain_tail {
        True -> #(running, [#(position, running), ..marks])
        False -> #(running, marks)
      }
    })
  marks
  |> list.reverse
  |> list.map(fn(mark) {
    let #(position, running) = mark
    int.to_string(position) <> ":" <> short_hex(running)
  })
  |> string.join(",")
}

const chain_stride = 16

const chain_tail = 4

fn short_hex(digest: BitArray) -> String {
  digest
  |> bit_array.base16_encode
  |> string.lowercase
  |> text_scalars.take(12)
}

fn input_identity(input: types.Input) -> String {
  case input {
    types.User(text) -> "user\n" <> text
    types.Assistant(text) -> "assistant\n" <> text
    types.UserImage(text, images) ->
      "user_image\n"
      <> string.join(list.map(images, image_identity), "\n")
      <> "\n"
      <> text
    types.ToolOutput(id, output, images) ->
      "tool_output\n"
      <> id
      <> "\n"
      <> output
      <> string.concat(
        list.map(images, fn(image) { "\n" <> image_identity(image) }),
      )
    types.Replay(item) -> "replay\n" <> json.to_string(types.replay_json(item))
  }
}

/// An image by the content identity its payload already carries.
fn image_identity(image: types.Image) -> String {
  case types.image_data(image) {
    types.InlineData(data) -> hash(data)
    types.StoredData(hash, _, _) -> hash
  }
}

fn hash(text: String) -> String {
  text
  |> bit_array.from_string
  |> crypto.hash(crypto.Sha256, _)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// One provider call, as it is about to be recorded.
pub type Call {
  Call(
    session: String,
    kind: Kind,
    /// The saved profile the request went through.
    profile: String,
    /// How the request reached the provider: protocol and endpoint.
    provider: String,
    /// Non-secret label of the account that served; None without a pool.
    account: Option(String),
    model: String,
    /// The reasoning effort the request asked for, when it set one.
    effort: Option(String),
    started_ms: Int,
    finished_ms: Int,
    outcome: Outcome,
    usage: Option(types.Usage),
    prefix: Prefix,
    /// Where the request asked the provider to cache, and for how long.
    cache_marks: List(types.CacheMark),
    run_id: String,
    /// The request's `input_chain`.
    input_chain: String,
    /// What the attempt streamed before it ended.
    streamed: stream_trace.Streamed,
    /// What the response reported about itself before it ended.
    reported: stream_trace.Reported,
  )
}

/// Writes one row and answers its id, so the caller can attach the transcript
/// seq the call produced once it is committed.
pub fn record(database: store.Store, call: Call) -> Result(Int, String) {
  store.query(database, fn(db) {
    use _ <- result.try(store.run(db, insert, values(call)))
    store.one(
      db,
      "SELECT last_insert_rowid()",
      [],
      decode.field(0, decode.int, decode.success),
      "provider request row id",
    )
  })
}

// `seq` starts null and is attached after the call's transcript row commits.
const insert =
  "INSERT INTO provider_requests(session,seq,kind,profile,provider,account,model,started_ms,finished_ms,outcome,status,error,input_tokens,cached_input_tokens,cache_creation_tokens,cache_write_5m_tokens,cache_write_1h_tokens,output_tokens,reasoning_tokens,head_hash,inputs,replaced,projection_hash,strategy,cache_marks,run_id,input_chain,first_event_ms,streamed_events,streamed_thinking_bytes,streamed_output_bytes,first_byte_ms,total_tokens,response_id,model_version,trace_id,effort) VALUES(?,NULL,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"

fn values(call: Call) -> List(sqlight.Value) {
  let Call(
    session,
    kind,
    profile,
    provider,
    account,
    model,
    effort,
    started_ms,
    finished_ms,
    outcome,
    usage,
    prefix,
    cache_marks,
    run_id,
    input_chain,
    streamed,
    reported,
  ) = call
  let Prefix(head_hash, inputs, replaced, projection_hash, strategy) = prefix
  let #(status, error) = case outcome {
    Completed -> #(None, None)
    Failed(status, detail) -> #(status, Some(bounded(detail)))
  }
  let #(input, output, cached, creation, write_5m, write_1h, reasoning) = case
    usage
  {
    Some(types.Usage(
      input,
      output,
      cached,
      creation,
      write_5m,
      write_1h,
      reasoning,
    )) -> #(
      Some(input),
      Some(output),
      cached,
      creation,
      write_5m,
      write_1h,
      reasoning,
    )
    None -> #(None, None, None, None, None, None, None)
  }
  [
    sqlight.text(session),
    sqlight.text(kind_name(kind)),
    sqlight.text(profile),
    sqlight.text(provider),
    sqlight.nullable(sqlight.text, account),
    sqlight.text(model),
    sqlight.int(started_ms),
    sqlight.int(finished_ms),
    sqlight.text(case outcome {
      Completed -> "ok"
      Failed(..) -> "error"
    }),
    sqlight.nullable(sqlight.int, status),
    sqlight.nullable(sqlight.text, error),
    sqlight.nullable(sqlight.int, input),
    sqlight.nullable(sqlight.int, cached),
    sqlight.nullable(sqlight.int, creation),
    sqlight.nullable(sqlight.int, write_5m),
    sqlight.nullable(sqlight.int, write_1h),
    sqlight.nullable(sqlight.int, output),
    sqlight.nullable(sqlight.int, reasoning),
    sqlight.text(head_hash),
    sqlight.int(inputs),
    sqlight.nullable(sqlight.int, replaced),
    sqlight.nullable(sqlight.text, projection_hash),
    sqlight.nullable(sqlight.text, strategy),
    sqlight.text(json.array(cache_marks, cache_mark_json) |> json.to_string),
    sqlight.text(run_id),
    sqlight.text(input_chain),
    sqlight.nullable(sqlight.int, streamed.first_event_ms),
    sqlight.int(streamed.events),
    sqlight.int(streamed.thinking_bytes),
    sqlight.int(streamed.output_bytes),
    sqlight.nullable(sqlight.int, reported.first_byte_ms),
    sqlight.nullable(sqlight.int, reported.total_tokens),
    sqlight.nullable(sqlight.text, reported.response_id),
    sqlight.nullable(sqlight.text, reported.model_version),
    sqlight.nullable(sqlight.text, reported.trace_id),
    sqlight.nullable(sqlight.text, effort),
  ]
}

/// Attaches the transcript row a recorded call produced.
pub fn attach(
  database: store.Store,
  session: String,
  row: Int,
  seq: Int,
) -> Result(Nil, String) {
  store.write(
    database,
    "UPDATE provider_requests SET seq=? WHERE id=? AND session=?",
    [sqlight.int(seq), sqlight.int(row), sqlight.text(session)],
  )
}

/// One stored row, as the read path answers it.
pub type Row {
  Row(
    id: Int,
    session: String,
    seq: Option(Int),
    kind: String,
    profile: String,
    provider: String,
    account: Option(String),
    model: String,
    /// None when the request set no effort, or for a row written before
    /// effort was recorded.
    effort: Option(String),
    started_ms: Int,
    finished_ms: Int,
    outcome: String,
    status: Option(Int),
    error: Option(String),
    input_tokens: Option(Int),
    cached_input_tokens: Option(Int),
    cache_creation_tokens: Option(Int),
    cache_write_5m_tokens: Option(Int),
    cache_write_1h_tokens: Option(Int),
    output_tokens: Option(Int),
    reasoning_tokens: Option(Int),
    head_hash: String,
    inputs: Int,
    replaced: Option(Int),
    projection_hash: Option(String),
    strategy: Option(String),
    cache_marks: List(types.CacheMark),
    run_id: Option(String),
    /// None for a row written before the chain was recorded.
    input_chain: Option(String),
    /// None for a row written before streams were traced.
    streamed: Option(stream_trace.Streamed),
    /// Delay to the response headers; None when none came, or for a row
    /// written before it was recorded.
    first_byte_ms: Option(Int),
    /// The provider's own total, when it reports one: on Gemini routes it
    /// also counts thinking the thought count leaves out.
    total_tokens: Option(Int),
    response_id: Option(String),
    model_version: Option(String),
    trace_id: Option(String),
  )
}

/// Rows after `after`, oldest first, at most `limit`; the id to continue from.
pub fn page(
  database: store.Store,
  session: String,
  after: Int,
  limit: Int,
) -> Result(#(List(Row), Int), String) {
  store.snapshot(database, fn(db) {
    use rows <- result.try(store.rows(
      db,
      "SELECT "
        <> columns
        <> " FROM provider_requests WHERE session=? AND id>? ORDER BY id LIMIT ?",
      [sqlight.text(session), sqlight.int(after), sqlight.int(limit)],
      row_decoder(),
    ))
    let next =
      rows
      |> list.last
      |> result.map(fn(row) { row.id })
      |> result.unwrap(after)
    Ok(#(rows, next))
  })
}

/// The session's latest completed turn call whose response the transcript
/// holds, with the background calls since then that repeated its prefix
/// (cache-warming pings), oldest first.
pub fn last_turn(
  database: store.Store,
  session: String,
) -> Result(Option(#(Row, List(Row))), String) {
  store.snapshot(database, fn(db) {
    use turns <- result.try(store.rows(
      db,
      "SELECT "
        <> columns
        <> " FROM provider_requests WHERE session=? AND kind='turn' AND outcome='ok' AND seq IS NOT NULL ORDER BY id DESC LIMIT 1",
      [sqlight.text(session)],
      row_decoder(),
    ))
    case turns {
      [] -> Ok(None)
      [turn, ..] -> {
        use pings <- result.map(store.rows(
          db,
          "SELECT "
            <> columns
            <> " FROM provider_requests WHERE session=? AND kind='background' AND outcome='ok' AND id>? AND head_hash=? AND inputs=? ORDER BY id",
          [
            sqlight.text(session),
            sqlight.int(turn.id),
            sqlight.text(turn.head_hash),
            sqlight.int(turn.inputs),
          ],
          row_decoder(),
        ))
        Some(#(turn, pings))
      }
    }
  })
}

/// The prefix identity a row was recorded with.
pub fn row_prefix(row: Row) -> Prefix {
  Prefix(
    row.head_hash,
    row.inputs,
    row.replaced,
    row.projection_hash,
    row.strategy,
  )
}

/// The usage a row recorded, when the call reported one.
pub fn row_usage(row: Row) -> Option(types.Usage) {
  case row.input_tokens, row.output_tokens {
    Some(input), Some(output) ->
      Some(types.Usage(
        input,
        output,
        row.cached_input_tokens,
        row.cache_creation_tokens,
        row.cache_write_5m_tokens,
        row.cache_write_1h_tokens,
        row.reasoning_tokens,
      ))
    _, _ -> None
  }
}

/// What a request head (its instructions and tools, under the hour-long
/// cache marks) takes up, from the latest call through `profile` to `model`
/// that wrote that head's hour-long entries: its read covered a prefix, and
/// those writes the rest. Any session's call counts, since the head is the
/// same whichever conversation follows it; `None` when none measured it.
pub fn head_tokens(
  database: store.Store,
  profile: String,
  model: String,
  head_hash: String,
) -> Option(Int) {
  store.snapshot(database, fn(db) {
    store.rows(
      db,
      "SELECT COALESCE(cached_input_tokens,0)+cache_write_1h_tokens FROM provider_requests WHERE head_hash=? AND model=? AND profile=? AND cache_write_1h_tokens>0 ORDER BY id DESC LIMIT 1",
      [sqlight.text(head_hash), sqlight.text(model), sqlight.text(profile)],
      decode.field(0, decode.int, decode.success),
    )
  })
  |> result.try(fn(rows) { list.first(rows) |> result.replace_error("") })
  |> option.from_result
}

// TODO: a per-model floor from each cache's block size. Argon rounds what it
// caches down by about 2k tokens, flash by up to about 6k, and Claude's reads
// are exact, so one floor has to clear the coarsest of them.
/// The smallest loss worth telling anyone about.
const miss_floor = 8192

/// A loss also has to be a twentieth of the prompt, so a big context rounding
/// a little off is not one.
const miss_share = 20

/// What a call read uncached that the call before it left cached.
pub type Loss {
  /// The provider let go of the prefix the call repeated.
  Missed(tokens: Int)
  /// The call did not repeat it: its history changed before its new inputs,
  /// so albedo sent something the provider had not cached.
  Drifted(tokens: Int)
}

/// How many tokens the call at `row_id` read uncached that the call before it
/// left cached, when nothing explains it: the same model, effort, head and
/// projection, a longer history, and a gap shorter than `whole_for_ms`, how
/// long the provider's cache is expected to keep. `None` when it read what it
/// should.
pub fn cache_loss(
  database: store.Store,
  session: String,
  row_id: Int,
  whole_for_ms: Option(Int),
) -> Option(Loss) {
  store.snapshot(database, fn(db) {
    store.rows(
      db,
      "SELECT "
        <> columns
        <> " FROM provider_requests WHERE session=? AND id<=? AND outcome='ok' AND kind IN ('turn','background') ORDER BY id DESC LIMIT 2",
      [sqlight.text(session), sqlight.int(row_id)],
      row_decoder(),
    )
  })
  |> result.unwrap([])
  |> fn(rows) {
    case rows, whole_for_ms {
      [current, previous], Some(whole) if current.id == row_id ->
        loss_between(previous, current, whole)
      _, _ -> None
    }
  }
}

/// `cache_loss` for two calls already read.
pub fn loss_between(
  previous: Row,
  current: Row,
  whole_for_ms: Int,
) -> Option(Loss) {
  let same_prefix =
    previous.model == current.model
    && previous.effort == current.effort
    && previous.head_hash == current.head_hash
    && previous.replaced == current.replaced
    && previous.projection_hash == current.projection_hash
    && current.inputs > previous.inputs
  let warm = current.started_ms - previous.finished_ms < whole_for_ms
  case same_prefix && warm, previous.cached_input_tokens, current.input_tokens {
    True, Some(read), Some(input) if read > 0 -> {
      // What the previous call left cached: all it wrote under its marks,
      // or, from a provider that caches on its own, its whole prompt.
      let left = case previous.cache_creation_tokens, previous.input_tokens {
        Some(written), _ if written > 0 -> read + written
        _, Some(prompt) -> prompt
        _, None -> read
      }
      let lost = left - option.unwrap(current.cached_input_tokens, 0)
      case lost >= miss_floor && lost * miss_share > input {
        False -> None
        True ->
          case drifted(previous, current) {
            True -> Some(Drifted(lost))
            False -> Some(Missed(lost))
          }
      }
    }
    _, _, _ -> None
  }
}

/// Whether two rows' input chains disagree at a position both kept: the later
/// request did not repeat the earlier one's history. Rows without a chain
/// cannot say, and neither can a later row that kept none of the earlier
/// one's positions.
fn drifted(previous: Row, current: Row) -> Bool {
  case previous.input_chain, current.input_chain {
    Some(earlier), Some(later) -> {
      let later = chain_marks(later)
      list.any(chain_marks(earlier), fn(mark) {
        case list.key_find(later, mark.0) {
          Ok(hash) -> hash != mark.1
          Error(_) -> False
        }
      })
    }
    _, _ -> False
  }
}

/// The `position:hash` pairs of an `input_chain`.
fn chain_marks(chain: String) -> List(#(Int, String)) {
  string.split(chain, ",")
  |> list.filter_map(fn(mark) {
    use #(position, hash) <- result.try(string.split_once(mark, ":"))
    int.parse(position) |> result.map(fn(position) { #(position, hash) })
  })
}

// Named, in decoder order, so a column added later cannot shift a read.
const columns =
  "id,session,seq,kind,profile,provider,account,model,started_ms,finished_ms,outcome,status,error,input_tokens,cached_input_tokens,cache_creation_tokens,cache_write_5m_tokens,cache_write_1h_tokens,output_tokens,reasoning_tokens,head_hash,inputs,replaced,projection_hash,strategy,cache_marks,run_id,input_chain,first_event_ms,streamed_events,streamed_thinking_bytes,streamed_output_bytes,first_byte_ms,total_tokens,response_id,model_version,trace_id,effort"

fn row_decoder() -> decode.Decoder(Row) {
  use id <- decode.field(0, decode.int)
  use session <- decode.field(1, decode.string)
  use seq <- decode.field(2, decode.optional(decode.int))
  use kind <- decode.field(3, decode.string)
  use profile <- decode.field(4, decode.string)
  use provider <- decode.field(5, decode.string)
  use account <- decode.field(6, decode.optional(decode.string))
  use model <- decode.field(7, decode.string)
  use started <- decode.field(8, decode.int)
  use finished <- decode.field(9, decode.int)
  use outcome <- decode.field(10, decode.string)
  use status <- decode.field(11, decode.optional(decode.int))
  use error <- decode.field(12, decode.optional(decode.string))
  use input <- decode.field(13, decode.optional(decode.int))
  use cached <- decode.field(14, decode.optional(decode.int))
  use creation <- decode.field(15, decode.optional(decode.int))
  use write_5m <- decode.field(16, decode.optional(decode.int))
  use write_1h <- decode.field(17, decode.optional(decode.int))
  use output <- decode.field(18, decode.optional(decode.int))
  use reasoning <- decode.field(19, decode.optional(decode.int))
  use head_hash <- decode.field(20, decode.string)
  use inputs <- decode.field(21, decode.int)
  use replaced <- decode.field(22, decode.optional(decode.int))
  use projection_hash <- decode.field(23, decode.optional(decode.string))
  use strategy <- decode.field(24, decode.optional(decode.string))
  use cache_marks <- decode.field(25, decode.then(decode.string, marks_decoder))
  use run_id <- decode.field(26, decode.optional(decode.string))
  use input_chain <- decode.field(27, decode.optional(decode.string))
  use first_event_ms <- decode.field(28, decode.optional(decode.int))
  use events <- decode.field(29, decode.optional(decode.int))
  use thinking_bytes <- decode.field(30, decode.optional(decode.int))
  use output_bytes <- decode.field(31, decode.optional(decode.int))
  use first_byte_ms <- decode.field(32, decode.optional(decode.int))
  use total_tokens <- decode.field(33, decode.optional(decode.int))
  use response_id <- decode.field(34, decode.optional(decode.string))
  use model_version <- decode.field(35, decode.optional(decode.string))
  use trace_id <- decode.field(36, decode.optional(decode.string))
  use effort <- decode.field(37, decode.optional(decode.string))
  let streamed =
    option.map(events, fn(events) {
      stream_trace.Streamed(
        first_event_ms,
        events,
        option.unwrap(thinking_bytes, 0),
        option.unwrap(output_bytes, 0),
      )
    })
  decode.success(Row(
    id,
    session,
    seq,
    kind,
    profile,
    provider,
    account,
    model,
    effort,
    started,
    finished,
    outcome,
    status,
    error,
    input,
    cached,
    creation,
    write_5m,
    write_1h,
    output,
    reasoning,
    head_hash,
    inputs,
    replaced,
    projection_hash,
    strategy,
    cache_marks,
    run_id,
    input_chain,
    streamed,
    first_byte_ms,
    total_tokens,
    response_id,
    model_version,
    trace_id,
  ))
}

/// A durable cache mark: `{"through":"tools"|"system"|"input",
/// "index"?, "ttlSeconds"}`.
fn cache_mark_json(mark: types.CacheMark) -> Json {
  let through = case mark.through {
    types.ToolsSpan -> [#("through", json.string("tools"))]
    types.SystemSpan -> [#("through", json.string("system"))]
    types.InputSpan(index) -> [
      #("through", json.string("input")),
      #("index", json.int(index)),
    ]
  }
  json.object(
    list.append(through, [#("ttlSeconds", json.int(mark.ttl_seconds))]),
  )
}

fn marks_decoder(stored: String) -> decode.Decoder(List(types.CacheMark)) {
  let mark = {
    use through <- decode.field("through", decode.string)
    use index <- decode.optional_field("index", 0, decode.int)
    use ttl_seconds <- decode.field("ttlSeconds", decode.int)
    case through {
      "tools" -> decode.success(types.ToolsSpan)
      "system" -> decode.success(types.SystemSpan)
      "input" -> decode.success(types.InputSpan(index))
      _ -> decode.failure(types.SystemSpan, "a cache mark span")
    }
    |> decode.map(types.CacheMark(_, ttl_seconds))
  }
  case json.parse(stored, decode.list(mark)) {
    Ok(marks) -> decode.success(marks)
    Error(_) -> decode.failure([], "stored cache marks")
  }
}

/// The ms clock request rows are timestamped with.
pub fn now() -> Int {
  clock.system_ms()
}
/// Rows a page asks for when it does not say.
