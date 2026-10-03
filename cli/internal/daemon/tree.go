package daemon

import (
	"context"
	"io"
	"net/http"

	"albedo/cli/internal/daemon/protocol"
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
	params := protocol.GetHistoryParams{View: new("checkpoints"), Limit: new(int64(min(max(limit, 1), 200)))}
	if after > 0 {
		params.After = new(int64(after))
	}
	var result TreePage
	err := executeRead(ctx, conn, operation{Name: "read checkpoints", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetHistoryRequest(base, id, &params)
	}, Policy: readRecovery}, func(data []byte) error {
		var w protocol.CheckpointPage
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
