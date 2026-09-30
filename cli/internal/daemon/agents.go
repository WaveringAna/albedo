package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"strings"
)

// StreamAgents delivers nonempty batches until the stream ends or onBatch fails.
// The caller controls cancellation, including any blocking work in onBatch.
func StreamAgents(ctx context.Context, conn *Connection, onBatch func([]map[string]any) error) error {
	req, err := newJSONRequest(ctx, http.MethodGet, conn.BaseURL()+"/agents/stream", nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Authorization", "Bearer "+conn.Token())
	res, err := doAuthenticatedRequest(conn, req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		// Error responses may never finish; do not wait for their bodies.
		return &APIError{StatusCode: res.StatusCode}
	}
	scanner := bufio.NewScanner(res.Body)
	scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
	// The daemon sends each JSON batch on one data: line; batches do not span lines.
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		var batch struct {
			Events []map[string]any `json:"events"`
		}
		if json.Unmarshal([]byte(strings.TrimSpace(line[5:])), &batch) != nil || len(batch.Events) == 0 {
			continue
		}
		if err := onBatch(batch.Events); err != nil {
			return err
		}
	}
	return scanner.Err()
}
