package daemon

import (
	"albedo/cli/internal/daemon/protocol"
	"context"
	"io"
	"net/http"
)

// GetArtifact reads an artifact and its version history for opening a page.
func GetArtifact(ctx context.Context, conn *Connection, id string) (protocol.ArtifactDetail, error) {
	var result protocol.ArtifactDetail
	err := executeRead(ctx, conn, operation{Name: "read artifact", BuildRequest: func(base string, _ io.Reader) (*http.Request, error) {
		return protocol.NewGetArtifactRequest(base, protocol.ArtifactID(id))
	}, Policy: readRecovery}, func(data []byte) error {
		return decodeRequired(data, &result)
	})
	return result, err
}
