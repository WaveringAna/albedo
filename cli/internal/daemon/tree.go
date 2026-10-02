package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type TreeCheckpoint struct {
	Timestamp *int64 `json:"timestamp,omitempty"`
	Type      string `json:"type"`
	Preview   string `json:"preview"`
	ID        int    `json:"id"`
}

type TreePage struct {
	NextCursor *int             `json:"nextCursor"`
	Items      []TreeCheckpoint `json:"items"`
	HasMore    bool             `json:"hasMore"`
}

func GetSessionTree(ctx context.Context, conn *Connection, session string, after, limit int) (TreePage, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var result TreePage
	if err := checkCapability(ctx, conn, "session_tree", "for /tree"); err != nil {
		return result, err
	}
	err := executeRead(ctx, conn, operation{Name: "get session tree", Method: http.MethodGet, Path: sessionPath(session, fmt.Sprintf("/tree?after=%d&limit=%d", after, limit)), Policy: readRecovery}, func(data []byte) error {
		fields, err := object(data)
		if err != nil {
			return err
		}
		var rows []json.RawMessage
		if err = required(fields, "items", &rows); err != nil {
			return err
		}
		if err = nullable(fields, "nextCursor", &result.NextCursor); err != nil {
			return err
		}
		if err = required(fields, "hasMore", &result.HasMore); err != nil {
			return err
		}
		if result.NextCursor != nil && (*result.NextCursor < 0 || *result.NextCursor <= after) {
			return fieldError("nextCursor")
		}
		if result.HasMore && (result.NextCursor == nil || len(rows) == 0) {
			return fieldError("nextCursor")
		}
		previous := after
		result.Items = make([]TreeCheckpoint, 0, len(rows))
		for _, row := range rows {
			fields, err := object(row)
			if err != nil {
				return err
			}
			var item TreeCheckpoint
			if err = required(fields, "id", &item.ID); err != nil {
				return err
			}
			if err = required(fields, "type", &item.Type); err != nil {
				return err
			}
			if err = required(fields, "preview", &item.Preview); err != nil {
				return err
			}
			if err = nullable(fields, "timestamp", &item.Timestamp); err != nil {
				return err
			}
			if item.ID <= previous {
				return fieldError("id")
			}
			previous = item.ID
			result.Items = append(result.Items, item)
		}
		if result.HasMore && result.NextCursor != nil && *result.NextCursor != previous {
			return fieldError("nextCursor")
		}
		return nil
	})
	return result, err
}
