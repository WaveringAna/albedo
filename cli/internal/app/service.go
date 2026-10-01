// Package app owns daemon-backed workflows without terminal interaction or rendering.
package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"slices"
	"strings"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
)

// Service obtains connections only when an operation needs one.
type Service struct {
	Connect  func(context.Context) (*daemon.Connection, error)
	Existing func() (*daemon.Connection, error)
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

func (s *Service) PrepareOpen(ctx context.Context, options OpenOptions) (PreparedOpen, error) {
	id, workspace, fresh := options.SessionID, options.Workspace, options.Fresh
	absWorkspace, err := filepath.Abs(workspace)
	if err != nil {
		absWorkspace = workspace
	}

	conn, err := s.Connect(ctx)
	if err != nil {
		return PreparedOpen{}, err
	}

	sessions, err := daemon.Request[[]daemon.Session](ctx, conn, "/sessions", nil)
	if err != nil {
		return PreparedOpen{}, err
	}

	var selected *daemon.Session
	if id != "" {
		selectedIndex, matchCount := -1, 0
		for i := range sessions {
			if sessions[i].ID == id {
				selectedIndex, matchCount = i, 1
				break
			}
			if strings.HasPrefix(sessions[i].ID, id) {
				selectedIndex = i
				matchCount++
			}
		}
		switch matchCount {
		case 0:
			return PreparedOpen{}, fmt.Errorf("no session matches %q; run albedo sessions to see the available sessions", id)
		case 1:
			session := sessions[selectedIndex]
			selected = &session
		default:
			return PreparedOpen{}, fmt.Errorf("more than one session ID starts with %q; use a longer ID or run albedo sessions to find it", id)
		}
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
		created, createErr := daemon.Request[daemon.Session](ctx, conn, "/sessions", map[string]string{"workspace": absWorkspace})
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
	sessions, err := daemon.Request[[]daemon.Session](ctx, conn, "/sessions", nil)
	if err != nil {
		return SessionList{}, err
	}
	settings, warning := daemon.GetSettings(ctx, conn)
	if warning == nil {
		sessions = slices.DeleteFunc(sessions, func(session daemon.Session) bool { return slices.Contains(settings.UI.Archived, session.ID) })
	}
	return SessionList{Sessions: sessions, ArchiveWarning: warning}, nil
}
func (s *Service) Send(ctx context.Context, id, prompt string) (json.RawMessage, error) {
	conn, err := s.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return daemon.Request[json.RawMessage](ctx, conn, "/sessions/"+url.PathEscape(id)+"/events", map[string]string{"content": prompt})
}
func (s *Service) Stop(ctx context.Context, id string) (json.RawMessage, error) {
	conn, err := s.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return daemon.Request[json.RawMessage](ctx, conn, "/sessions/"+url.PathEscape(id)+"/interrupt", map[string]any{})
}
func (s *Service) DeleteSessions(ctx context.Context, ids []string) error {
	conn, err := s.Connect(ctx)
	if err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := daemon.RequestMethod[json.RawMessage](ctx, conn, "DELETE", "/sessions/"+url.PathEscape(id), nil); err != nil {
			return err
		}
	}
	return nil
}
func (s *Service) StartDaemon(ctx context.Context) (*daemon.Connection, error) { return s.Connect(ctx) }
func (s *Service) StopDaemon(ctx context.Context) error {
	conn, err := s.Existing()
	if err != nil || conn == nil {
		return err
	}
	_, err = daemon.Request[json.RawMessage](ctx, conn, "/shutdown", map[string]any{})
	return err
}
func (s *Service) PrepareLogin(ctx context.Context) (PreparedOpen, error) {
	conn, err := s.Connect(ctx)
	if err != nil {
		return PreparedOpen{}, err
	}
	profiles, err := daemon.ProviderProfiles(ctx, conn)
	return PreparedOpen{Connection: conn, Providers: profiles}, err
}
