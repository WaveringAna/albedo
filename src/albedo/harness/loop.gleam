//// Model → tools → model. The session owns cancellation and durable commits.

import albedo/daemon/conversation
import albedo/daemon/events as view
import albedo/daemon/image_fit
import albedo/daemon/requests
import albedo/daemon/transcript
import albedo/daemon/usage
import albedo/harness/cache_fade
import albedo/harness/cache_ttl
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Loop {
  Loop(
    model: String,
    effort: Option(String),
    host: runtime.Runtime,
    kernel: runtime.Session,
    pin: Pin,
    upstream: extension.Upstream,
    publish: fn(String) -> Bool,
    /// Commits inputs at a stage; a model response passes how long the
    /// model thought before it. Answers the shared daemon time and the seq
    /// of the commit's first assistant row, which the call's request row
    /// links to.
    commit: fn(List(types.Input), conversation.Stage, Option(Int)) ->
      Result(#(Int, Option(Int)), String),
    /// Appends image fit rows ahead of the request that needs them.
    commit_fits: fn(List(transcript.ImageFit)) -> Result(Nil, String),
    record_context: fn(types.Request, Option(compaction.Observation), Bool) ->
      Nil,
    record_usage: fn(usage.Metadata) -> Result(Nil, String),
    drain_steering: fn() -> Result(List(types.Input), String),
    /// Reports the pin's compaction baseline (`Some`) or that compaction
    /// replaced the history the pinned prompt was cached with (`None`).
    report_pin: fn(Option(Int)) -> Nil,
    /// Reports each successful turn call as it went out, for the session's
    /// extensions to hear.
    report_call: fn(extension.SentCall) -> Nil,
    /// The session whose provider requests are recorded.
    session: String,
    /// The saved profile those calls went through.
    profile: String,
  )
}

/// A live session keeps the system prompt it was cached with after its
/// capabilities change; the change reaches the model as a transcript update
/// instead. `head` is how many original inputs compaction had replaced when
/// the pin was first used, so a new compaction, which invalidates the cache
/// anyway, can drop the pin.
pub type Pin {
  Unpinned
  Pinned(prompt: conversation.PinnedPrompt, head: Option(Int))
}

pub fn stopped_message(
  finish: types.Finish,
  output: List(types.ReplayItem),
) -> String {
  let failure = "model stopped: " <> string.inspect(finish)
  let response =
    output
    |> list.map(view.output_text)
    |> list.filter(fn(text) { text != "" })
    |> string.join("\n\n")
  case response {
    "" -> failure
    response -> failure <> "\n\n" <> response
  }
}

pub fn run(
  state: Loop,
  id: String,
  inputs: List(types.Input),
  step: Int,
) -> Result(Nil, String) {
  use _ <- result.try(checkpoint(state))
  use inputs <- result.try(fit_history(state, inputs))
  let original = list.reverse(inputs)
  use prepared <- result.try(prepare(state, original, False))
  let #(state, history) = settle_pin(state, original, prepared.inputs)
  case state.pin {
    Unpinned ->
      state.report_pin(Some(
        list.length(original) - compaction.common_suffix(original, history),
      ))
    Pinned(..) -> Nil
  }
  let current_instructions = request_instructions(state)
  let request = request(state, current_instructions, history)
  state.record_context(request, prepared.observation, prepared.compacted)
  use #(row, turn, sent) <- result.try(
    call(
      state,
      requests.Turn,
      request,
      request_prefix(request, history, original, prepared.observation),
      state.publish,
      fn(event) {
        case view.stream_event(id, step, event) {
          Some(serialized) ->
            case state.publish(serialized) {
              True -> types.Continue
              False -> types.Stop
            }
          None -> types.Continue
        }
      },
    )
    |> result.map_error(describe(state.upstream, _)),
  )
  let cache = fading(state, sent)
  let completed_usage =
    usage.from_completion(state.model, turn.usage, usage.now(), cache)
  let replay = list.map(turn.output, types.Replay)
  use #(timestamp, seq) <- result.try(state.commit(
    replay,
    case turn.tool_calls {
      [] -> conversation.Idle
      _ -> conversation.Tool
    },
    turn.thought_ms,
  ))
  attach(state, row, seq)
  list.each(replay, fn(input) {
    let _ =
      list.each(view.assistant_message(input, Some(timestamp)), state.publish)
  })
  use _ <- result.try(state.record_usage(completed_usage))
  let _ = state.publish(usage.event(completed_usage))
  case turn.tool_calls {
    [] ->
      case turn.finish {
        types.Complete -> {
          use steering <- result.try(state.drain_steering())
          case steering {
            [] -> Ok(Nil)
            _ -> run(state, id, unshift(inputs, [replay, steering]), step + 1)
          }
        }
        _ -> Error(stopped_message(turn.finish, turn.output))
      }
    calls -> {
      use results <- result.try(list.try_map(calls, run_tool(state, _)))
      use steering <- result.try(state.drain_steering())
      use _ <- result.try(state.commit([], conversation.Model, None))
      run(state, id, unshift(inputs, [replay, results, steering]), step + 1)
    }
  }
}

