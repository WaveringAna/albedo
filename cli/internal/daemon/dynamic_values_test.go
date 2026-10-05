// Dynamic choices and tool arguments must preserve integers beyond float precision.
// A controlled peer advertises exact numeric values across these client surfaces.
package daemon

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
)

func TestDynamicIntegerChoicesAndToolArgumentsRemainExact(t *testing.T) {
	var field FormField
	if err := json.Unmarshal([]byte(`{"name":"version","label":"Version","type":"choice","required":true,"default":9007199254740993,"choices":[{"label":"Lower","value":9007199254740992},{"label":"Upper","value":9007199254740993}]}`), &field); err != nil {
		t.Fatal(err)
	}
	if selected := FormChoiceDefault(field); selected != 1 {
		t.Fatalf("adjacent integer defaults collapsed into choice %d", selected)
	}
	if err := validateFormValue(field, json.RawMessage(`9007199254740994`)); err == nil {
		t.Fatal("an undeclared adjacent integer choice was accepted")
	}
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		writeInitialStream(w, "chat")
		fmt.Fprintf(w, `data: {"generation":%q,"cursor":2,"events":[{"type":"tool","sequence":2,"data":{"tool_call_id":"call-1","progress_call_id":"progress-1","name":"python","arguments":{"version":9007199254740993},"result":"ok","trace":null,"content_complete":true,"reference":null}}]}`+"\n\n", generationA)
	})
	var version any
	if err := NewChatClient(conn, "test").Stream(t.Context(), 0, func(event StreamEvent) error {
		if event.Type == EventTool {
			version = event.ToolArgs["version"]
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if version != json.Number("9007199254740993") {
		t.Fatalf("tool argument integer changed: %#v", version)
	}
}
