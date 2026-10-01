// Package app owns daemon-backed workflows without terminal interaction or rendering.
package app

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"strings"

	"albedo/cli/internal/config"
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
	Providers     config.Profiles
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

	profs, err := daemon.ProviderProfiles(ctx, conn)
	if err != nil {
		return PreparedOpen{}, err
	}
	configured := profs.Active != ""

	if !configured && !options.Terminal {
		return PreparedOpen{}, errors.New("no model provider is configured; run albedo login in a terminal to set one up")
	}

	var initial *daemon.Session
	if selected != nil {
		initial = selected
	} else if configured && (fresh || len(sessions) == 0) {
		created, createErr := daemon.CreateSession(ctx, conn, daemon.CreateSessionRequest{Workspace: absWorkspace})
		if createErr != nil {
			return PreparedOpen{}, createErr
		}
		initial = &created
	}

	return PreparedOpen{Connection: conn, Providers: profs, Sessions: sessions, Selected: initial, Workspace: absWorkspace, LoginRequired: !configured}, nil
}

type SessionList struct {
	ArchiveWarning error
	Sessions       []daemon.Session
}

func (s *Service) Sessions(ctx context.Context) (SessionList, error) {
	conn, err := s.Connect(ctx)
	if err != nil {
		return SessionList{}, err
	}
	sessions, err := daemon.ListSessions(ctx, conn)
	if err != nil {
		return SessionList{}, err
	}
	settings, warning := daemon.GetSettings(ctx, conn)
	if warning == nil {
		sessions = slices.DeleteFunc(sessions, func(session daemon.Session) bool { return slices.Contains(settings.UI.Archived, session.ID) })
	}
	return SessionList{Sessions: sessions, ArchiveWarning: warning}, nil
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

// resolveSession expands a shortened session ID against the daemon's sessions.
func resolveSession(ctx context.Context, conn *daemon.Connection, id string) (string, error) {
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
		if _, err := daemon.DeleteSession(ctx, conn, id, false); err != nil {
			return err
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
	profiles, err := daemon.ProviderProfiles(ctx, conn)
	return PreparedOpen{Connection: conn, Providers: profiles}, err
}
