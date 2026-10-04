//// JSON encoders for protocol 3 observations. These functions do not resolve
//// configuration, advance a session, or query storage.

import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/events
import albedo/daemon/folders
import albedo/daemon/http_api
import albedo/daemon/http_configuration
import albedo/daemon/operations
import albedo/daemon/quota
import albedo/daemon/requests
import albedo/daemon/session
import albedo/daemon/session_activity
import albedo/daemon/session_configuration
import albedo/daemon/session_namespace
import albedo/daemon/tool_progress
import albedo/daemon/usage
import albedo/harness/extensions/python/kernel as python
import albedo/harness/location
import albedo/harness/vcs
import albedo/openai_api/types
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn cursor(cursor: session.Cursor) -> json.Json {
  json.object([
    #("generation", json.string(cursor.generation)),
    #("sequence", json.int(cursor.sequence)),
  ])
}

pub fn status(status: session_activity.Status) -> json.Json {
  events.status(status)
}

pub fn activity(activity: session_activity.Projection) -> json.Json {
  events.activity(activity)
}

pub fn progress(snapshot: tool_progress.Snapshot) -> json.Json {
  events.progress(snapshot)
}

pub fn summary_fields(capture: session.Capture) -> List(#(String, json.Json)) {
  [
    #("id", json.string(capture.info.id)),
    #(
      "name",
      json.string(session_configuration.display_name(capture.configuration)),
    ),
    #("automatic_name", json.string(capture.automatic_name)),
    #("workspace", json.string(capture.info.cwd)),
    #(
      "location",
      location.parse(capture.info.cwd)
        |> result.unwrap(location.Local(capture.info.cwd))
        |> location.to_json,
    ),
    #("root_id", json.string(capture.family.root_id)),
    #(
      "parent_id",
      json.nullable(
        option.map(capture.family.member, fn(member) { member.parent }),
        json.string,
      ),
    ),
    #(
      "address",
      json.nullable(
        option.map(capture.family.member, fn(member) { member.name }),
        json.string,
      ),
    ),
    #(
      "depth",
      json.int(
        option.map(capture.family.member, fn(member) { member.depth })
        |> option.unwrap(0),
      ),
    ),
    #(
      "closed",
      json.bool(
        option.map(capture.family.member, fn(member) { member.closed })
        |> option.unwrap(False),
      ),
    ),
    #(
      "preferences",
      http_configuration.preferences(capture.configuration.preferences, True),
    ),
    #("created_at", json.nullable(capture.created_at, timestamp)),
    #("activity_at", json.nullable(capture.activity_at, timestamp)),
    #("provider_profile", case capture.info.provider {
      "" -> json.null()
      profile -> json.string(profile)
    }),
    #("model", case capture.info.model {
      "" -> json.null()
      model -> json.string(model)
    }),
    #("effort", json.nullable(capture.info.effort, json.string)),
    #("status", status(capture.status)),
    #("current_progress", json.array(capture.current_progress, progress)),
    #("activity", activity(capture.activity)),
    #("cursor", cursor(capture.cursor)),
    #("preview", session_preview(capture.preview)),
  ]
}

fn session_preview(value: conversation.Preview) -> json.Json {
  json.object([
    #("text", json.string(value.text)),
    #("transcript_count", json.int(value.transcript_count)),
    #("truncated", json.bool(value.truncated)),
  ])
}

