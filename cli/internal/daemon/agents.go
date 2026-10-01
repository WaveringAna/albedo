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
	operation := Operation{Name: "stream agents", Method: http.MethodGet, Path: "/agents/stream", Policy: ReadRecovery}
	return scanEventStream(ctx, conn, operation, streamLimits{lineBytes: 8 * 1024 * 1024}, func(scanner *bufio.Scanner) error {
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
		return nil
	})
}
