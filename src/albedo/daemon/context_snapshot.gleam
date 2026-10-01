//// Bounded, read-only observations of an already prepared provider request.
//// This module never prepares history, invokes tools, or calls a provider.

import albedo/daemon/events
import albedo/daemon/usage
import albedo/harness/compaction as context_size
import albedo/openai_api/request as provider_request
import albedo/openai_api/types
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const page_characters = 8000

const preview_characters = 180

pub type SectionKind {
  Instructions
  History
  Tools
  Other
}

pub opaque type Section {
  Section(
    id: String,
    label: String,
    kind: SectionKind,
    source: String,
    item_count: Int,
    byte_count: Int,
    /// Rendered only when an inspector asks. A snapshot is taken for every
    /// model step and kept by the session, so an eager render would copy the
    /// whole prepared history into a string that is almost never read.
    content: fn() -> String,
    omitted: Option(String),
  )
}

pub type CompactionStatus {
  NotConfigured
  NotNeeded
  Compacted
  Unknown
}

pub opaque type Compaction {
  Compaction(
    strategy: Option(String),
    status: CompactionStatus,
    source: Option(String),
    trigger_free_percent: Option(Int),
    input_limit_tokens: Option(Int),
    estimated_input_tokens: Option(Int),
    provider_input_tokens: Option(Int),
    provider_cached_input_tokens: Option(Int),
    estimate_method: Option(String),
    before_items: Option(Int),
    after_items: Option(Int),
  )
}

pub opaque type Snapshot {
  Pending(reason: String)
  Ready(
    captured_at: Option(Int),
    provider: Option(String),
    model: String,
    protocol: Option(String),
    context_window_tokens: Option(Int),
    compaction: Compaction,
    sections: List(Section),
    retained_tool_calls: List(String),
  )
}

fn section(
  id: String,
  label: String,
  kind: SectionKind,
  source: String,
  item_count: Int,
  byte_count: Int,
  content: String,
  omitted: Option(String),
) -> Section {
  lazy_section(
    id,
    label,
    kind,
    source,
    item_count,
    byte_count,
    fn() { content },
    omitted,
  )
}

fn lazy_section(
  id: String,
  label: String,
  kind: SectionKind,
  source: String,
  item_count: Int,
  byte_count: Int,
  content: fn() -> String,
  omitted: Option(String),
) -> Section {
  Section(
    id,
    label,
    kind,
    source,
    int.max(0, item_count),
    int.max(0, byte_count),
    content,
    omitted,
  )
}

fn compaction(
  strategy: Option(String),
  status: CompactionStatus,
  source: Option(String),
  trigger_free_percent: Option(Int),
  input_limit_tokens: Option(Int),
  estimated_input_tokens: Option(Int),
  estimate_method: Option(String),
  before_items: Option(Int),
  after_items: Option(Int),
) -> Compaction {
  Compaction(
    strategy,
    status,
    source,
    clamp_percent(trigger_free_percent),
    non_negative(input_limit_tokens),
    non_negative(estimated_input_tokens),
    None,
    None,
    estimate_method,
    non_negative(before_items),
    non_negative(after_items),
  )
}

/// Attach the completion's measured input usage to the request that produced it.
/// A newer prepared request starts without a measurement; missing provider usage
/// clears this request's measurement rather than reusing an older completion.
pub fn with_usage(snapshot: Snapshot, metadata: usage.Metadata) -> Snapshot {
  case snapshot {
    Ready(model: model, compaction: compaction, ..) if model == metadata.model -> {
      let #(input, cached) = case metadata.tokens {
        Some(usage.Tokens(
          prompt_tokens: prompt,
          cached_prompt_tokens: cached,
          ..,
        )) -> #(non_negative(Some(prompt)), non_negative(cached))
        None -> #(None, None)
      }
      Ready(
        ..snapshot,
        compaction: Compaction(
          ..compaction,
          provider_input_tokens: input,
          provider_cached_input_tokens: cached,
        ),
      )
    }
    _ -> snapshot
  }
}

/// The strategy's own token estimate for the prepared request, when it recorded one.
pub fn estimate(snapshot: Snapshot) -> Option(Int) {
  case snapshot {
    Pending(_) -> None
    Ready(compaction: compaction, ..) -> compaction.estimated_input_tokens
  }
}

pub fn pending(reason: String) -> Snapshot {
  Pending(reason)
}

fn ready(
  captured_at: Option(Int),
  provider: Option(String),
  model: String,
  protocol: Option(String),
  context_window_tokens: Option(Int),
  compaction: Compaction,
  sections: List(Section),
) -> Snapshot {
  Ready(
    non_negative(captured_at),
    provider,
    model,
    protocol,
    non_negative(context_window_tokens),
    compaction,
    sections,
    [],
  )
}