/// `inputs`, newest first, with the images the provider would refuse swapped
/// for fitted copies. The fits are committed first, so a history loaded from
/// the transcript carries the same copies.
fn fit_history(
  state: Loop,
  inputs: List(types.Input),
) -> Result(List(types.Input), String) {
  use fits <- result.try(image_fit.needed(
    state.upstream.images,
    list.reverse(inputs),
  ))
  case fits {
    [] -> Ok(inputs)
    _ -> {
      use _ <- result.try(state.commit_fits(fits))
      let notes = list.map(fits, fn(fit) { types.User(fit.note) })
      list.map(inputs, fn(input) { list.fold(fits, input, image_fit.apply) })
      |> list.append(list.reverse(notes), _)
      |> Ok
    }
  }
}

/// Force the session's selected strategy without sending an ordinary assistant turn.
/// The durable transcript remains unchanged; the next request uses the saved projection.
pub fn compact(state: Loop, inputs: List(types.Input)) -> Result(Nil, String) {
  use _ <- result.try(checkpoint(state))
  // `inputs` accumulates newest-first; strategies read chronological history.
  let original = list.reverse(inputs)
  use prepared <- result.try(prepare(state, original, True))
  let history = prepared.inputs
  // The projection keeps a verbatim tail, so everything before the shared
  // suffix is what the strategy's replacement stands in for.
  let suffix = compaction.common_suffix(original, history)
  let evicted = list.length(inputs) - suffix
  let _ = case evicted > 0 {
    True -> {
      // The summary replaced the history the pinned prompt was cached with.
      case state.pin {
        Pinned(..) -> state.report_pin(None)
        Unpinned -> Nil
      }
      state.publish(
        view.event("compacted", [
          #("evicted", json.int(evicted)),
          // Clients word the notice by strategy: a summary, folds, frames.
          #("strategy", case prepared.observation {
            Some(observation) -> json.string(observation.strategy)
            None -> json.null()
          }),
          #(
            "summary",
            json.string(
              display_text(list.take(history, list.length(history) - suffix)),
            ),
          ),
        ]),
      )
    }
    False ->
      state.publish(view.text(
        "note",
        "history already fits; nothing new to compact",
      ))
  }
  state.report_pin(Some(evicted))
  let instructions = case evicted > 0 {
    True -> current_instructions(state)
    False -> request_instructions(state)
  }
  // A forced compaction keeps the default options; an ordinary turn sets effort.
  state.record_context(
    types.Request(
      ..request(state, instructions, history),
      options: types.defaults,
    ),
    prepared.observation,
    prepared.compacted,
  )
  Ok(Nil)
}

/// One background call: `request` sent exactly as given — never rebuilt
/// through `prepare`, which could compact or call the summarizer — and
/// recorded under `prefix`. It commits nothing and publishes nothing; it
/// answers the call's usage.
pub fn background(
  state: Loop,
  request: types.Request,
  prefix: requests.Prefix,
) -> Result(Option(types.Usage), String) {
  call(
    state,
    requests.Background,
    request,
    prefix,
    // A retry is silent: a background call never shows on the stream.
    fn(_event) { True },
    fn(_event) { types.Continue },
  )
  |> result.map(fn(attempt) { attempt.1.usage })
  |> result.map_error(describe(state.upstream, _))
}

/// One tool call, committed before its transcript event; a client refusal
/// between the progress event and the result cancels the turn.
fn run_tool(state: Loop, call: types.ToolCall) -> Result(types.Input, String) {
  case state.publish(view.progress(call, "running")) {
    False -> Error("cancelled before tool execution")
    True -> {
      use output <- result.try(runtime.invoke(
        state.host,
        state.kernel,
        call,
        state.upstream.images,
      ))
      use _ <- result.try(state.commit([output], conversation.Tool, None))
      let _ = case output {
        types.ToolOutput(_, body, images) ->
          state.publish(view.tool(
            runtime.ledger(state.host),
            call,
            body,
            images,
          ))
        _ -> True
      }
      Ok(output)
    }
  }
}

