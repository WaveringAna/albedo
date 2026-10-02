package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"time"
)

const ProtocolVersion = 2

// Health describes the daemon's readiness and API contract.
type Health struct {
	OK           bool     `json:"ok"`
	Version      int      `json:"version"`
	Capabilities []string `json:"capabilities"`
	Build        string   `json:"build,omitempty"`
}

func decodeHealth(body []byte) (Health, error) {
	var wire struct {
		OK           *bool             `json:"ok"`
		Version      *int              `json:"version"`
		Capabilities []json.RawMessage `json:"capabilities"`
		Build        json.RawMessage   `json:"build"`
	}
	invalid := func(cause error) (Health, error) {
		return Health{}, &ProtocolError{Code: "invalid_health", Operation: "probe health", Cause: cause}
	}
	if err := json.Unmarshal(body, &wire); err != nil {
		return invalid(err)
	}
	if wire.OK == nil || !*wire.OK {
		return invalid(errors.New("health must report ok:true"))
	}
	if wire.Version == nil || *wire.Version <= 0 {
		return invalid(errors.New("health must report a positive integer version"))
	}
	if wire.Capabilities == nil {
		return invalid(errors.New("health must report a capabilities array"))
	}
	health := Health{OK: true, Version: *wire.Version, Capabilities: make([]string, 0, len(wire.Capabilities))}
	for _, raw := range wire.Capabilities {
		var capability string
		if string(raw) == "null" {
			return invalid(errors.New("health capability must be a string"))
		}
		if err := json.Unmarshal(raw, &capability); err != nil {
			return invalid(err)
		}
		health.Capabilities = append(health.Capabilities, capability)
	}
	if len(wire.Build) > 0 {
		if string(wire.Build) == "null" {
			return invalid(errors.New("health build must be a string"))
		}
		if err := json.Unmarshal(wire.Build, &health.Build); err != nil {
			return invalid(err)
		}
	}
	return health, nil
}

// ProbeHealth validates health without rediscovery or lifecycle changes.
func ProbeHealth(ctx context.Context, conn *Connection) (Health, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if conn == nil {
		return Health{}, errors.New("not connected to Albedo")
	}
	operation := Operation{Name: "probe health", Method: http.MethodGet, Path: "/health", Policy: NoRecovery}
	body, err := requestBytes(ctx, conn, operation, responseLimits{successStatus: http.StatusOK, bodyBytes: 64 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return Health{}, err
	}
	return decodeHealth(body)
}

// CheckCompatible checks the protocol and core capabilities used by this client.
func CheckCompatible(health Health) error {
	if !health.OK || health.Version <= 0 || health.Capabilities == nil {
		return &ProtocolError{Code: "invalid_health", Operation: "attach daemon", Cause: errors.New("invalid daemon health")}
	}
	failure := &CompatibilityError{Version: health.Version}
	for _, capability := range []string{"operation_receipts", "session_stream_generation", "agents_stream_overflow"} {
		if !slices.Contains(health.Capabilities, capability) {
			failure.MissingCapabilities = append(failure.MissingCapabilities, capability)
		}
	}
	if health.Version != ProtocolVersion || len(failure.MissingCapabilities) > 0 {
		return failure
	}
	return nil
}

// Attach validates an endpoint before exposing its API connection.
func Attach(ctx context.Context, snapshot ConnectionSnapshot, rediscover Rediscovery) (*Connection, error) {
	if snapshot.Port < 1 || snapshot.Port > 65535 || snapshot.Token == "" {
		return nil, &ProtocolError{Code: "invalid_endpoint", Operation: "attach daemon", Cause: errors.New("daemon endpoint requires a valid port and token")}
	}
	conn := NewConnection(snapshot, rediscover)
	health, err := ProbeHealth(ctx, conn)
	if err == nil {
		err = CheckCompatible(health)
	}
	if err != nil {
		conn.HTTPClient().CloseIdleConnections()
		return nil, err
	}
	snapshot.Version, snapshot.Build = health.Version, health.Build
	conn.snapshot.Store(&snapshot)
	return conn, nil
}

// Capabilities reads a validated health response with ordinary read recovery.
func Capabilities(ctx context.Context, conn *Connection) ([]string, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	operation := Operation{Name: "read capabilities", Method: http.MethodGet, Path: "/health", Policy: ReadRecovery}
	body, err := requestBytes(ctx, conn, operation, responseLimits{successStatus: http.StatusOK, bodyBytes: 64 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return nil, err
	}
	health, err := decodeHealth(body)
	return health.Capabilities, err
}

func CheckCapability(ctx context.Context, conn *Connection, capability, feature string) error {
	capabilities, err := Capabilities(ctx, conn)
	if err != nil {
		return err
	}
	if !slices.Contains(capabilities, capability) {
		return UpgradeNeeded(feature)
	}
	return nil
}

func UpgradeNeeded(feature string) error { return &UpgradeRequiredError{Feature: feature} }