/// Build a safe inspector view from the exact request value about to be sent.
/// The input order and byte counts remain exact. Image bodies and opaque
/// provider replay objects are represented without copying their payloads.
pub fn from_request(
  captured_at: Option(Int),
  provider: String,
  protocol_name: String,
  protocol: types.Protocol,
  request: types.Request,
  observation: Option(context_size.Observation),
) -> Snapshot {
  let sections =
    [
      instructions_section(request.instructions),
      history_section(request.input, observation),
      tools_section(protocol, request.tools),
    ]
    |> list.filter_map(option.to_result(_, Nil))
  let calls =
    list.filter_map(request.input, fn(input) {
      case input {
        types.ToolOutput(id, _, _) -> Ok(id)
        _ -> Error(Nil)
      }
    })
  case
    ready(
      captured_at,
      Some(provider),
      request.model,
      Some(protocol_name),
      observation_capacity(observation),
      observation_compaction(observation),
      sections,
    )
  {
    Ready(..) as snapshot -> Ready(..snapshot, retained_tool_calls: calls)
    pending -> pending
  }
}

fn tools_section(
  protocol: types.Protocol,
  tools: List(types.Tool),
) -> Option(Section) {
  case tools {
    [] -> None
    tools -> {
      let content =
        provider_request.encode_tools(protocol, tools) |> json.to_string
      Some(section(
        "tools",
        "tool schemas",
        Tools,
        "enabled extension tool registry; exact provider encoding",
        list.length(tools),
        string.byte_size(content),
        content,
        None,
      ))
    }
  }
}

fn history_section(
  history: List(types.Input),
  observation: Option(context_size.Observation),
) -> Option(Section) {
  case history {
    [] -> None
    history ->
      Some(lazy_section(
        "history",
        "prepared conversation",
        History,
        history_source(observation),
        list.length(history),
        context_size.inputs_bytes(history),
        fn() { render_inputs(history) },
        input_omission(history),
      ))
  }
}

fn instructions_section(instructions: Option(String)) -> Option(Section) {
  case instructions {
    None -> None
    Some(instructions) ->
      Some(section(
        "instructions",
        "system instructions",
        Instructions,
        "albedo core + enabled extension instructions",
        1,
        string.byte_size(instructions),
        instructions,
        None,
      ))
  }
}

/// Tool calls in the exact prepared request, not in the durable history.
pub fn retained_tool_calls(snapshot: Snapshot) -> Option(List(String)) {
  case snapshot {
    Pending(_) -> None
    Ready(retained_tool_calls: calls, ..) -> Some(calls)
  }
}

fn render_inputs(inputs: List(types.Input)) -> String {
  inputs
  |> list.map(render_input)
  |> string.join(
    "

",
  )
}

fn render_input(input: types.Input) -> String {
  case input {
    types.User(text) -> "[user]
" <> text
    types.UserImage(text, image) -> "[user]
" <> text <> "
" <> image_label(image)
    types.Assistant(text) -> "[assistant]
" <> text
    types.ToolOutput(id, output, images) -> "[tool output · " <> id <> "]
" <> output <> string.concat(
        list.map(images, fn(image) { "\n" <> image_label(image) }),
      )
    types.Replay(_) ->
      "[provider replay item · opaque provider payload omitted]"
  }
}

fn image_label(image: types.Image) -> String {
  let #(mime, width, height, bytes) = types.image_meta(image)
  "[image · "
  <> mime
  <> " · "
  <> int.to_string(width)
  <> "×"
  <> int.to_string(height)
  <> " · "
  <> int.to_string(bytes)
  <> " decoded bytes · payload omitted]"
}

fn input_omission(inputs: List(types.Input)) -> Option(String) {
  let reasons =
    inputs
    |> list.flat_map(fn(input) {
      case input {
        types.UserImage(_, _) | types.ToolOutput(_, _, [_, ..]) -> [
          "image base64 payload",
        ]
        types.Replay(_) -> ["opaque provider replay payload"]
        _ -> []
      }
    })
  case reasons {
    [] -> None
    reasons -> Some(reasons |> list.unique |> string.join("; "))
  }
}

fn observation_capacity(
  observation: Option(context_size.Observation),
) -> Option(Int) {
  option.then(observation, fn(obs) { obs.input_limit_tokens })
}

fn observation_compaction(
  observation: Option(context_size.Observation),
) -> Compaction {
  case observation {
    None ->
      compaction(None, NotConfigured, None, None, None, None, None, None, None)
    Some(obs) ->
      compaction(
        Some(obs.strategy),
        case obs.status {
          "not_needed" -> NotNeeded
          "compacted" -> Compacted
          _ -> Unknown
        },
        Some(obs.source),
        obs.trigger_free_percent,
        obs.input_limit_tokens,
        obs.estimated_input_tokens,
        obs.estimate_method,
        obs.before_items,
        obs.after_items,
      )
  }
}

