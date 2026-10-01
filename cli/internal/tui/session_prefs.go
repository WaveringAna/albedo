package tui

import (
	"albedo/cli/internal/daemon"
	"maps"
	"slices"
)

// sessionPrefs is the UI snapshot of daemon-owned shared preferences.
type sessionPrefs daemon.UIPreferences

func (p sessionPrefs) pinned(id string) bool { return slices.Contains(p.Pinned, id) }

// forget drops stale entries from the view after a complete session listing.
func (p *sessionPrefs) forget(known map[string]bool) {
	drop := func(id string) bool { return !known[id] }
	p.Pinned = slices.DeleteFunc(p.Pinned, drop)
	p.Archived = slices.DeleteFunc(p.Archived, drop)
	maps.DeleteFunc(p.Opens, func(id string, _ int) bool { return drop(id) })
}
