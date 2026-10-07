// A usage event's timing reaches the CLI under the daemon's keys. A key renamed
// on one side would drop every turn's rate without an error.
package daemon

import (
	"encoding/json"
	"testing"
)

func TestUsageEventKeepsTheRateTheDaemonReports(t *testing.T) {
	raw := json.RawMessage(`{"type":"usage","sequence":1,"data":{"model":"m","observed_at":null,"prompt_tokens":10,"cached_prompt_tokens":null,"cache_write_tokens":null,"completion_tokens":100,"total_tokens":110,"elapsed_ms":2000,"tokens_per_second":50,"context_window_tokens":null,"cache_ttl_seconds":null,"cache_fade":[]}}`)
	event, err := decodeChatEvent(raw)
	if err != nil {
		t.Fatal(err)
	}
	usage := event.Usage
	if usage == nil || usage.ElapsedMs == nil || *usage.ElapsedMs != 2000 || usage.TokensPerSecond == nil || *usage.TokensPerSecond != 50 {
		t.Fatalf("usage event lost its timing: %+v", usage)
	}
}