/// A checkpoint event a client may refuse; a refusal ends the turn cancelled.
fn checkpoint(state: Loop) -> Result(Nil, String) {
  compaction.require(state.publish(view.event("checkpoint", [])), "cancelled")
}

/// The request this turn or a forced compaction prepares: its scoped strategy
/// view of `original`, the chronological history.
fn prepare(
  state: Loop,
  original: List(types.Input),
  force: Bool,
) -> Result(compaction.Prepared, String) {
  runtime.prepare_view_scoped(
    state.host,
    state.kernel,
    state.model,
    request_source(state.upstream, state.model),
    extension.clean_endpoint(state.upstream.endpoint),
    request_instructions(state),
    summarize(state, _),
    original,
    force,
    state.upstream.images,
  )
}

/// Newest-first `inputs` with each newest-first batch unshifted ahead of it,
/// earliest batch last.
fn unshift(
  inputs: List(types.Input),
  batches: List(List(types.Input)),
) -> List(types.Input) {
  list.fold(batches, inputs, fn(accumulated, batch) {
    list.append(list.reverse(batch), accumulated)
  })
}

fn display_text(items: List(types.Input)) -> String {
  items
  |> list.map(fn(input) {
    case input {
      types.User(text) -> text
      types.UserImage(text, _) -> text <> "\n[image omitted from this view]"
      types.ToolOutput(id, _, _) -> "[tool output " <> id <> " omitted]"
      input ->
        option.unwrap(
          view.visible_assistant_text(input),
          "[assistant tool call omitted]",
        )
    }
  })
  |> string.join("\n\n")
  |> bounded(20_000, "\n[remainder omitted]")
}

fn bounded_summary_text(text: String) -> String {
  bounded(text, 16_000, "\n[remainder omitted from compaction summary input]")
}

/// Truncated views of oversized text: `limit` graphemes, then why it ends.
fn bounded(text: String, limit: Int, note: String) -> String {
  case string.length(text) > limit {
    True -> string.slice(text, 0, limit) <> note
    False -> text
  }
}

