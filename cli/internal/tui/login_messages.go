package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
)

type LoginDoneMsg struct {
	Gen      int
	Name     string
	Settings config.Settings
}

type LoginCancelMsg struct{}

type loginModelsLoadedMsg struct {
	Err    error
	Note   string
	Models []string
	Gen    int
}

// signInsLoadedMsg carries the daemon's sign-ins and accounts, after the first
// read and after every change. Profiles comes from the same settings snapshot.
type signInsLoadedMsg struct {
	Mutation bool
	Err      error
	Profiles *config.Profiles
	Listed   daemon.SignIns
	Gen      int
}

type signInStartedMsg struct {
	ETag string
	Err  error
	ID   string
	URL  string
	Gen  int
}

type signInStatusMsg struct {
	ETag, Instructions string
	Accounts           []daemon.Account
	URL                string
	Err                error
	ID                 string
	State              string
	Message            string
	Gen                int
}

type signInPollMsg struct {
	ID  string
	Gen int
}

type providerSavedMsg struct {
	Gen      int
	Err      error
	Name     string
	Settings config.Settings
}