fn history_source(observation: Option(context_size.Observation)) -> String {
  case observation {
    Some(value) -> value.history_source
    None -> "durable transcript without a selected compaction strategy"
  }
}

/// Metadata and bounded previews only. Full inspectable text is returned by
/// `page`, one bounded page at a time.
pub fn summary(snapshot: Snapshot) -> json.Json {
  case snapshot {
    Pending(reason) ->
      json.object([
        #("state", json.string("pending")),
        #("reason", json.string(reason)),
      ])
    Ready(
      captured_at,
      provider,
      model,
      protocol,
      context_window_tokens,
      compacted,
      sections,
      _,
    ) ->
      // Optional detail fields lead the wire order; absent ones are omitted.
      json.object(
        list.flatten([
          events.opt("context_window_tokens", context_window_tokens, json.int),
          events.opt("protocol", protocol, json.string),
          events.opt("provider", provider, json.string),
          events.opt("captured_at", captured_at, json.int),
          [
            #("state", json.string("ready")),
            #("model", json.string(model)),
            #("compaction", compaction_json(compacted)),
            #("sections", json.array(sections, section_json)),
          ],
        ]),
      )
  }
}

/// Return one bounded page of inspectable content. Binary image bodies,
/// credentials, and other intentionally excluded values are named by `omitted`.
pub fn page(
  snapshot: Snapshot,
  section_id: String,
  index: Int,
) -> Result(json.Json, String) {
  case snapshot {
    Pending(_) -> Error("no request has been prepared")
    Ready(sections: sections, ..) -> {
      use section <- result.try(
        list.find(sections, fn(section) { section.id == section_id })
        |> result.replace_error("context section not found"),
      )
      let content = section.content()
      let pages = page_count(content)
      case index >= 0 && index < pages {
        False -> Error("context page not found")
        True -> {
          let fields = [
            #("section", json.string(section.id)),
            #("page", json.int(index)),
            #("pages", json.int(pages)),
            #(
              "content",
              json.string(string.slice(
                content,
                index * page_characters,
                page_characters,
              )),
            ),
          ]
          Ok(
            json.object(
              list.flatten([
                events.opt("omitted", section.omitted, json.string),
                fields,
              ]),
            ),
          )
        }
      }
    }
  }
}

fn section_json(section: Section) -> json.Json {
  let content = section.content()
  json.object([
    #("id", json.string(section.id)),
    #("label", json.string(section.label)),
    #("kind", json.string(kind_name(section.kind))),
    #("source", json.string(section.source)),
    #("item_count", json.int(section.item_count)),
    #("byte_count", json.int(section.byte_count)),
    #("preview", json.string(preview(content))),
    #("pages", json.int(page_count(content))),
  ])
}

fn compaction_json(value: Compaction) -> json.Json {
  json.object(
    list.flatten([
      events.opt("after_items", value.after_items, json.int),
      events.opt("before_items", value.before_items, json.int),
      events.opt("estimate_method", value.estimate_method, json.string),
      events.opt(
        "provider_cached_input_tokens",
        value.provider_cached_input_tokens,
        json.int,
      ),
      events.opt("provider_input_tokens", value.provider_input_tokens, json.int),
      events.opt(
        "estimated_input_tokens",
        value.estimated_input_tokens,
        json.int,
      ),
      events.opt("input_limit_tokens", value.input_limit_tokens, json.int),
      events.opt("trigger_free_percent", value.trigger_free_percent, json.int),
      events.opt("source", value.source, json.string),
      events.opt("strategy", value.strategy, json.string),
      [#("status", json.string(status_name(value.status)))],
    ]),
  )
}

fn preview(content: String) -> String {
  let clean =
    content
    |> string.replace(
      "
",
      " ",
    )
    |> string.trim
  case string.length(clean) > preview_characters {
    True -> string.slice(clean, 0, preview_characters - 1) <> "…"
    False -> clean
  }
}

fn page_count(content: String) -> Int {
  case string.length(content) {
    0 -> 0
    size -> { size + page_characters - 1 } / page_characters
  }
}

fn kind_name(kind: SectionKind) -> String {
  case kind {
    Instructions -> "instructions"
    History -> "history"
    Tools -> "tools"
    Other -> "other"
  }
}

fn status_name(status: CompactionStatus) -> String {
  case status {
    NotConfigured -> "not_configured"
    NotNeeded -> "not_needed"
    Compacted -> "compacted"
    Unknown -> "unknown"
  }
}

fn non_negative(value: Option(Int)) -> Option(Int) {
  case value {
    Some(value) if value >= 0 -> Some(value)
    _ -> None
  }
}

fn clamp_percent(value: Option(Int)) -> Option(Int) {
  case non_negative(value) {
    Some(value) if value <= 100 -> Some(value)
    _ -> None
  }
}
