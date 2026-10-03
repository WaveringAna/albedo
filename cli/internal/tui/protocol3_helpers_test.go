package tui

import (
	"albedo/cli/internal/testwire"
	"encoding/json"
	"net/http"
)

const generationA = testwire.GenerationA

var protocolSession = testwire.Session

func writeSessionChange(w http.ResponseWriter, id, model, provider string) {
	session := protocolSession(id, generationA, 0)
	session["model"] = model
	session["provider_profile"] = provider
	config := session["configuration_resource"].(map[string]any)
	v := config["value"].(map[string]any)
	v["model"] = model
	v["provider_profile"] = provider
	_ = json.NewEncoder(w).Encode(map[string]any{"resource": config, "session": session, "move": nil})
}
func protocolEntry(id, kind, text string, position int64) map[string]any {
	return map[string]any{"id": id, "position": position, "kind": kind, "created_at": nil, "input_id": nil, "turn_id": nil, "content_complete": true, "content": []any{map[string]any{"kind": "text", "text": text}}, "tool": nil, "checkpoint_id": nil}
}