/// Durable collection metadata remains on the page's read boundary. Only the
/// live fields come from the actor's joint lightweight summary observation.
pub fn summary(
  durable: conversation.CapturedInfo,
  live: Option(session.Summary),
  observed_at: Int,
) -> json.Json {
  let info = durable.info
  let status_value = case live {
    Some(live) -> live.status
    None ->
      session_activity.Status(
        "idle",
        None,
        False,
        option.then(
          list.first(durable.pending_inputs) |> option.from_result,
          fn(input) { input.blocking_reason },
        ),
      )
  }
  let activity_value = case live {
    Some(live) -> live.activity
    None ->
      session_activity.request(
        session_activity.new(observed_at),
        durable.current_request,
      )
  }
  json.object([
    #("id", json.string(info.id)),
    #(
      "name",
      json.string(session_configuration.display_name(durable.configuration)),
    ),
    #("automatic_name", json.string(durable.automatic_name)),
    #("workspace", json.string(info.cwd)),
    #(
      "location",
      location.parse(info.cwd)
        |> result.unwrap(location.Local(info.cwd))
        |> location.to_json,
    ),
    #("root_id", json.string(durable.family.root_id)),
    #(
      "parent_id",
      json.nullable(
        option.map(durable.family.member, fn(member) { member.parent }),
        json.string,
      ),
    ),
    #(
      "address",
      json.nullable(
        option.map(durable.family.member, fn(member) { member.name }),
        json.string,
      ),
    ),
    #(
      "depth",
      json.int(
        option.map(durable.family.member, fn(member) { member.depth })
        |> option.unwrap(0),
      ),
    ),
    #(
      "closed",
      json.bool(
        option.map(durable.family.member, fn(member) { member.closed })
        |> option.unwrap(False),
      ),
    ),
    #(
      "preferences",
      http_configuration.preferences(durable.configuration.preferences, True),
    ),
    #("created_at", json.nullable(durable.created_at, timestamp)),
    #("activity_at", json.nullable(durable.activity_at, timestamp)),
    #("provider_profile", case info.provider {
      "" -> json.null()
      profile -> json.string(profile)
    }),
    #("model", case info.model {
      "" -> json.null()
      model -> json.string(model)
    }),
    #("effort", json.nullable(info.effort, json.string)),
    #("preview", session_preview(durable.preview)),
    #("status", status(status_value)),
    #("activity", activity(activity_value)),
    #(
      "current_progress",
      json.array(
        case live {
          None -> []
          Some(live) -> live.current_progress
        },
        progress,
      ),
    ),
    #(
      "cursor",
      json.nullable(option.map(live, fn(live) { live.cursor }), cursor),
    ),
  ])
}

pub fn timestamp(value: Int) -> json.Json {
  json.string(http_api.timestamp(value))
}

pub fn kernel(observed: session_namespace.KernelObservation) -> json.Json {
  let reasons = case observed.stale {
    None -> []
    Some(python.Bundle) -> [
      http_api.reason("bundle", "kernel bundle differs from the daemon"),
    ]
    Some(python.Modules) -> [
      http_api.reason(
        "modules",
        "kernel modules differ from the session selection",
      ),
    ]
    Some(python.Protocol) -> [
      http_api.reason("protocol", "kernel protocol differs from the daemon"),
    ]
  }
  json.object([
    #("instance_id", json.nullable(observed.instance_id, json.string)),
    #("build", json.nullable(observed.build, json.string)),
    #("state", json.string(observed.state)),
    #("stage", json.nullable(observed.stage, json.string)),
    #("stale", json.bool(observed.stale != None)),
    #("staleness_reasons", json.preprocessed_array(reasons)),
    #("live_job_count", json.nullable(observed.live_job_count, json.int)),
    #(
      "running_jobs",
      json.nullable(observed.running_jobs, fn(jobs) {
        json.array(jobs, python.job_json)
      }),
    ),
  ])
}

pub fn input(outcome: operations.InputOutcome) -> json.Json {
  events.input(outcome)
}

pub fn usage(metadata: Option(usage.Metadata)) -> json.Json {
  events.usage(metadata)
}

pub fn request(row: requests.Row) -> json.Json {
  json.object([
    #("sequence", json.int(row.id)),
    #("provider", json.string(row.provider)),
    #("model", json.string(row.model)),
    #("run_id", json.nullable(row.run_id, json.string)),
    #("started_at", timestamp(row.started_ms)),
    #("ended_at", timestamp(row.finished_ms)),
    #("prompt_tokens", token_observation(row.input_tokens)),
    #("completion_tokens", token_observation(row.output_tokens)),
    #("cached_tokens", token_observation(row.cached_input_tokens)),
    #(
      "failure",
      json.nullable(row.error, fn(detail) {
        http_api.reason("provider_request_failed", detail)
      }),
    ),
    #(
      "transcript_positions",
      json.array(
        case row.seq {
          Some(position) -> [position]
          None -> []
        },
        json.int,
      ),
    ),
    #("kind", json.string(row.kind)),
    #("provider_profile", json.string(row.profile)),
    #("account_id", json.nullable(row.account, json.string)),
    #(
      "outcome",
      json.string(case row.outcome {
        "ok" -> "completed"
        "error" -> "failed"
        value -> value
      }),
    ),
    #("http_status", json.nullable(row.status, json.int)),
    #("cache_creation_tokens", token_observation(row.cache_creation_tokens)),
    #("cache_write_5m_tokens", token_observation(row.cache_write_5m_tokens)),
    #("cache_write_1h_tokens", token_observation(row.cache_write_1h_tokens)),
    #("reasoning_tokens", token_observation(row.reasoning_tokens)),
    #("head_hash", json.string(row.head_hash)),
    #("input_count", json.int(row.inputs)),
    #("replaced_input_count", json.nullable(row.replaced, json.int)),
    #("projection_hash", json.nullable(row.projection_hash, json.string)),
    #("strategy", json.nullable(row.strategy, json.string)),
    #(
      "cache_marks",
      json.array(row.cache_marks, fn(mark) {
        let #(span, index) = case mark.through {
          types.ToolsSpan -> #("tools", None)
          types.SystemSpan -> #("system", None)
          types.InputSpan(index) -> #("input", Some(index))
        }
        json.object([
          #("through", json.string(span)),
          #("index", json.nullable(index, json.int)),
          #("ttl_seconds", json.int(mark.ttl_seconds)),
        ])
      }),
    ),
  ])
}

