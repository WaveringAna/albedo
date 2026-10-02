package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
)

type DeletionResult struct {
	OK      bool `json:"ok"`
	Deleted int  `json:"deleted"`
}

type PreviewItem struct {
	Type    string `json:"type"`
	Preview string `json:"preview"`
}

type SessionPreview struct {
	Items []PreviewItem `json:"items"`
	Total int           `json:"total"`
}

type CreateSessionRequest struct {
	Workspace string `json:"workspace"`
	Provider  string `json:"provider,omitempty"`
	Model     string `json:"model,omitempty"`
}

type ForkRequest struct {
	Checkpoint int `json:"checkpoint"`
}

type Session struct {
	ID              string `json:"id"`
	Title           string `json:"title,omitempty"`
	LastAssistantAt *int64 `json:"last_assistant_at,omitempty"`
	Workspace       string `json:"workspace"`
	Model           string `json:"model"`
	Effort          string `json:"effort,omitempty"`
	Protocol        string `json:"protocol"`
	Provider        string `json:"provider"`
}

func CreateSession(ctx context.Context, conn *Connection, body CreateSessionRequest) (Session, error) {
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
		if operationID != handle.ID() {
			return fieldError("operationId")
		}
		session, err = decodeSession(body)
		return err
	})
	return session, err
}

func RenameSession(ctx context.Context, conn *Connection, id, name string) (Session, error) {
	return mutateSession(ctx, conn, operation{Name: "rename session", Method: http.MethodPatch, Path: sessionPath(id, ""), Body: map[string]string{"name": name}, Policy: authRecovery}, http.StatusOK)
}

func ForkSession(ctx context.Context, conn *Connection, id string, body ForkRequest) (Session, error) {
	return mutateSession(ctx, conn, operation{Name: "fork session", Method: http.MethodPost, Path: sessionPath(id, "/fork"), Body: body, Policy: authRecovery}, http.StatusCreated)
}

func DeleteSession(ctx context.Context, conn *Connection, id string, tree bool) (DeletionResult, error) {
	path := sessionPath(id, "")
	if tree {
		path += "?tree=1"
	}
	var result DeletionResult
	err := executeMutation(ctx, conn, operation{Name: "delete session", Method: http.MethodDelete, Path: path, Policy: authRecovery}, []int{200}, func(body []byte, _ int) error {
		var err error
		result, err = decodeDeletion(body)
		return err
	})
	return result, err
}

func ListSessions(ctx context.Context, conn *Connection) ([]Session, error) {
	var result []Session
	err := executeRead(ctx, conn, operation{Name: "list sessions", Method: http.MethodGet, Path: "/sessions", Policy: readRecovery}, func(data []byte) error {
		var rows []json.RawMessage
		if err := json.Unmarshal(data, &rows); err != nil {
			return err
		}
		if rows == nil {
			return errors.New("expected a session array")
		}
		result = make([]Session, 0, len(rows))
		for _, row := range rows {
			session, err := decodeSession(row)
			if err != nil {
				return err
			}
			result = append(result, session)
		}
		return nil
	})
	return result, err
}

func GetSessionPreview(ctx context.Context, conn *Connection, session string, limit int) (SessionPreview, error) {
	var result SessionPreview
	err := executeRead(ctx, conn, operation{Name: "get session preview", Method: http.MethodGet, Path: sessionPath(session, fmt.Sprintf("/preview?limit=%d", limit)), Policy: readRecovery}, func(data []byte) error {
		fields, err := object(data)
		if err != nil {
			return err
		}
		var rows []json.RawMessage
		if err = required(fields, "items", &rows); err != nil {
			return err
		}
		if err = required(fields, "total", &result.Total); err != nil {
			return err
		}
		if result.Total < 0 {
			return fieldError("total")
		}
		result.Items = make([]PreviewItem, 0, len(rows))
		for _, row := range rows {
			itemFields, err := object(row)
			if err != nil {
				return err
			}
			var item PreviewItem
			if err = required(itemFields, "type", &item.Type); err != nil {
				return err
			}
			if err = required(itemFields, "preview", &item.Preview); err != nil {
				return err
			}
			result.Items = append(result.Items, item)
		}
		return nil
	})
	return result, err
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

func mutateSession(ctx context.Context, conn *Connection, operation operation, status int) (Session, error) {
	var session Session
	err := executeMutation(ctx, conn, operation, []int{status}, func(body []byte, _ int) error {
		var err error
		session, err = decodeSession(body)
		return err
	})
	return session, err
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
