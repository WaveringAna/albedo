package tui

import (
	"cmp"
	"path"
	"strings"

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

// placeText is a workspace as one line of text: a local path under your
// home starts with ~, and a remote one leads with its host (label, else as
// stored), relative to that host's home as scp reads it. home is the path ~
// names where the workspace is; empty, a local path folds under your own
// home and a remote one stays whole.
func placeText(workspace, label, home string) string {
	host, p := daemon.SplitLocation(workspace)
	switch {
	case host != "":
		return cmp.Or(label, host) + ":" + scpRelative(underHome(p, home))
	case home == "":
		return homePath(workspace)
	}
	return underHome(workspace, home)
}

// sessionPlace is where a session works, as placeText shows it.
func sessionPlace(s daemon.Session) string {
	return placeText(s.Workspace, sessionHost(s), "")
}

// splitHost reads typed text as a location still being written: the host
// before the first colon and whatever follows it, which may be empty, ~ or
// relative to the remote home as well as absolute. Like the daemon's rule,
// text starting with / or ~, or with a slash before the colon, is local.
func splitHost(text string) (host, rest string, ok bool) {
	if text == "" || text[0] == '/' || text[0] == '~' {
		return "", text, false
	}
	if i := strings.Index(text, "]:"); text[0] == '[' && i > 0 {
		return text[:i+1], text[i+2:], true
	}
	host, rest, ok = strings.Cut(text, ":")
	if !ok || host == "" || strings.Contains(host, "/") {
		return "", text, false
	}
	return host, rest, true
}

// joinPlace is the folder name inside the location dir.
func joinPlace(dir, name string) string {
	host, p := daemon.SplitLocation(dir)
	if host == "" {
		return path.Join(dir, name)
	}
	return host + ":" + path.Join(p, name)
}

// parentPlace is the folder above the location dir, on the same host.
func parentPlace(dir string) string {
	return joinPlace(dir, "..")
}
