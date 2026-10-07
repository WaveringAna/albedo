package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
)

// UpgradeRequiredError identifies a feature missing from the running daemon.
type UpgradeRequiredError struct {
	Feature string
}

func (e *UpgradeRequiredError) Error() string {
	return "the running copy of Albedo needs an update " + e.Feature + "; restarting will interrupt work in all sessions and clear their Python variables; when you are ready, run albedo daemon --stop, then launch your updated copy of Albedo"
}

// APIError retains the HTTP status and daemon error code independently of copy.
type APIError struct {
	Cause      error
	Code       string
	Message    string
	StatusCode int
	Decision   json.RawMessage
}

func (e *APIError) Error() string {
	if e.Message != "" {
		return e.Message
	}
	if e.Cause != nil {
		return fmt.Sprintf("HTTP %d: %v", e.StatusCode, e.Cause)
	}
	if status := http.StatusText(e.StatusCode); status != "" {
		return fmt.Sprintf("HTTP %d: %s", e.StatusCode, status)
	}
	return fmt.Sprintf("HTTP %d", e.StatusCode)
}

func (e *APIError) Unwrap() error { return e.Cause }

// daemonRestarting reports whether the daemon refused because it is going
// away or not serving yet, so the one that serves next may answer.
func (e *APIError) daemonRestarting() bool {
	return e.Code == "daemon_stopping" || e.Code == "daemon_unavailable"
}

func decodeAPIError(status int, body []byte) error {
	var data struct {
		Code     string          `json:"code"`
		Detail   string          `json:"detail"`
		Title    string          `json:"title"`
		Decision json.RawMessage `json:"decision"`
	}
	apiErr := &APIError{StatusCode: status}
	if err := json.Unmarshal(body, &data); err != nil {
		return apiErr
	}
	apiErr.Code, apiErr.Message, apiErr.Decision = data.Code, data.Detail, data.Decision
	if apiErr.Message == "" {
		apiErr.Message = data.Title
	}
	return apiErr
}

// UncertainOutcomeError means the daemon may have applied a mutation. Callers
// must reconcile its result before asking the user to submit it again.
type UncertainOutcomeError struct {
	Cause     error
	Operation string
	Handle    *OperationHandle
}

func (e *UncertainOutcomeError) Error() string {
	if e.Handle != nil {
		return e.Operation + " admission is uncertain; operation " + e.Handle.ID() + " can be queried"
	}
	return e.Operation + " may have been accepted; check its result before trying again"
}

func (e *UncertainOutcomeError) Unwrap() error { return e.Cause }

// StreamFailureKind tells subscribers whether reconnecting can make progress.
type StreamFailureKind uint8

const (
	StreamTransient StreamFailureKind = iota
	StreamTerminal
	StreamProtocol
)

// StreamError preserves the cause while defining subscription recovery.
type StreamError struct {
	Kind  StreamFailureKind
	Cause error
}

func (e *StreamError) Error() string { return e.Cause.Error() }

func (e *StreamError) Unwrap() error { return e.Cause }

// CompatibilityError describes a live daemon that cannot serve this client.
type CompatibilityError struct {
	Version             int
	MissingCapabilities []string
}

func (e *CompatibilityError) Error() string {
	if e.Version != ProtocolVersion {
		return fmt.Sprintf("daemon protocol %d is incompatible with this client; required protocol is %d. Stop the daemon with a matching client (albedo daemon --stop), then relaunch this client", e.Version, ProtocolVersion)
	}
	return fmt.Sprintf("daemon protocol %d is incompatible with this client; required protocol is %d; missing capabilities: %v", e.Version, ProtocolVersion, e.MissingCapabilities)
}

// ProtocolError identifies an invalid successful API response.
type ProtocolError struct {
	Cause     error
	Code      string
	Operation string
	Field     string
}

func (e *ProtocolError) Error() string {
	if e.Field == "" {
		return fmt.Sprintf("invalid response for %s: %v", e.Operation, e.Cause)
	}
	return fmt.Sprintf("invalid response for %s (%s): %v", e.Operation, e.Field, e.Cause)
}

func (e *ProtocolError) Unwrap() error { return e.Cause }

func invalidResponse(operation operation, field string, cause error) error {
	return uncertainOperation(operation, &ProtocolError{Code: "invalid_response", Operation: operation.Name, Field: field, Cause: cause})
}

type responseFieldError struct {
	cause error
	field string
}

func (e *responseFieldError) Error() string { return e.field + ": " + e.cause.Error() }

func fieldError(field string) error {
	return &responseFieldError{field: field, cause: errors.New("required field is missing or invalid")}
}
