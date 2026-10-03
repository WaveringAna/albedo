package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"net/http"
)

const ProtocolVersion = 3

type ServerInfo struct {
	State        string
	Protocol     int
	InstanceID   string
	Capabilities map[string]int64
	Build        string
	Digest       string
	Notices      []ServerNotice
}
type ServerNotice struct{ ID, Kind, Message string }

func decodeServer(body []byte) (ServerInfo, error) {
	var server wireServer
	if err := decodeRequired(body, &server, "instance_id", "protocol", "state", "capabilities", "build", "digest", "extensions", "quota", "notices"); err != nil {
		return ServerInfo{}, &ProtocolError{Code: "invalid_server", Operation: "read server", Cause: err}

	}
	if server.InstanceID == "" || server.Protocol <= 0 || server.Capabilities == nil || (server.State != "ready" && server.State != "draining") {
		return ServerInfo{}, &ProtocolError{Code: "invalid_server", Operation: "read server", Cause: errors.New("missing daemon identity, protocol, state, or capabilities")}
	}
	return ServerInfo{State: server.State, Protocol: int(server.Protocol), InstanceID: server.InstanceID, Capabilities: server.Capabilities, Build: value(server.Build), Digest: value(server.Digest), Notices: noticeValues(server.Notices)}, nil

}

func ProbeServer(ctx context.Context, conn *Connection) (ServerInfo, error) {
	if conn == nil {
		return ServerInfo{}, errors.New("not connected to Albedo")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	body, err := requestBytes(ctx, conn, operation{Name: "read server", Method: http.MethodGet, Path: "/server", Policy: noRecovery}, responseLimits{successStatus: 200, bodyBytes: 1048576, errorBytes: 65536})
	if err != nil {
		return ServerInfo{}, err
	}
	return decodeServer(body)
}

func CheckCompatible(server ServerInfo) error {
	failure := &CompatibilityError{Version: server.Protocol}
	for _, name := range []string{"durable_inputs", "session_replay", "collection_invalidation", "tool_progress"} {
		if server.Capabilities[name] < 1 {
			failure.MissingCapabilities = append(failure.MissingCapabilities, name)
		}
	}
	if server.Protocol != ProtocolVersion || len(failure.MissingCapabilities) > 0 {
		return failure
	}
	if server.State != "ready" {
		return &APIError{StatusCode: 503, Code: "server_draining", Message: "the daemon is draining"}
	}
	return nil
}

func Attach(ctx context.Context, snapshot ConnectionSnapshot, rediscover Rediscovery) (*Connection, error) {
	if snapshot.Port < 1 || snapshot.Port > 65535 || snapshot.Token == "" {
		return nil, &ProtocolError{Code: "invalid_endpoint", Operation: "attach daemon", Cause: errors.New("daemon endpoint requires a valid port and token")}
	}
	conn := NewConnection(snapshot, rediscover)
	server, err := ProbeServer(ctx, conn)
	if err == nil {
		err = CheckCompatible(server)
	}
	if err != nil {
		conn.HTTPClient().CloseIdleConnections()
		return nil, err
	}
	snapshot.Version, snapshot.Build, snapshot.Digest, snapshot.InstanceID = server.Protocol, server.Build, server.Digest, server.InstanceID
	conn.state.Store(&connectionState{endpoint: snapshot, capabilities: maps.Clone(server.Capabilities)})

	return conn, nil
}

func StopDaemon(ctx context.Context, conn *Connection) error {
	instanceID := conn.Snapshot().InstanceID
	if instanceID == "" {
		server, err := ProbeServer(ctx, conn)
		if err != nil {
			return err
		}
		instanceID = server.InstanceID
	}
	return executeMutation(ctx, conn, operation{Name: "stop daemon", Method: http.MethodPost, Path: "/server/shutdown", Body: struct {
		InstanceID string `json:"instance_id"`
	}{instanceID}, Policy: noRecovery}, []int{202}, func(data []byte, _ int) error {
		var reply wireShutdown
		if err := json.Unmarshal(data, &reply); err != nil {
			return err
		}
		if reply.InstanceID != instanceID || reply.State != "draining" {
			return fieldError("shutdown")
		}
		return nil
	})
}

func noticeValues(rows []struct {
	ID      string `json:"id"`
	Kind    string `json:"kind"`
	Message string `json:"message"`
}) []ServerNotice {
	result := []ServerNotice{}
	for _, row := range rows {
		result = append(result, ServerNotice{ID: row.ID, Kind: row.Kind, Message: row.Message})
	}
	return result
}
func DismissServerNotices(ctx context.Context, conn *Connection, etag string, ids []string) error {
	_, err := patchSettingsGroup[wireUISettings](ctx, conn, "ui", etag, map[string]any{"dismissed_notices": ids})
	return err
}

// BuildIdentity identifies daemon code by its label and content digest.
type BuildIdentity struct {
	Build  string
	Digest string
}

// BuildMismatch offers a restart unless matching digests, or matching labels
// when digests are unavailable, establish that the code is the same.
func BuildMismatch(running, selected BuildIdentity) bool {
	if running.Digest != "" && selected.Digest != "" {
		return running.Digest != selected.Digest
	}
	if running.Build != "" && selected.Build != "" {
		return running.Build != selected.Build
	}
	return true
}
