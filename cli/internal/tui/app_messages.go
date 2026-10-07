package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
)

type sessionsLoadedMsg struct {
	Err      error
	Sessions []daemon.Session
	Gen      int
	Notice   string
}

type sessionDeletedMsg struct {
	Err    error
	ID     string
	Result *daemon.DeletionResult
}

type sessionCreationRecoveryMsg struct {
	Handle *daemon.OperationHandle
	Gen    int
}

type sessionCreatedMsg struct {
	Handle  *daemon.OperationHandle
	Err     error
	Session daemon.Session
	Gen     int
}

type commandCatalogLoadedMsg struct {
	Err      error
	Commands []daemon.SessionCommand
	Gen      int
}

type modelChangedMsg struct {
	Selection *daemon.ModelSelection
	Err       error
	SessionID string
	Gen       int
}

type commandExecutedMsg struct {
	Page             *daemon.PageDocument
	ETag, ModelsETag string
	Err              error
	Name             string
	Message          string
	Effort           string
	SessionID        string
	Available        []string
	Gen              int
	EffortChanged    bool
}

type profilesLoadedMsg struct {
	Profiles config.Profiles
	Err      error
	Provider string
	Gen      int
}

type settingsLoadedMsg struct {
	Err      error
	Settings daemon.Settings
	Gen      int
}

type uiSavedMsg struct {
	Err     error
	Prefs   daemon.UIPreferences
	Gen     int
	Session string // the pinned or archived session; empty for shared preferences
	Open    bool
}
