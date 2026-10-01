package tui

import (
	"cmp"

	"albedo/cli/internal/daemon"
)

// sessionHost is how a session's host reads: the daemon's label, which
// leaves out a user ssh would pick anyway, else the host as stored. Local
// sessions have none.
func sessionHost(s daemon.Session) string {
	if s.Location != nil && s.Location.Label != nil {
		return *s.Location.Label
	}
	host, _ := daemon.SplitLocation(s.Workspace)
	return host
}

// placeText is a workspace as one line of text: a local path under home
// starts with ~, a remote one leads with its host (label, else as stored).
func placeText(workspace, label string) string {
	host, p := daemon.SplitLocation(workspace)
	if host == "" {
		return homePath(workspace)
	}
	return cmp.Or(label, host) + ":" + p
}

// sessionPlace is where a session works, as placeText shows it.
func sessionPlace(s daemon.Session) string {
	return placeText(s.Workspace, sessionHost(s))
}