fn token_observation(observed: Option(Int)) -> json.Json {
  json.object([
    #("estimated", json.null()),
    #("observed", json.nullable(observed, json.int)),
    #("source", case observed {
      None -> json.null()
      Some(_) -> json.string("provider")
    }),
  ])
}

pub fn quota(sample: quota.Sample) -> json.Json {
  json.object([
    #("sequence", json.int(sample.id)),
    #("account_id", json.string(sample.account)),
    #("provider", json.string(sample.provider)),
    #("plan", json.nullable(sample.plan, json.string)),
    #("limit_id", json.string(sample.limit_id)),
    #("label", json.string(sample.label)),
    #("used_percent", json.nullable(sample.used_percent, json.float)),
    #("window_label", json.nullable(sample.window_label, json.string)),
    #("window_seconds", json.nullable(sample.window_seconds, json.int)),
    #("resets_at", json.nullable(sample.resets_at, timestamp)),
    #("scope", json.nullable(sample.scope, json.string)),
    #("status", json.string(sample.status)),
    #(
      "error",
      json.nullable(sample.error, fn(detail) {
        http_api.reason("quota_failed", detail)
      }),
    ),
    #("observed_at", timestamp(sample.observed_at)),
    #("source", json.string(sample.source)),
  ])
}

pub fn preview(text: String, count: Int) -> json.Json {
  json.object([
    #("text", json.string(http_api.scalar_prefix(text, 256))),
    #("transcript_count", json.int(count)),
    #(
      "truncated",
      json.bool(
        string.byte_size(http_api.scalar_prefix(text, 256))
        < string.byte_size(text),
      ),
    ),
  ])
}

pub fn context(snapshot: context_snapshot.Snapshot) -> json.Json {
  case snapshot {
    context_snapshot.Pending(reason) ->
      json.object([
        #("state", json.string("pending")),
        #("snapshot_id", json.null()),
        #("captured_at", json.null()),
        #("provider", json.null()),
        #("model", json.null()),
        #("protocol", json.null()),
        #("context_window_tokens", json.null()),
        #(
          "compaction",
          compaction(context_snapshot.Compaction(
            None,
            context_snapshot.Unknown,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
          )),
        ),
        #("sections", json.array([], fn(value) { value })),
        #("reason", http_api.reason("context_pending", reason)),
      ])
    context_snapshot.Ready(
      id,
      captured_at,
      provider,
      model,
      protocol,
      window,
      compacted,
      sections,
      _,
    ) ->
      json.object([
        #("state", json.string("ready")),
        #("snapshot_id", json.string(id)),
        #("captured_at", json.nullable(captured_at, timestamp)),
        #("provider", json.nullable(provider, json.string)),
        #("model", json.string(model)),
        #("protocol", json.nullable(protocol, json.string)),
        #("context_window_tokens", json.nullable(window, json.int)),
        #("compaction", compaction(compacted)),
        #(
          "sections",
          json.array(sections, fn(section) {
            let text = section.content()
            let kind = case section.kind {
              context_snapshot.Instructions -> "instructions"
              context_snapshot.History -> "history"
              context_snapshot.Tools -> "tools"
              context_snapshot.Other -> "other"
            }
            json.object([
              #("id", json.string(section.id)),
              #("label", json.string(section.label)),
              #("kind", json.string(kind)),
              #("source", json.string(section.source)),
              #("item_count", json.int(section.item_count)),
              #("utf8_bytes", json.int(section.byte_count)),
              #("page_count", json.int(context_snapshot.page_count(text))),
              #("preview", preview(text, section.item_count)),
            ])
          }),
        ),
        #("reason", json.null()),
      ])
  }
}

pub fn context_page(page: context_snapshot.SectionPage) -> json.Json {
  json.object([
    #("snapshot_id", json.string(page.snapshot_id)),
    #("section_id", json.string(page.section_id)),
    #("text", json.string(page.text)),
    #("omitted", json.nullable(page.omitted, json.string)),
    #("page", json.int(page.page)),
    #("page_count", json.int(page.page_count)),
  ])
}

