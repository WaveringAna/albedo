package daemon

import (
	"context"
	"net/http"
	"net/url"
	"strconv"
)

type TreeCheckpoint struct {
	Timestamp         *int64
	Type, Preview, ID string
	Position          int
}
type TreePage struct {
	NextCursor *int
	Items      []TreeCheckpoint
	HasMore    bool
}

func GetSessionTree(ctx context.Context, conn *Connection, id string, after, limit int) (TreePage, error) {
	q := url.Values{"view": {"checkpoints"}, "limit": {strconv.Itoa(min(max(limit, 1), 200))}}
	if after > 0 {
		q.Set("after", strconv.Itoa(after))
	}
	var result TreePage
	err := executeRead(ctx, conn, operation{Name: "read checkpoints", Method: http.MethodGet, Path: sessionPath(id, "/history?"+q.Encode()), Policy: readRecovery}, func(data []byte) error {
		var w wireCheckpointPage
		if err := decodeRequired(data, &w, "items", "older", "newer", "high_water"); err != nil {
			return err
		}
		result.Items = []TreeCheckpoint{}
		previous := after
		for _, row := range w.Items {
			if row.CheckpointID == "" || row.Position <= int64(previous) {
				return fieldError("checkpoint")
			}
			previous = int(row.Position)
			result.Items = append(result.Items, TreeCheckpoint{ID: row.CheckpointID, Position: int(row.Position), Type: row.TurnType, Preview: row.Preview.Text})
		}
		result.HasMore = w.Newer != nil
		if result.HasMore {
			if len(w.Items) == 0 {
				return fieldError("checkpoint page")
			}
			result.NextCursor = &previous
		}
		return nil
	})
	return result, err
}
