// Package app owns daemon-backed workflows without terminal interaction or rendering.
package app

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"albedo/cli/internal/daemon"
)

// Service obtains connections only when an operation needs one.
type Service struct {
	Connect  func(context.Context) (*daemon.Connection, error)
	Existing func(context.Context) (*daemon.Connection, error)
}
type OpenOptions struct {
	SessionID, Workspace string
	Fresh, Terminal      bool
}
type PreparedOpen struct {
	Connection    *daemon.Connection
	Settings      daemon.Settings
	Selected      *daemon.Session
	Workspace     string
	Sessions      []daemon.Session
	LoginRequired bool
}

// absoluteWorkspace resolves a local workspace against the current
// directory; a location on another host is the daemon's to read.
func absoluteWorkspace(workspace string) string {
	if host, _ := daemon.SplitLocation(workspace); host != "" {
		return workspace
	}
	if abs, err := filepath.Abs(workspace); err == nil {
		return abs
	}
	return workspace
}

func (s *Service) PrepareOpen(ctx context.Context, options OpenOptions) (PreparedOpen, error) {
	id, workspace, fresh := options.SessionID, options.Workspace, options.Fresh
	absWorkspace := absoluteWorkspace(workspace)

	conn, err := s.Connect(ctx)
	if err != nil {
		return PreparedOpen{}, err
	}

	sessions, err := daemon.ListSessions(ctx, conn)
	if err != nil {
		return PreparedOpen{}, err
	}

	selectedID := ""
	if id != "" {
		resolved, matchErr := resolveSessionID(id, sessions)
		if matchErr != nil {
			return PreparedOpen{}, matchErr
		}
		selectedID = resolved
	}

	settings, err := daemon.GetSettings(ctx, conn)
	if err != nil {
		return PreparedOpen{}, err
	}
	configured := settings.Profiles.Active != ""

	if !configured && !options.Terminal {
		return PreparedOpen{}, errors.New("no model provider is configured; run albedo login in a terminal to set one up")
	}

	var initial *daemon.Session
	if selectedID != "" {
		captured, err := daemon.GetSession(ctx, conn, selectedID)
		if err != nil {
			return PreparedOpen{}, sessionLookupError(id, err)
		}
		initial = &captured
	} else if configured && (fresh || len(sessions) == 0) {
		created, createErr := daemon.CreateSession(ctx, conn, daemon.CreateSessionRequest{Workspace: absWorkspace})
		if createErr != nil {
			return PreparedOpen{}, createErr
		}
		initial = &created
	}

	if initial != nil {
		if i := slices.IndexFunc(sessions, func(s daemon.Session) bool { return s.ID == initial.ID }); i >= 0 {
			sessions[i] = *initial
		} else {
			sessions = append([]daemon.Session{*initial}, sessions...)
		}
	}
	return PreparedOpen{Connection: conn, Settings: settings, Sessions: sessions, Selected: initial, Workspace: absWorkspace, LoginRequired: !configured}, nil
}

func (s *Service) Sessions(ctx context.Context) ([]daemon.Session, error) {
	conn, err := s.Connect(ctx)
	if err != nil {
		return nil, err
	}
	sessions, err := daemon.ListSessions(ctx, conn)
	if err != nil {
		return nil, err
	}
	return slices.DeleteFunc(sessions, func(session daemon.Session) bool { return session.Archived }), nil
}

// resolveSessionID addresses full IDs directly and expands prefixes against roots.
func resolveSessionID(id string, sessions []daemon.Session) (string, error) {
	if fullSessionID.MatchString(id) {
		return id, nil
	}
	selectedIndex, matchCount := -1, 0
	for i := range sessions {
		if sessions[i].ID == id {
			return sessions[i].ID, nil
		}
		if strings.HasPrefix(sessions[i].ID, id) {
			selectedIndex = i
			matchCount++
		}
	}
	switch matchCount {
	case 0:
		return "", noSessionMatch(id)
	case 1:
		return sessions[selectedIndex].ID, nil
	default:
		return "", fmt.Errorf("more than one session ID starts with %q; use a longer ID or run albedo sessions to find it", id)
	}
}

// The UUIDv7 shape in the daemon's operation validator and OpenAPI schema.
var fullSessionID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func noSessionMatch(id string) error {
	return fmt.Errorf("no session matches %q; run albedo sessions to see the available sessions", id)
}

func sessionLookupError(id string, err error) error {
	if problem, ok := errors.AsType[*daemon.APIError](err); ok && problem.StatusCode == http.StatusNotFound && fullSessionID.MatchString(id) {
		return noSessionMatch(id)
	}
	return err
}

// resolveSession validates full IDs directly and lists roots only for prefixes.
func resolveSession(ctx context.Context, conn *daemon.Connection, id string) (string, error) {
	var sessions []daemon.Session
	if !fullSessionID.MatchString(id) {
		var err error
		sessions, err = daemon.ListSessions(ctx, conn)
		if err != nil {
			return "", err
		}
	}
	resolved, err := resolveSessionID(id, sessions)
	if err != nil {
		return "", err
	}
	if fullSessionID.MatchString(id) {
		configuration, err := daemon.GetSessionConfiguration(ctx, conn, resolved)
		return configuration.Value.ID, sessionLookupError(id, err)
	}
	return resolved, nil
}

func (s *Service) Send(ctx context.Context, id, prompt string) (daemon.SendResult, error) {
	conn, err := s.Connect(ctx)
	if err != nil {
		return daemon.SendResult{}, err
	}
	id, err = resolveSession(ctx, conn, id)
	if err != nil {
		return daemon.SendResult{}, err
	}
	return daemon.Submit(ctx, conn, id, daemon.SubmissionRequest{Content: &prompt})
}

type InterruptionResult struct {
	Interrupted bool `json:"interrupted"`
}

func (s *Service) Stop(ctx context.Context, id string) (InterruptionResult, error) {
	conn, err := s.Connect(ctx)
	if err != nil {
		return InterruptionResult{}, err
	}
	id, err = resolveSession(ctx, conn, id)
	if err != nil {
		return InterruptionResult{}, err
	}
	interrupted, err := daemon.InterruptSession(ctx, conn, id)
	return InterruptionResult{Interrupted: interrupted}, err
}
func (s *Service) DeleteSessions(ctx context.Context, ids []string) error {
	conn, err := s.Connect(ctx)
	if err != nil {
		return err
	}
	for _, id := range ids {
		configuration, err := daemon.GetSessionConfiguration(ctx, conn, id)
		if err != nil {
			return err
		}
		result, err := daemon.DeleteSession(ctx, conn, id, false, daemon.SessionCondition{ETag: configuration.ETag})
		if err != nil {
			return err
		}
		if !result.OK {
			return errors.New(result.Message)
		}
	}
	return nil
}
func (s *Service) StopDaemon(ctx context.Context) error {
	conn, err := s.Existing(ctx)
	if err != nil || conn == nil {
		return err
	}
	return daemon.StopDaemon(ctx, conn)
}
func (s *Service) PrepareLogin(ctx context.Context) (PreparedOpen, error) {
	conn, err := s.Connect(ctx)
	if err != nil {
		return PreparedOpen{}, err
	}
	settings, err := daemon.GetSettings(ctx, conn)
	return PreparedOpen{Connection: conn, Settings: settings}, err
}
