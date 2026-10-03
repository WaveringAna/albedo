// Package testwire provides protocol 3 controlled-peer fixtures.
package testwire

import (
	"encoding/json"
	"fmt"
	"io"
)

const GenerationA = "J6kYj6IGcXyP3eMIp-WL3A"
const GenerationB = "N73vTuOSKGHtrN6EsYnLbQ"

func Session(id, generation string, sequence int64) map[string]any {
	selection := map[string]any{"extensions": map[string]bool{}, "skills": map[string]bool{}, "instructions": map[string]bool{}, "mcp": map[string]bool{}}
	config := map[string]any{"id": id, "name": "Session", "workspace": "/work", "provider_profile": nil, "model": nil, "effort": nil, "preferences": map[string]any{"pinned": false, "pin_order": nil, "archived": false}, "selection": selection, "revision": "revision-a", "family_revision": "family-a"}
	return map[string]any{
		"id": id, "name": "Session", "automatic_name": "Session", "location": map[string]any{"host": nil, "user": nil, "path": "/work", "label": nil}, "workspace": "/work", "parent_id": nil, "root_id": id, "address": nil, "depth": 0, "closed": false, "created_at": nil, "activity_at": nil, "provider_profile": nil, "model": nil, "effort": nil,
		"status":  map[string]any{"phase": "idle", "run_id": nil, "interrupt_requested": false, "blocking_reason": nil},
		"preview": map[string]any{"text": "", "transcript_count": 0, "truncated": false}, "preferences": map[string]any{"pinned": false, "pin_order": nil, "archived": false, "opens": 0}, "current_progress": []any{},
		"activity": map[string]any{"lines": []any{}, "output_scalars": 0, "output_utf8_bytes": 0, "observed_at": "2026-10-03T00:00:00Z", "latest_input": nil, "latest_answer": nil},
		"cursor":   map[string]any{"generation": generation, "sequence": sequence}, "creation": nil, "revision": "revision-a", "family_revision": "family-a", "configuration_resource": map[string]any{"url": "/sessions/" + id + "?view=configuration", "etag": "\"revision-a\"", "value": config}, "workspace_change": nil,
		"selection": map[string]any{"overrides": selection, "effective": selection}, "composition": map[string]any{"desired_revision": "composition-a", "loaded_revision": nil, "needs_reload": false, "dependencies": map[string]any{}, "quarantine": []any{}, "availability": map[string]bool{}},
		"kernel": map[string]any{"state": "none", "stage": nil, "build": nil, "stale": false, "staleness_reasons": []any{}, "live_job_count": 0, "instance_id": nil}, "pending_inputs": []any{}, "input_order": 0,
		"usage":   map[string]any{"model": nil, "observed_at": nil, "prompt_tokens": nil, "cached_prompt_tokens": nil, "cache_write_tokens": nil, "completion_tokens": nil, "total_tokens": nil, "elapsed_ms": nil, "tokens_per_second": nil, "context_window_tokens": nil, "cache_ttl_seconds": nil, "cache_fade": []any{}},
		"history": map[string]any{"items": []any{}, "older": nil, "newer": nil, "high_water": 0}, "glances": []any{},
	}
}
func Input(session, id, kind, delivery string) map[string]any {
	return map[string]any{"id": id, "session_id": session, "kind": kind, "admission": "accepted", "http_status": 202, "problem": nil, "accepted_at": "2026-10-03T00:00:00Z", "acceptance_order": 1, "delivery": delivery, "blocking_reason": nil, "transcript_position": nil, "turn": nil, "outcome": nil, "client_id": nil}
}
func Event(kind string, sequence int64, data any) map[string]any {
	return map[string]any{"type": kind, "sequence": sequence, "data": data}
}
func Text(sequence int64, text string) map[string]any {
	return Event("text", sequence, map[string]any{"run_id": "run-a", "message_id": "message-a", "text": text})
}
func WriteBatch(w io.Writer, batch any) {
	encoded, _ := json.Marshal(batch)
	_, _ = fmt.Fprintf(w, "data: %s\n\n", encoded)
}
func InitialStream(w io.Writer, kind string) {
	if kind == "agents" {
		WriteBatch(w, map[string]any{"events": []any{map[string]any{"type": "ready", "data": map[string]any{}}, map[string]any{"type": "reset", "data": map[string]any{"reason": "initial"}}}})
		return
	}
	WriteBatch(w, map[string]any{"generation": GenerationA, "cursor": 1, "events": []any{map[string]any{"type": "reset", "data": map[string]any{"reason": "initial"}}, Text(1, "hello")}, "snapshot": Session("test", GenerationA, 0)})
}
func Progress(id string) map[string]any {
	return map[string]any{"call_id": id, "tool_call_id": nil, "name": "python", "phase": "running", "intent": "", "preview": map[string]any{"text": "print(1)", "offset_scalars": 0, "complete": true}}
}

func Settings() map[string]any {
	result := map[string]any{"providers": map[string]any{"default_profile": nil, "profiles": map[string]any{}}, "mcp": map[string]any{"definitions": map[string]any{}}, "extensions": map[string]any{"defaults": map[string]bool{}}, "capabilities": map[string]any{"preferences": map[string]bool{}}, "models": map[string]any{"raised_caps": map[string]bool{}, "cache_ttl_priors": []any{}}, "ui": map[string]any{"thinking": true, "tools": false, "dismissed_notices": []any{}}}
	resources := map[string]any{}
	for _, group := range []string{"providers", "mcp", "extensions", "capabilities", "models", "ui"} {
		resources[group] = map[string]any{"url": "/settings?group=" + group, "etag": "\"" + group + "-a\""}
	}
	result["group_resources"] = resources
	return result
}
func SettingsChange(group string, value any) map[string]any {
	return map[string]any{"group": group, "resource": map[string]any{"url": "/settings?group=" + group, "etag": "\"" + group + "-b\"", "value": value}, "application": map[string]any{"desired_revision": "desired-b", "active_service_revision": nil, "needs_reload_count": 0, "session_ids": []any{}, "more": false, "validation": "validated", "warnings": []any{}}}
}
func Model(id string) map[string]any {
	return map[string]any{"id": id, "label": id, "efforts": []any{map[string]string{"id": "low", "label": "Low"}, map[string]string{"id": "high", "label": "High"}}, "default_context_tokens": nil, "effective_context_tokens": nil, "max_context_tokens": nil, "max_output_tokens": nil, "input_modalities": []any{"text", "pdf"}, "image_edge": nil, "raised": false, "cap_key": "provider/" + id, "cache_policy": map[string]any{"ttl_seconds": nil, "source": nil}, "source": "catalog", "observed_at": nil}
}

const Server = `{"instance_id":"instance-a","protocol":3,"state":"ready","capabilities":{"durable_inputs":1,"session_replay":1,"collection_invalidation":1,"tool_progress":1,"context":1,"catalog":1,"workspace_browsing":1,"host_probes":1,"provider_auth":1,"storage_report":1},"build":null,"digest":null,"extensions":[],"quota":null,"notices":[]}`
