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

	var selected *daemon.Session
	if id != "" {
		session, matchErr := matchSession(sessions, id)
		if matchErr != nil {
			return PreparedOpen{}, matchErr
		}
		selected = &session
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
	if selected != nil {
		captured, err := daemon.GetSession(ctx, conn, selected.ID)
		if err != nil {
			return PreparedOpen{}, err
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

// matchSession finds the session whose ID is id or, failing that, the only one
// that starts with it, since `albedo sessions` prints shortened IDs.
func matchSession(sessions []daemon.Session, id string) (daemon.Session, error) {
	selectedIndex, matchCount := -1, 0
	for i := range sessions {
		if sessions[i].ID == id {
			return sessions[i], nil
		}
		if strings.HasPrefix(sessions[i].ID, id) {
			selectedIndex = i
			matchCount++
		}
	}
	switch matchCount {
	case 0:
		return daemon.Session{}, fmt.Errorf("no session matches %q; run albedo sessions to see the available sessions", id)
	case 1:
		return sessions[selectedIndex], nil
	default:
		return daemon.Session{}, fmt.Errorf("more than one session ID starts with %q; use a longer ID or run albedo sessions to find it", id)
	}
}

// The UUIDv7 shape in the daemon's operation validator and OpenAPI schema.
var fullSessionID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

// resolveSession reads full IDs directly and expands prefixes against root sessions.
func resolveSession(ctx context.Context, conn *daemon.Connection, id string) (string, error) {
	if fullSessionID.MatchString(id) {
		configuration, err := daemon.GetSessionConfiguration(ctx, conn, id)
		if problem, ok := errors.AsType[*daemon.APIError](err); ok && problem.StatusCode == http.StatusNotFound {
			return "", fmt.Errorf("no session matches %q; run albedo sessions to see the available sessions", id)
		}
		return configuration.Value.ID, err
	}
	sessions, err := daemon.ListSessions(ctx, conn)
	if err != nil {
		return "", err
	}
	session, err := matchSession(sessions, id)
	return session.ID, err
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
