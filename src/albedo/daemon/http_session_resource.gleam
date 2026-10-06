//// A complete session resource, captured once by the session owner.

import albedo/daemon/conversation
import albedo/daemon/http_active_output
import albedo/daemon/http_api
import albedo/daemon/http_configuration
import albedo/daemon/http_transcript
import albedo/daemon/http_wire
import albedo/daemon/operations
import albedo/daemon/session
import albedo/daemon/session_submission
import albedo/daemon/store
import albedo/harness/extension/selection
import albedo/harness/page
import albedo/harness/runtime
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub fn creation(
  record: conversation.CreationRecord,
) -> Result(json.Json, http_api.Failure) {
  case record.submitted, record.resolved {
    Some(submitted), Some(resolved) -> {
      use submitted <- result.try(
        http_api.json_value(submitted)
        |> result.map_error(fn(_) {
          http_api.Failure(
            503,
            "creation_unavailable",
            "stored creation intent is unavailable",
          )
        }),
      )
      use resolved <- result.try(
        http_api.json_value(resolved)
        |> result.map_error(fn(_) {
          http_api.Failure(
            503,
            "creation_unavailable",
            "stored creation resolution is unavailable",
          )
        }),
      )
      Ok(json.object([#("submitted", submitted), #("resolved", resolved)]))
    }
    None, None -> Ok(json.null())
    _, _ ->
      Error(http_api.Failure(
        503,
        "creation_unavailable",
        "stored creation provenance is incomplete",
      ))
  }
}

fn pending_input(input: operations.Pending) -> json.Json {
  let submission = session_submission.decode(input.payload)
  let preview = http_api.scalar_prefix(submission.display, 256)
  json.object([
    #("id", json.string(input.id)),
    #("kind", json.string(input.kind)),
    #(
      "preview",
      json.object([
        #("text", json.string(preview)),
        #("transcript_count", json.int(0)),
        #("truncated", json.bool(preview != submission.display)),
      ]),
    ),
    #("accepted_at", http_wire.timestamp(input.accepted_at)),
    #("acceptance_order", json.int(input.acceptance_order)),
    #("delivery", json.string("pending")),
    #(
      "blocking_reason",
      json.nullable(input.blocking_reason, http_api.reason("input_blocked", _)),
    ),
  ])
}

fn composition_value(observed: runtime.CompositionObservation) -> json.Json {
  json.object([
    #("desired_revision", json.string(observed.desired_revision)),
    #("loaded_revision", json.nullable(observed.loaded_revision, json.string)),
    #("needs_reload", json.bool(observed.needs_reload)),
    #(
      "dependencies",
      json.object(
        dict.to_list(observed.dependencies)
        |> list.map(fn(item) { #(item.0, json.array(item.1, json.string)) }),
      ),
    ),
    #(
      "quarantine",
      json.array(list.take(observed.quarantine, 200), fn(item) {
        json.object([
          #("id", json.string(item.name)),
          #("reason", http_api.reason("extension_unavailable", item.reason)),
        ])
      }),
    ),
    #(
      "availability",
      json.object(
        dict.to_list(observed.availability)
        |> list.map(fn(item) { #(item.0, json.bool(item.1)) }),
      ),
    ),
  ])
}

fn glance_row(row: page.Row) -> json.Json {
  json.object([
    #("id", json.string(row.id)),
    #("text", json.string(http_api.scalar_prefix(row.text, 256))),
    #("badge", json.string(row.badge)),
    #("detail", json.string(http_api.scalar_prefix(row.detail, 256))),
    #("resource", json.null()),
    #(
      "tone",
      json.string(case row.tone {
        page.Plain -> "plain"
        page.Active -> "active"
        page.Warning -> "warning"
        page.Muted -> "muted"
      }),
    ),
  ])
}

fn glance_value(glance: selection.Glance) -> json.Json {
  json.object([
    #("extension", json.string(glance.extension)),
    #("title", json.string(glance.value.title)),
    #("rows", json.array(glance.value.rows, glance_row)),
    #("url", json.string(glance.url)),
  ])
}

pub fn encode(
  secret: String,
  ledger: store.Store,
  capture: session.Capture,
  tail: Int,
) -> Result(json.Json, http_api.Failure) {
  use provenance <- result.try(
    conversation.creation(ledger, capture.info.id)
    |> result.map_error(http_api.failure),
  )
  use creation <- result.try(case provenance {
    None -> Ok(json.null())
    Some(record) -> creation(record)
  })
  let boundary =
    http_transcript.Cursor(
      capture.history_high_water,
      capture.continuation_high_water,
      "before",
      capture.history_high_water + 1,
      0,
      0,
      False,
      tail,
    )
  use history <- result.try(case tail {
    0 ->
      Ok(
        json.object([
          #("items", json.array([], fn(value) { value })),
          #("high_water", json.int(capture.history_high_water)),
          #(
            "older",
            case
              capture.history_high_water > 0
              || capture.continuation_high_water > 0
            {
              True ->
                http_transcript.token(
                  secret,
                  capture.info.id,
                  "entries",
                  100,
                  http_transcript.Cursor(..boundary, rows: 100),
                )
              False -> json.null()
            },
          ),
          #("newer", json.null()),
        ]),
      )
    _ ->
      http_transcript.project(
        secret,
        ledger,
        capture.info.id,
        "entries",
        tail,
        boundary,
      )
  })
  Ok(
    json.object(
      list.append(http_wire.summary_fields(capture), [
        #(
          "active_output",
          json.array(capture.active_output, fn(output) {
            http_active_output.snapshot(
              secret,
              capture.info.id,
              capture.cursor.generation,
              output,
            )
          }),
        ),
        #("creation", creation),
        #(
          "revision",
          json.string(http_configuration.revision(capture.configuration)),
        ),
        #(
          "family_revision",
          json.string(http_configuration.family_revision(capture.configuration)),
        ),
        #(
          "configuration_resource",
          http_configuration.resource(capture.configuration),
        ),
        #(
          "workspace_change",
          json.nullable(capture.workspace_change, fn(change) {
            json.object([
              #("active", json.string(change.active)),
              #("desired", json.string(change.desired)),
              #(
                "revision",
                json.string("workspace-" <> int.to_string(change.revision)),
              ),
              #("state", json.string("deferred")),
            ])
          }),
        ),
        #(
          "selection",
          json.object([
            #(
              "overrides",
              http_configuration.selection(capture.configuration.selection),
            ),
            #(
              "effective",
              json.object(
                list.map(
                  [
                    #("extensions", "extension"),
                    #("skills", "skill"),
                    #("instructions", "instruction"),
                    #("mcp", "mcp"),
                  ],
                  fn(kind) {
                    #(
                      kind.0,
                      json.object(
                        capture.composition.discovery.candidates
                        |> list.filter(fn(candidate) {
                          candidate.kind == kind.1
                        })
                        |> list.map(fn(candidate) {
                          #(
                            candidate.id,
                            json.bool(candidate.effective_enabled),
                          )
                        }),
                      ),
                    )
                  },
                ),
              ),
            ),
          ]),
        ),
        #("composition", composition_value(capture.composition)),
        #("kernel", http_wire.kernel(capture.kernel)),
        #("pending_inputs", json.array(capture.pending_inputs, pending_input)),
        #("input_order", json.int(capture.input_order)),
        #("usage", http_wire.usage(capture.usage)),
        #("history", history),
        #("glances", json.array(capture.composition.glances, glance_value)),
      ]),
    ),
  )
}
