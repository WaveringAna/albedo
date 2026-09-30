package daemon

import (
	"encoding/json"
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
	StatusCode int
	Code       string
	Message    string
	Cause      error
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

func decodeAPIError(status int, body []byte) error {
	var data struct {
		Code      string `json:"code"`
		Error     string `json:"error"`
		Workspace string `json:"workspace"`
	}
	apiErr := &APIError{StatusCode: status}
	if err := json.Unmarshal(body, &data); err != nil {
		return apiErr
	}
	apiErr.Code, apiErr.Message = data.Code, data.Error
	if data.Code == "workspace_missing" && data.Workspace != "" {
		apiErr.Cause = &WorkspaceMissingError{Workspace: data.Workspace}
		apiErr.Message = apiErr.Cause.Error()
	}
	return apiErr
}