fn compaction(compacted: context_snapshot.Compaction) -> json.Json {
  let status = case compacted.status {
    context_snapshot.NotConfigured -> "not_configured"
    context_snapshot.NotNeeded -> "not_needed"
    context_snapshot.Compacted -> "compacted"
    context_snapshot.Unknown -> "unknown"
  }
  json.object([
    #("strategy", json.nullable(compacted.strategy, json.string)),
    #("status", json.string(status)),
    #("source", json.nullable(compacted.source, json.string)),
    #(
      "trigger_free_percent",
      json.nullable(compacted.trigger_free_percent, json.int),
    ),
    #(
      "input_limit_tokens",
      json.nullable(compacted.input_limit_tokens, json.int),
    ),
    #(
      "estimated_input_tokens",
      json.nullable(compacted.estimated_input_tokens, json.int),
    ),
    #(
      "provider_input_tokens",
      json.nullable(compacted.provider_input_tokens, json.int),
    ),
    #(
      "provider_cached_input_tokens",
      json.nullable(compacted.provider_cached_input_tokens, json.int),
    ),
    #("estimate_method", json.nullable(compacted.estimate_method, json.string)),
    #("before_items", json.nullable(compacted.before_items, json.int)),
    #("after_items", json.nullable(compacted.after_items, json.int)),
  ])
}

pub fn workspace_preview(
  observation: folders.PreviewObservation,
  workspace: String,
) -> json.Json {
  let root_location = fn(root) {
    case location.parse(workspace) {
      Ok(location.Remote(..) as remote) ->
        location.to_string(location.Remote(..remote, path: root))
      _ -> root
    }
  }
  json.object([
    #(
      "repository",
      json.nullable(observation.repository, fn(repo) {
        repository(repo, root_location)
      }),
    ),
    #("repository_diagnostic", json.null()),
    #(
      "languages",
      json.array(observation.languages, fn(language) {
        json.object([
          #("name", json.string(language.name)),
          #("bytes", json.int(language.bytes)),
          #("share", json.float(language.share)),
          #("color", json.nullable(language.color, json.string)),
        ])
      }),
    ),
    #(
      "tree",
      json.array(observation.tree, fn(entry) {
        json.object([
          #(
            "children",
            json.array(entry.children, fn(child) {
              json.object(tree_fields(child))
            }),
          ),
          #("more", json.int(entry.more)),
          ..tree_fields(entry)
        ])
      }),
    ),
    #("more", json.int(observation.more)),
  ])
}

fn tree_fields(item: folders.TreeItem) -> List(#(String, json.Json)) {
  [
    #("name", json.string(item.name)),
    #(
      "kind",
      json.string(case item.symlink, item.directory {
        True, _ -> "symlink"
        False, True -> "directory"
        False, False -> "file"
      }),
    ),
    #("location", json.string(item.location)),
    #("language", json.nullable(item.language, json.string)),
    #("changed", json.int(item.changed)),
  ]
}

fn repository(
  repo: vcs.Repo,
  root_location: fn(String) -> String,
) -> json.Json {
  case repo {
    vcs.Git(root, branch, revision, changed, touched) ->
      json.object([
        #("kind", json.string("git")),
        #("root", json.string(root_location(root))),
        #("branch", json.nullable(branch, json.string)),
        #("revision", json.nullable(revision, json.string)),
        #(
          "dirty",
          json.nullable(option.map(changed, fn(count) { count > 0 }), json.bool),
        ),
        #("added", json.null()),
        #("modified", json.null()),
        #("removed", json.null()),
        #("changed", json.nullable(changed, json.int)),
        #(
          "touched_at",
          json.nullable(touched, fn(seconds) { timestamp(seconds * 1000) }),
        ),
      ])
    vcs.Jj(root, change, bookmark, changed, touched) ->
      json.object([
        #("kind", json.string("jj")),
        #("root", json.string(root_location(root))),
        #("change_id", json.nullable(change, json.string)),
        #("revision", json.null()),
        #("description", json.null()),
        #(
          "dirty",
          json.nullable(option.map(changed, fn(count) { count > 0 }), json.bool),
        ),
        #("conflicts", json.null()),
        #("changed", json.nullable(changed, json.int)),
        #(
          "touched_at",
          json.nullable(touched, fn(seconds) { timestamp(seconds * 1000) }),
        ),
        #(
          "bookmark",
          json.nullable(bookmark, fn(bookmark) {
            json.object([
              #("name", json.string(bookmark.name)),
              #("ahead", json.int(bookmark.ahead)),
            ])
          }),
        ),
      ])
  }
}