/// Streams one provider call, recording one provider request per attempt: what
/// it cost, how it ended, and the prefix identity it went out with. The row
/// id of the attempt that succeeded is answered so its transcript seq can be
/// attached once committed, with the call as it went out. A row that cannot
/// be written is logged and skipped, never a failed turn.
fn call(
  state: Loop,
  kind: requests.Kind,
  request: types.Request,
  prefix: requests.Prefix,
  publish: fn(String) -> Bool,
  on_event: fn(types.Event) -> types.Control,
) -> Result(#(Option(Int), types.Turn, extension.SentCall), types.Error) {
  retry_stream(
    fn() {
      let started = requests.now()
      let outcome = state.upstream.stream(request, on_event)
      let finished = requests.now()
      let usage = case outcome {
        Ok(turn) -> turn.usage
        Error(_) -> None
      }
      let marks = state.upstream.cache_marks(request)
      // The account label is read after the attempt: rotation records which
      // account served while the request streams.
      let row =
        requests.record(
          runtime.ledger(state.host),
          requests.Call(
            state.session,
            kind,
            state.profile,
            provider_label(state),
            state.upstream.account(),
            request.model,
            started,
            finished,
            requests.outcome(outcome),
            usage,
            prefix,
            marks,
          ),
        )
      let row = case row {
        Ok(id) -> Some(id)
        Error(error) -> {
          io.println_error(
            "provider request record failed for session "
            <> state.session
            <> ": "
            <> error,
          )
          None
        }
      }
      let sent =
        extension.SentCall(
          request,
          prefix,
          usage,
          marks,
          state.profile,
          state.upstream.endpoint,
          state.upstream.protocol,
          started,
          finished,
        )
      // Extensions hear a turn's call as sent, never a rebuilt one.
      case kind, outcome {
        requests.Turn, Ok(_) -> state.report_call(sent)
        _, _ -> Nil
      }
      case outcome {
        Ok(turn) -> Ok(#(row, turn, sent))
        Error(error) -> Error(error)
      }
    },
    publish,
    1,
  )
}

/// Attaches the transcript row a recorded call produced — the first
/// assistant row of its response commit. A commit with no assistant row, or
/// a failed update, is logged and skipped, never a failed turn.
fn attach(state: Loop, row: Option(Int), seq: Option(Int)) -> Nil {
  case row, seq {
    Some(id), Some(seq) ->
      case requests.attach(runtime.ledger(state.host), state.session, id, seq) {
        Ok(_) -> Nil
        Error(error) ->
          io.println_error(
            "provider request seq attach failed for session "
            <> state.session
            <> ": "
            <> error,
          )
      }
    _, _ -> Nil
  }
}

/// How the cached count of a turn's call fades, by the cache table's entry
/// for where it went and the request ledger's measure of its head.
fn fading(state: Loop, sent: extension.SentCall) -> Option(cache_fade.Fade) {
  cache_fade.fade(
    cache_ttl.for_call(state.profile, sent.endpoint, sent.request.model),
    sent.marks,
    sent.usage,
    fn() {
      requests.head_tokens(
        runtime.ledger(state.host),
        state.profile,
        sent.request.model,
        sent.prefix.head_hash,
      )
    },
    sent.started_ms,
    sent.finished_ms,
  )
}

/// How a call reached its provider: the protocol over the endpoint.
fn provider_label(state: Loop) -> String {
  types.protocol_name(state.upstream.protocol) <> ":" <> state.upstream.endpoint
}

/// The request's prefix identity: its head, and the projection that stands in
/// for the history compaction replaced.
fn request_prefix(
  request: types.Request,
  history: List(types.Input),
  original: List(types.Input),
  observation: Option(compaction.Observation),
) -> requests.Prefix {
  requests.prefix(
    option.unwrap(request.instructions, ""),
    request.tools,
    history,
    original,
    option.map(observation, fn(observation) { observation.strategy }),
  )
}

/// Attempts per provider call. Waits double from 250ms, so the last retry
/// comes about 32s after the first failure: long enough to outlast a network
/// handoff or a host whose ephemeral ports sit in TIME_WAIT.
const attempts = 8

/// Reissue transient transport and gateway failures. A failed attempt has no committed output
/// or tool effects; discard its live previews before forwarding the next attempt.
fn retry_stream(
  run: fn() -> Result(a, types.Error),
  publish: fn(String) -> Bool,
  attempt: Int,
) -> Result(a, types.Error) {
  case run() {
    Error(error) ->
      case attempt < attempts && retryable(error) {
        False -> Error(error)
        True ->
          case publish(view.event("retry", [])) {
            False -> Error(types.Cancelled)
            True -> {
              sleep_retry(int.bitwise_shift_left(250, attempt - 1))
              retry_stream(run, publish, attempt + 1)
            }
          }
      }
    outcome -> outcome
  }
}

fn request_instructions(state: Loop) -> String {
  case state.pin {
    Pinned(prompt, _) -> prompt.instructions <> context_text(prompt.context)
    Unpinned -> current_instructions(state)
  }
}

/// The request this loop state implies for one prepared history: its model,
/// tools, and effort setting.
fn request(
  state: Loop,
  instructions: String,
  history: List(types.Input),
) -> types.Request {
  types.Request(
    state.model,
    Some(instructions),
    history,
    runtime.tools(state.kernel),
    None,
    types.Options(..types.defaults, effort: state.effort),
  )
}

fn current_instructions(state: Loop) -> String {
  runtime.instructions(state.kernel)
  <> context_text(runtime.context(state.kernel))
}

fn context_text(context: List(types.Input)) -> String {
  context
  |> list.filter_map(fn(input) {
    case input {
      types.User(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("\n\n")
  |> fn(text) {
    case text {
      "" -> ""
      _ -> "\n\n" <> text
    }
  }
}

/// Keeps the pin while compaction has replaced no further inputs. More
/// replaced inputs mean compaction rewrote history, so the cached prompt is
/// already lost: the pin is dropped and the current system prompt is used.
fn settle_pin(
  state: Loop,
  original: List(types.Input),
  history: List(types.Input),
) -> #(Loop, List(types.Input)) {
  case state.pin {
    Unpinned -> #(state, history)
    Pinned(prompt, baseline) -> {
      // Strategies may rebuild recap text every request, but the count of
      // original inputs they stand in for only grows when compaction runs.
      let head =
        list.length(original) - compaction.common_suffix(original, history)
      case baseline {
        None -> {
          state.report_pin(Some(head))
          #(Loop(..state, pin: Pinned(prompt, Some(head))), history)
        }
        Some(previous) if previous == head -> #(state, history)
        Some(_) -> {
          state.report_pin(None)
          #(Loop(..state, pin: Unpinned), history)
        }
      }
    }
  }
}

fn describe(upstream: extension.Upstream, error: types.Error) -> String {
  upstream.explain(error) |> option.lazy_unwrap(fn() { string.inspect(error) })
}

fn retryable(error: types.Error) -> Bool {
  case error {
    types.ConnectionError(_) | types.Timeout | types.UnexpectedEnd -> True
    types.HttpError(502, _)
    | types.HttpError(503, _)
    | types.HttpError(504, _) -> True
    _ -> False
  }
}

@external(erlang, "albedo_retry", "sleep")
fn sleep_retry(milliseconds: Int) -> Nil

fn summarize(
  state: Loop,
  request: compaction.SummaryRequest,
) -> Result(String, String) {
  let compaction.SummaryRequest(
    model,
    previous,
    evicted,
    max_output_tokens,
    instructions,
  ) = request
  let previous = option.unwrap(previous, "(none)")
  let transcript =
    evicted
    |> compaction.without_superseded
    |> list.map(render_summary_input)
    |> list.filter(fn(line) { line != "" })
    |> string.join("\n")
  let prompt =
    "<previous-summary>\n"
    <> previous
    <> "\n</previous-summary>\n<newly-evicted-history>\n"
    <> transcript
    <> "\n</newly-evicted-history>"
  let summary_request =
    types.Request(
      model,
      Some(instructions),
      [types.User(prompt)],
      [],
      Some(max_output_tokens),
      types.defaults,
    )
  use #(_, turn, _) <- result.try(
    call(
      state,
      requests.Summarizer,
      summary_request,
      // The summarizer's history is exactly what it says; nothing replaced.
      requests.direct_prefix(instructions, [], [types.User(prompt)]),
      state.publish,
      fn(_) { types.Continue },
    )
    |> result.map_error(fn(error) {
      "summarizer provider request failed: " <> describe(state.upstream, error)
    }),
  )
  let text =
    turn.output
    |> list.filter_map(fn(item) {
      view.visible_assistant_text(types.Replay(item))
      |> option.to_result(Nil)
    })
    |> string.join("")
    |> string.trim
  case text {
    "" -> Error("summarizer provider returned no text")
    value -> Ok(value)
  }
}

/// One evicted item as the summarizer reads it: image payloads never reach it.
fn render_summary_input(input: types.Input) -> String {
  case input {
    types.User(text) -> "[user]\n" <> bounded_summary_text(text)
    types.UserImage(text, image) ->
      "[user with "
      <> describe_image(image)
      <> "; binary omitted]\n"
      <> bounded_summary_text(text)
    types.Assistant(text) -> "[assistant]\n" <> bounded_summary_text(text)
    types.ToolOutput(id, output, images) ->
      "[tool output "
      <> id
      <> "]\n"
      <> bounded_summary_text(output)
      <> string.concat(
        list.map(images, fn(image) {
          "\n[" <> describe_image(image) <> "; binary omitted]"
        }),
      )
    types.Replay(item) -> render_replay(item)
  }
}

/// A provider item as the text it said and the calls it made. An item with
/// neither, such as encrypted reasoning, contributes nothing; a shape this
/// does not read is shown as its JSON, so no call is lost.
fn render_replay(item: types.ReplayItem) -> String {
  case compaction.assistant_parts(item) {
    Ok(#(text, calls)) ->
      [
        case text {
          "" -> []
          _ -> ["[assistant]\n" <> bounded_summary_text(text)]
        },
        list.map(calls, fn(call) {
          "[assistant call "
          <> call.name
          <> "]\n"
          <> bounded_summary_text(call.arguments)
        }),
      ]
      |> list.flatten
      |> string.join("\n")
    Error(_) ->
      "[assistant provider item]\n"
      <> bounded_summary_text(json.to_string(types.replay_json(item)))
  }
}

fn describe_image(image: types.Image) -> String {
  let #(mime, width, height, bytes) = types.image_meta(image)
  "image "
  <> mime
  <> " "
  <> int.to_string(width)
  <> "x"
  <> int.to_string(height)
  <> ", "
  <> int.to_string(bytes)
  <> " bytes"
}

fn request_source(upstream: extension.Upstream, model: String) -> String {
  string.join(
    [types.protocol_name(upstream.protocol), upstream.endpoint, model],
    ":",
  )
}
