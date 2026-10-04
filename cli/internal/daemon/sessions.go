package daemon

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"

	"albedo/cli/internal/daemon/protocol"
)

type DeletionResult struct {
	OK         bool
	Deleted    int
	Remaining  int
	State      string
	DeletedIDs []string
	Truncated  bool
	Message    string
}
type PreviewItem struct {
	Type    string
	Preview string
}
type SessionPreview struct {
	Items   []PreviewItem
	Total   int
	Session *Session
}
type CreateSessionRequest struct{ Kind, Workspace, Provider, Model, Effort, Name, SourceSessionID, CheckpointID, ParentID, Address, Task string }
type ForkRequest struct{ Checkpoint string }
type Session struct {
	ID               string    `json:"id"`
	Title            string    `json:"name"`
	LastAssistantAt  *int64    `json:"activity_at"` // Unix seconds, when observed.
	Workspace        string    `json:"workspace"`
	Location         *Location `json:"-"`
	Cursor           *Cursor   `json:"-"`
	Model            string    `json:"model"`
	Effort           string    `json:"effort"`
	Protocol         string    `json:"-"`
	Provider         string    `json:"provider_profile"`
	ETag             string    `json:"-"`
	FamilyRevision   string    `json:"family_revision"`
	ParentID         *string   `json:"parent_id"`
	RootID           string    `json:"root_id"`
	Depth            int       `json:"depth"`
	Closed           bool      `json:"closed"`
	Pinned, Archived bool
	Opens            int
	Status           AgentStatus
	Glances          []PageGlance `json:"-"`
	wire             protocol.Session
}
type Location struct {
	Host  *string `json:"host"`
	User  *string `json:"user"`
	Path  string  `json:"path"`
	Label *string `json:"label"`
}

func SplitLocation(workspace string) (host, path string) {
	if workspace == "" || workspace[0] == '/' || workspace[0] == '~' {
		return "", workspace
	}
	i := strings.Index(workspace, ":/")
	if i <= 0 || strings.Contains(workspace[:i], "/") {
		return "", workspace
	}
	return workspace[:i], workspace[i+1:]
}

func sessionValue(wire protocol.Session) Session {
	location := &Location{Host: wire.Location.Host, User: wire.Location.User, Path: wire.Location.Path, Label: wire.Location.Label}
	session := Session{ID: wire.ID, Title: wire.Name, Cursor: wire.Cursor, LastAssistantAt: timestampSeconds(value(wire.ActivityAt)), Workspace: wire.Workspace, Location: location, Model: value(wire.Model), Effort: value(wire.Effort), Provider: value(wire.ProviderProfile), ETag: wire.ConfigurationResource.ETag, FamilyRevision: wire.FamilyRevision, ParentID: wire.ParentID, RootID: wire.RootID, Depth: int(wire.Depth), Closed: wire.Closed, Pinned: wire.Preferences.Pinned, Archived: wire.Preferences.Archived, Opens: int(wire.Preferences.Opens), Status: capturedStatus(wire), wire: wire}
	for _, glance := range wire.Glances {
		session.Glances = append(session.Glances, *glanceValue(glance))
	}
	slices.SortFunc(session.Glances, func(first, second PageGlance) int { return strings.Compare(first.Title, second.Title) })
	return session
}
func decodeSession(data []byte) (Session, error) {
	var wire protocol.Session
	if err := decodeRequired(data, &wire); err != nil {
		return Session{}, err
	}
	if err := validateSession(wire); err != nil {
		return Session{}, err
	}
	return sessionValue(wire), nil
}
func validateSession(wire protocol.Session) error {
	if wire.ID == "" || wire.RootID == "" || wire.Cursor == nil || !validGeneration(wire.Cursor.Generation) || wire.Cursor.Sequence < 0 || wire.ConfigurationResource.ETag == "" || wire.History.Items == nil {
		return fieldError("session")
	}
	return validateSessionStatus(wire.Status)
}
func CreateSession(ctx context.Context, conn *Connection, request CreateSessionRequest) (Session, error) {
	handle, err := NewCreation(request)
	if err != nil {
		return Session{}, err
	}
	return CreateSessionOperation(ctx, conn, handle)
}
func CreateSessionOperation(ctx context.Context, conn *Connection, handle *OperationHandle) (Session, error) {
	return executeReceipt(ctx, conn, handle, []int{201}, func(body []byte, _ int) (Session, error) {
		result, err := decodeSession(body)
		if err == nil && result.ID != handle.ID() {
			return result, fieldError("session ID")
		}
		return result, err
	}, func(ctx context.Context) (Session, bool, error) {
		result, err := ResolveCreation(ctx, conn, handle)
		return result, err == nil, err
	})
}
func GetSession(ctx context.Context, conn *Connection, id string) (Session, error) {
	var result Session
	err := executeRead(ctx, conn, operation{Name: "read session", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetSessionRequest(base, id, &protocol.GetSessionParams{Tail: new(int64(0))})
	}, Policy: readRecovery}, func(data []byte) error {
		var err error
		result, err = decodeSession(data)
		if err == nil && result.ID != id {
			return fieldError("session ID")
		}
		return err
	})
	return result, err
}

