package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"
)

// HistoryPage is older transcript, rendered as the stream renders a reset.
type HistoryPage struct {
	Events []StreamEvent
	Before int64 // first row of the page: the cursor for the next older one
	More   bool
}

// History returns up to rows transcript rows before the given row, oldest
// first, widened back to the start of a turn.
func (c *ChatClient) History(ctx context.Context, before int64, rows int) (*HistoryPage, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	route := fmt.Sprintf("/history?rows=%d", rows)
	if before > 0 {
		route += fmt.Sprintf("&before=%d", before)
	}
	operation := operation{Name: "read history", Method: http.MethodGet, Path: sessionPath(c.agentID, route), Body: nil, Policy: readRecovery}
	body, err := requestBytes(reqCtx, c.conn, operation, responseLimits{successStatus: http.StatusOK, bodyBytes: 32 * 1024 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return nil, err
	}

	var data struct {
		Before *int64            `json:"before"`
		More   *bool             `json:"more"`
		Events []json.RawMessage `json:"events"`
	}
	if err := json.Unmarshal(body, &data); err != nil {
		return nil, err
	}
	if data.Events == nil || data.Before == nil || data.More == nil || *data.Before < 0 {
		return nil, errors.New("invalid history page: missing events, before, or more")
	}
	page := &HistoryPage{Before: *data.Before, More: *data.More}
	for _, raw := range data.Events {
		event, err := decodeChatEvent(raw)
		if err != nil {
			return nil, err
		}
		if event != nil {
			event.Replayed = true
			page.Events = append(page.Events, event.StreamEvent)
		}
	}
	return page, nil
}
