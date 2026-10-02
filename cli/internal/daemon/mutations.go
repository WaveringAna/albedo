package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

// ProtocolError identifies an invalid successful mutation response.
type ProtocolError struct {
	Cause     error
	Code      string
	Operation string
	Field     string
}

func (e *ProtocolError) Error() string {
	return fmt.Sprintf("invalid response for %s (%s): %v", e.Operation, e.Field, e.Cause)
}
func (e *ProtocolError) Unwrap() error { return e.Cause }

func invalidResponse(operation Operation, field string, cause error) error {
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

// executeMutation validates after requestBytes finishes authentication recovery.
// Covered operations apply receipt recovery around this single attempt.
func executeMutation(ctx context.Context, conn *Connection, operation Operation, statuses []int, decode func([]byte, int) error) error {
	if conn == nil {
		return errors.New("not connected to Albedo")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	reqCtx := ctx
	if deadline, ok := ctx.Deadline(); !ok || time.Until(deadline) > 20*time.Second {
		var cancel context.CancelFunc
		reqCtx, cancel = context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
	}
	status := 0
	body, err := requestBytes(reqCtx, conn, operation, responseLimits{successStatuses: statuses, status: &status, bodyBytes: 50 * 1024 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return err
	}
	if err = decode(body, status); err != nil {
		field := ""
		if detail, ok := errors.AsType[*responseFieldError](err); ok {
			field = detail.field
		} else if detail, ok := errors.AsType[*json.UnmarshalTypeError](err); ok {
			field = detail.Field
		}
		return invalidResponse(operation, field, err)
	}
	return nil
}

func object(data []byte) (map[string]json.RawMessage, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return nil, err
	}
	if fields == nil {
		return nil, errors.New("expected an object")
	}
	return fields, nil
}
func required(fields map[string]json.RawMessage, key string, target any) error {
	raw, ok := fields[key]
	if !ok || string(raw) == "null" {
		return fieldError(key)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return &responseFieldError{field: key, cause: err}
	}
	return nil
}
func nullable(fields map[string]json.RawMessage, key string, target any) error {
	raw, ok := fields[key]
	if !ok {
		return fieldError(key)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return &responseFieldError{field: key, cause: err}
	}
	return nil
}
func decodeAck(data []byte, _ int) error {
	var wire struct {
		OK *bool `json:"ok"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	if wire.OK == nil || !*wire.OK {
		return fieldError("ok")
	}
	return nil
}
func acknowledge(ctx context.Context, conn *Connection, operation Operation) error {
	return executeMutation(ctx, conn, operation, []int{http.StatusOK}, decodeAck)
}
func sessionPath(id, tail string) string { return "/sessions/" + url.PathEscape(id) + tail }

func decodeSubmission(data []byte, _ int) (SendResult, error) {
	var wire struct {
		OK          *bool  `json:"ok"`
		Queued      *bool  `json:"queued"`
		OperationID string `json:"operationId"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return SendResult{}, err
	}
	if wire.OK == nil || !*wire.OK {
		return SendResult{}, fieldError("ok")
	}
	if wire.Queued == nil {
		return SendResult{}, fieldError("queued")
	}
	if wire.OperationID == "" {
		return SendResult{}, fieldError("operationId")
	}
	return SendResult{OK: *wire.OK, Queued: *wire.Queued, OperationID: wire.OperationID}, nil
}
func Submit(ctx context.Context, conn *Connection, id string, payload map[string]any) (SendResult, error) {
	handle, err := NewSubmission(id, payload)
	if err != nil {
		return SendResult{}, err
	}
	return SubmitOperation(ctx, conn, handle)
}
func SubmitOperation(ctx context.Context, conn *Connection, handle *OperationHandle) (SendResult, error) {
	var result SendResult
	err := executeReceipt(ctx, conn, handle, []int{http.StatusAccepted}, func(body []byte, status int) error {
		var err error
		result, err = decodeSubmission(body, status)
		if err == nil && result.OperationID != handle.ID {
			return fieldError("operationId")
		}
		return err
	})
	return result, err
}
func decodeInterruption(data []byte, _ int) (bool, error) {
	var wire struct {
		Interrupted *bool `json:"interrupted"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return false, err
	}
	if wire.Interrupted == nil {
		return false, fieldError("interrupted")
	}
	return *wire.Interrupted, nil
}
func InterruptSession(ctx context.Context, conn *Connection, id string) (bool, error) {
	var interrupted bool
	err := executeMutation(ctx, conn, Operation{Name: "interrupt session", Method: http.MethodPost, Path: sessionPath(id, "/interrupt"), Body: map[string]any{}, Policy: AuthRecovery}, []int{http.StatusOK}, func(body []byte, status int) error {
		var err error
		interrupted, err = decodeInterruption(body, status)
		return err
	})
	return interrupted, err
}
func decodeSession(data []byte) (Session, error) {
	var wire struct {
		ID              *string         `json:"id"`
		Title           *string         `json:"title"`
		Workspace       *string         `json:"workspace"`
		Model           *string         `json:"model"`
		Protocol        *string         `json:"protocol"`
		Provider        *string         `json:"provider"`
		Effort          json.RawMessage `json:"effort"`
		LastAssistantAt json.RawMessage `json:"last_assistant_at"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return Session{}, err
	}
	for _, field := range []struct {
		value *string
		name  string
	}{{wire.ID, "id"}, {wire.Title, "title"}, {wire.Workspace, "workspace"}, {wire.Model, "model"}, {wire.Protocol, "protocol"}, {wire.Provider, "provider"}} {
		if field.value == nil {
			return Session{}, fieldError(field.name)
		}
	}
	if wire.Effort == nil {
		return Session{}, fieldError("effort")
	}
	if wire.LastAssistantAt == nil {
		return Session{}, fieldError("last_assistant_at")
	}
	var effort *string
	if !bytes.Equal(bytes.TrimSpace(wire.Effort), []byte("null")) {
		if err := json.Unmarshal(wire.Effort, &effort); err != nil {
			return Session{}, &responseFieldError{field: "effort", cause: err}
		}
	}
	session := Session{ID: *wire.ID, Title: *wire.Title, Workspace: *wire.Workspace, Model: *wire.Model, Protocol: *wire.Protocol, Provider: *wire.Provider}
	if effort != nil {
		session.Effort = *effort
	}
	if !bytes.Equal(bytes.TrimSpace(wire.LastAssistantAt), []byte("null")) {
		if err := json.Unmarshal(wire.LastAssistantAt, &session.LastAssistantAt); err != nil {
			return Session{}, &responseFieldError{field: "last_assistant_at", cause: err}
		}
	}
	return session, nil
}
func mutateSession(ctx context.Context, conn *Connection, operation Operation, status int) (Session, error) {
	var session Session
	err := executeMutation(ctx, conn, operation, []int{status}, func(body []byte, _ int) error {
		var err error
		session, err = decodeSession(body)
		return err
	})
	return session, err
}
func CreateSession(ctx context.Context, conn *Connection, body map[string]string) (Session, error) {
	handle, err := NewCreation(body)
	if err != nil {
		return Session{}, err
	}
	return CreateSessionOperation(ctx, conn, handle)
}
func CreateSessionOperation(ctx context.Context, conn *Connection, handle *OperationHandle) (Session, error) {
	var session Session
	err := executeReceipt(ctx, conn, handle, []int{http.StatusCreated}, func(body []byte, _ int) error {
		fields, err := object(body)
		if err != nil {
			return err
		}
		var operationID string
		if err := required(fields, "operationId", &operationID); err != nil {
			return err
		}
		if operationID != handle.ID {
			return fieldError("operationId")
		}
		session, err = decodeSession(body)
		return err
	})
	return session, err
}
func RenameSession(ctx context.Context, conn *Connection, id, name string) (Session, error) {
	return mutateSession(ctx, conn, Operation{Name: "rename session", Method: http.MethodPatch, Path: sessionPath(id, ""), Body: map[string]string{"name": name}, Policy: AuthRecovery}, http.StatusOK)
}
func ForkSession(ctx context.Context, conn *Connection, id string, body map[string]any) (Session, error) {
	return mutateSession(ctx, conn, Operation{Name: "fork session", Method: http.MethodPost, Path: sessionPath(id, "/fork"), Body: body, Policy: AuthRecovery}, http.StatusCreated)
}

type DeletionResult struct {
	OK      bool `json:"ok"`
	Deleted int  `json:"deleted"`
}

func decodeDeletion(data []byte) (DeletionResult, error) {
	var wire struct {
		OK      *bool `json:"ok"`
		Deleted *int  `json:"deleted"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return DeletionResult{}, err
	}
	if wire.OK == nil || !*wire.OK {
		return DeletionResult{}, fieldError("ok")
	}
	if wire.Deleted == nil || *wire.Deleted < 1 {
		return DeletionResult{}, fieldError("deleted")
	}
	return DeletionResult{OK: *wire.OK, Deleted: *wire.Deleted}, nil
}
func DeleteSession(ctx context.Context, conn *Connection, id string, tree bool) (DeletionResult, error) {
	path := sessionPath(id, "")
	if tree {
		path += "?tree=1"
	}
	var result DeletionResult
	err := executeMutation(ctx, conn, Operation{Name: "delete session", Method: http.MethodDelete, Path: path, Policy: AuthRecovery}, []int{200}, func(body []byte, _ int) error {
		var err error
		result, err = decodeDeletion(body)
		return err
	})
	return result, err
}
func StopDaemon(ctx context.Context, conn *Connection) error {
	return acknowledge(ctx, conn, Operation{Name: "stop daemon", Method: http.MethodPost, Path: "/shutdown", Body: map[string]any{}, Policy: NoRecovery})
}

type ModelSelection struct {
	Provider string `json:"provider"`
	Model    string `json:"model"`
	Protocol string `json:"protocol"`
	Effort   string `json:"effort"`
}

func decodeModelSelection(data []byte) (ModelSelection, error) {
	var wire struct {
		Provider *string         `json:"provider"`
		Model    *string         `json:"model"`
		Protocol *string         `json:"protocol"`
		Effort   json.RawMessage `json:"effort"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return ModelSelection{}, err
	}
	if wire.Provider == nil {
		return ModelSelection{}, fieldError("provider")
	}
	if wire.Model == nil {
		return ModelSelection{}, fieldError("model")
	}
	if wire.Protocol == nil {
		return ModelSelection{}, fieldError("protocol")
	}
	if wire.Effort == nil {
		return ModelSelection{}, fieldError("effort")
	}
	var effort *string
	if !bytes.Equal(bytes.TrimSpace(wire.Effort), []byte("null")) {
		if err := json.Unmarshal(wire.Effort, &effort); err != nil {
			return ModelSelection{}, &responseFieldError{field: "effort", cause: err}
		}
	}
	result := ModelSelection{Provider: *wire.Provider, Model: *wire.Model, Protocol: *wire.Protocol}
	if effort != nil {
		result.Effort = *effort
	}
	return result, nil
}
func SelectModel(ctx context.Context, conn *Connection, id string, body map[string]string) (ModelSelection, error) {
	var result ModelSelection
	err := executeMutation(ctx, conn, Operation{Name: "select model", Method: http.MethodPost, Path: sessionPath(id, "/model"), Body: body, Policy: AuthRecovery}, []int{200}, func(body []byte, _ int) error {
		var err error
		result, err = decodeModelSelection(body)
		return err
	})
	return result, err
}

type ExtensionSummary struct {
	Name          string   `json:"name"`
	Description   string   `json:"description"`
	Quarantined   string   `json:"quarantined"`
	Tools         []string `json:"tools"`
	PythonModules []string `json:"python_modules"`
	Requires      []string `json:"requires"`
	Plugins       []string `json:"plugins"`
	Enabled       bool     `json:"enabled"`
	Context       bool     `json:"context"`
	Overridden    bool     `json:"overridden"`
	GlobalEnabled bool     `json:"global_enabled"`
}

func decodeExtensions(data []byte) ([]ExtensionSummary, error) {
	type extensionWire struct {
		Name          *string          `json:"name"`
		Description   *string          `json:"description"`
		Enabled       *bool            `json:"enabled"`
		Context       *bool            `json:"context"`
		Overridden    *bool            `json:"overridden"`
		GlobalEnabled *bool            `json:"global_enabled"`
		Tools         stringCollection `json:"tools"`
		PythonModules stringCollection `json:"python_modules"`
		Requires      stringCollection `json:"requires"`
		Plugins       stringCollection `json:"plugins"`
		Quarantined   json.RawMessage  `json:"quarantined"`
	}
	var wire []extensionWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return nil, err
	}
	if wire == nil {
		return nil, errors.New("expected an array")
	}
	summaries := make([]ExtensionSummary, 0, len(wire))
	for i, item := range wire {
		missing := ""
		switch {
		case item.Name == nil:
			missing = "name"
		case item.Description == nil:
			missing = "description"
		case item.Tools == nil:
			missing = "tools"
		case item.PythonModules == nil:
			missing = "python_modules"
		case item.Requires == nil:
			missing = "requires"
		case item.Plugins == nil:
			missing = "plugins"
		case item.Enabled == nil:
			missing = "enabled"
		case item.Context == nil:
			missing = "context"
		case item.Overridden == nil:
			missing = "overridden"
		case item.GlobalEnabled == nil:
			missing = "global_enabled"
		case item.Quarantined == nil:
			missing = "quarantined"
		}
		if missing != "" {
			return nil, fieldError(fmt.Sprintf("extensions[%d].%s", i, missing))
		}
		var quarantine *string
		if !bytes.Equal(bytes.TrimSpace(item.Quarantined), []byte("null")) {
			if err := json.Unmarshal(item.Quarantined, &quarantine); err != nil {
				return nil, &responseFieldError{field: fmt.Sprintf("extensions[%d].quarantined", i), cause: err}
			}
		}
		summary := ExtensionSummary{Name: *item.Name, Description: *item.Description, Tools: []string(item.Tools), PythonModules: []string(item.PythonModules), Requires: []string(item.Requires), Plugins: []string(item.Plugins), Enabled: *item.Enabled, Context: *item.Context, Overridden: *item.Overridden, GlobalEnabled: *item.GlobalEnabled}
		if quarantine != nil {
			summary.Quarantined = *quarantine
		}
		summaries = append(summaries, summary)
	}
	return summaries, nil
}
func SelectExtension(ctx context.Context, conn *Connection, id string, body map[string]any) ([]ExtensionSummary, error) {
	var result []ExtensionSummary
	err := executeMutation(ctx, conn, Operation{Name: "select extension", Method: http.MethodPost, Path: sessionPath(id, "/extensions"), Body: body, Policy: AuthRecovery}, []int{200}, func(body []byte, _ int) error {
		var err error
		result, err = decodeExtensions(body)
		return err
	})
	return result, err
}

type Member struct {
	Session string `json:"session"`
	Parent  string `json:"parent"`
	Name    string `json:"name"`
	Depth   int    `json:"depth"`
	Closed  bool   `json:"closed"`
}
type ChildResult struct {
	Session Session `json:"session"`
	Member  Member  `json:"member"`
}

func decodeChild(data []byte) (ChildResult, error) {
	fields, err := object(data)
	if err != nil {
		return ChildResult{}, err
	}
	var result ChildResult
	raw, ok := fields["session"]
	if !ok {
		return result, fieldError("session")
	}
	result.Session, err = decodeSession(raw)
	if err != nil {
		return ChildResult{}, err
	}
	member, err := object(fields["member"])
	if err != nil {
		return ChildResult{}, err
	}
	for _, field := range []struct {
		target any
		name   string
	}{{&result.Member.Session, "session"}, {&result.Member.Parent, "parent"}, {&result.Member.Name, "name"}, {&result.Member.Depth, "depth"}, {&result.Member.Closed, "closed"}} {
		if err := required(member, field.name, field.target); err != nil {
			return ChildResult{}, err
		}
	}
	return result, nil
}
func CreateChild(ctx context.Context, conn *Connection, id string, body map[string]any) (ChildResult, error) {
	var result ChildResult
	err := executeMutation(ctx, conn, Operation{Name: "create child", Method: http.MethodPost, Path: sessionPath(id, "/children"), Body: body, Policy: AuthRecovery}, []int{201}, func(body []byte, _ int) error {
		var err error
		result, err = decodeChild(body)
		return err
	})
	return result, err
}

type ReloadResult struct {
	Reloaded string `json:"reloaded"`
	Message  string `json:"message"`
	Warning  string `json:"warning"`
}

func decodeReload(data []byte, _ int) (ReloadResult, error) {
	var wire struct {
		Reloaded *string         `json:"reloaded"`
		Message  json.RawMessage `json:"message"`
		Warning  json.RawMessage `json:"warning"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return ReloadResult{}, err
	}
	if wire.Reloaded == nil || *wire.Reloaded != "session" {
		return ReloadResult{}, fieldError("reloaded")
	}
	result := ReloadResult{Reloaded: *wire.Reloaded}
	if (wire.Message == nil) == (wire.Warning == nil) {
		return ReloadResult{}, fieldError("message")
	}
	raw, target := wire.Message, &result.Message
	field := "message"
	if raw == nil {
		raw, target, field = wire.Warning, &result.Warning, "warning"
	}
	if string(raw) == "null" {
		return ReloadResult{}, fieldError(field)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return ReloadResult{}, &responseFieldError{field: field, cause: err}
	}
	return result, nil
}
func reloadSettings(ctx context.Context, conn *Connection, operation Operation) (ReloadResult, error) {
	var result ReloadResult
	err := executeMutation(ctx, conn, operation, []int{200}, func(data []byte, status int) error {
		var err error
		result, err = decodeReload(data, status)
		return err
	})
	return result, err
}
func decodeUI(data []byte, _ int) (UIPreferences, error) {
	var wire struct {
		Opens    *map[string]*int  `json:"opens"`
		Pinned   *stringCollection `json:"pinned"`
		Archived *stringCollection `json:"archived"`
		Thinking *bool             `json:"thinking"`
		Tools    *bool             `json:"tools"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return UIPreferences{}, err
	}
	if wire.Opens == nil {
		return UIPreferences{}, fieldError("opens")
	}
	if wire.Pinned == nil {
		return UIPreferences{}, fieldError("pinned")
	}
	if wire.Archived == nil {
		return UIPreferences{}, fieldError("archived")
	}
	if wire.Thinking == nil {
		return UIPreferences{}, fieldError("thinking")
	}
	if wire.Tools == nil {
		return UIPreferences{}, fieldError("tools")
	}
	opens := make(map[string]int, len(*wire.Opens))
	for id, count := range *wire.Opens {
		if count == nil {
			return UIPreferences{}, fieldError("opens." + id)
		}
		opens[id] = *count
	}
	return UIPreferences{Opens: opens, Pinned: []string(*wire.Pinned), Archived: []string(*wire.Archived), Thinking: *wire.Thinking, Tools: *wire.Tools}, nil
}
func mutateUI(ctx context.Context, conn *Connection, operation Operation) (UIPreferences, error) {
	var result UIPreferences
	err := executeMutation(ctx, conn, operation, []int{200}, func(data []byte, status int) error {
		var err error
		result, err = decodeUI(data, status)
		return err
	})
	return result, err
}

// stringCollection rejects null entries rather than decoding them as empty strings.
type stringCollection []string

func (values *stringCollection) UnmarshalJSON(data []byte) error {
	if bytes.Equal(bytes.TrimSpace(data), []byte("[]")) {
		*values = stringCollection{}
		return nil
	}
	var wire []*string
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	if wire == nil {
		return errors.New("expected a string array")
	}
	result := make(stringCollection, len(wire))
	for i, value := range wire {
		if value == nil {
			return errors.New("string array contains null")
		}
		result[i] = *value
	}
	*values = result
	return nil
}
