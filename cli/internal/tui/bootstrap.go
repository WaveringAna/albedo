package tui

import "albedo/cli/internal/daemon"

// Bootstrap contains completed startup reads, including a known empty list.
// Navigation and invalidations load fresh data after this initial snapshot.
type Bootstrap struct {
	Sessions []daemon.Session
	Settings daemon.Settings
}