type SessionCondition struct{ ETag, FamilyRevision string }
type SessionConfiguration struct {
	Value protocol.SessionConfiguration
	ETag  string
}

func GetSessionConfiguration(ctx context.Context, conn *Connection, id string) (SessionConfiguration, error) {
	var result SessionConfiguration
	err := executeRead(ctx, conn, operation{Name: "read session configuration", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetSessionRequest(base, id, &protocol.GetSessionParams{View: new("configuration")})
	}, Validator: &result.ETag, Policy: readRecovery}, func(data []byte) error {
		if err := decodeRequired(data, &result.Value); err != nil {
			return err
		}
		if result.ETag == "" || result.Value.ID != id {
			return fieldError("configuration validator")
		}
		return nil
	})
	return result, err
}
func patchSession(ctx context.Context, conn *Connection, id, etag string, body any) (Session, error) {
	headers, err := observedHeaders(etag)
	if err != nil {
		return Session{}, err
	}
	var result Session
	err = executeMutation(ctx, conn, operation{Name: "edit session configuration", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewPatchSessionRequestWithBody(base, id, &protocol.PatchSessionParams{View: "configuration", IfMatch: headers.Get("If-Match")}, "application/merge-patch+json", body)
	}, Headers: headers, Body: body, Policy: authRecovery}, []int{200}, func(data []byte, _ int) error {
		var change protocol.SessionChange
		if err := decodeRequired(data, &change); err != nil {
			return err
		}
		if change.Resource.ETag == "" || change.Session.ID != id || change.Resource.Value.ID != id || change.Resource.ETag != change.Session.ConfigurationResource.ETag {
			return fieldError("session change")
		}
		if err := validateSession(change.Session); err != nil {
			return err
		}
		result = sessionValue(change.Session)
		return nil
	})
	return result, err
}
func RenameSession(ctx context.Context, conn *Connection, id, name, etag string) (Session, error) {
	return patchSession(ctx, conn, id, etag, struct {
		Name string `json:"name"`
	}{name})
}
func ForkSession(ctx context.Context, conn *Connection, id string, body ForkRequest) (Session, error) {
	return CreateSession(ctx, conn, CreateSessionRequest{Kind: "fork", SourceSessionID: id, CheckpointID: body.Checkpoint})
}
func DeleteSession(ctx context.Context, conn *Connection, id string, tree bool, condition SessionCondition) (DeletionResult, error) {
	headers, err := observedHeaders(condition.ETag)
	if err != nil {
		return DeletionResult{}, err
	}
	params := protocol.DeleteSessionParams{View: "configuration", Scope: new("leaf"), IfMatch: condition.ETag}
	if tree {
		if condition.FamilyRevision == "" {
			return DeletionResult{}, errors.New("subtree deletion requires the observed family revision")
		}
		params.Scope = new("subtree")
		params.FamilyRevision = &condition.FamilyRevision
	}
	var result DeletionResult
	err = executeMutation(ctx, conn, operation{Name: "delete session", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewDeleteSessionRequest(base, id, &params)
	}, Headers: headers, Policy: authRecovery}, []int{200}, func(data []byte, _ int) error {
		var wire protocol.SessionDeletion
		if err := decodeRequired(data, &wire); err != nil {
			return err
		}
		if wire.DeletedCount < 0 || wire.RemainingCount < 0 || wire.State != "complete" && wire.State != "partial" || wire.State == "complete" && wire.RemainingCount != 0 {
			return fieldError("deletion counts")
		}
		result = DeletionResult{OK: wire.State == "complete", Deleted: int(wire.DeletedCount), Remaining: int(wire.RemainingCount), State: wire.State, DeletedIDs: wire.DeletedIDs, Truncated: wire.Truncated, Message: fmt.Sprintf("Deleted %d sessions; %d remain.", wire.DeletedCount, wire.RemainingCount)}
		for _, remaining := range wire.Remaining {
			result.Message += " " + remaining.ID + ": " + remaining.Reason.Detail
		}
		if wire.Truncated {
			result.Message += " Individual results are truncated; refresh the session list."
		}
		return nil
	})
	return result, err
}
func ListSessions(ctx context.Context, conn *Connection) ([]Session, error) {
	return listSessions(ctx, conn, protocol.ListSessionsParams{Scope: new("roots")})
}
func listSessions(ctx context.Context, conn *Connection, query protocol.ListSessionsParams) ([]Session, error) {
	result := []Session{}
	query.Limit = new(int64(200))
	seen := map[string]bool{}
	for {
		var page protocol.SessionPage
		err := executeRead(ctx, conn, operation{Name: "list sessions", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
			return protocol.NewListSessionsRequest(base, &query)
		}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &page) })
		if err != nil {
			return nil, err
		}
		if page.Items == nil {
			return nil, fieldError("items")
		}
		for _, row := range page.Items {
			if row.ID == "" || row.RootID == "" || row.Cursor != nil && (!validGeneration(row.Cursor.Generation) || row.Cursor.Sequence < 0) {
				return nil, fieldError("session ID")
			}
			// Summaries intentionally contain no configuration validator.
			result = append(result, summaryValue(row))
		}
		if page.Next == nil {
			break
		}
		if seen[*page.Next] {
			return nil, fieldError("repeated session page")
		}
		seen[*page.Next] = true
		query.Next = page.Next
	}
	return result, nil
}
func GetSessionPreview(ctx context.Context, conn *Connection, id string, limit int) (SessionPreview, error) {
	var wire protocol.Session
	err := executeRead(ctx, conn, operation{Name: "read session preview", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetSessionRequest(base, id, &protocol.GetSessionParams{Tail: new(int64(min(200, max(0, limit))))})
	}, Policy: readRecovery}, func(data []byte) error { session, err := decodeSession(data); wire = session.wire; return err })
	if err != nil {
		return SessionPreview{}, err
	}
	session := sessionValue(wire)
	result := SessionPreview{Total: int(wire.Preview.TranscriptCount), Items: []PreviewItem{}, Session: &session}
	events, err := historyEvents(wire.History.Items)
	if err != nil {
		return SessionPreview{}, err
	}
	for _, event := range events {
		if event.Type == EventCommitted {
			continue
		}
		text := event.Text
		if event.Type == EventTool {
			text = event.ToolName + ": " + event.ToolResult
		}
		result.Items = append(result.Items, PreviewItem{Type: string(event.Type), Preview: text})
	}
	return result, nil
}

func summaryValue(row protocol.SessionSummary) Session {
	return sessionValue(protocol.Session{ID: row.ID, Name: row.Name, AutomaticName: row.AutomaticName, Workspace: row.Workspace, Location: row.Location, ParentID: row.ParentID, RootID: row.RootID, Address: row.Address, Depth: row.Depth, Closed: row.Closed, CreatedAt: row.CreatedAt, ActivityAt: row.ActivityAt, ProviderProfile: row.ProviderProfile, Model: row.Model, Effort: row.Effort, Status: row.Status, Preview: row.Preview, Preferences: row.Preferences, CurrentProgress: row.CurrentProgress, Activity: row.Activity, Cursor: row.Cursor})
}
func ListAllSessions(ctx context.Context, conn *Connection) ([]Session, error) {
	return listSessions(ctx, conn, protocol.ListSessionsParams{Scope: new("all")})
}

func capturedStatus(w protocol.Session) AgentStatus {
	status := statusValue(w.Status, w.Kernel)
	status.InputOrder = w.InputOrder
	return status
}
