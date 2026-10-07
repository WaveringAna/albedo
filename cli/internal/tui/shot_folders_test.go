// The folder picker in every state a person sees, for the shot gallery. A
// plain test run draws each state and writes nothing.
package tui

import (
	"errors"

	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
)

const shotHere = "/Users/dawn/proj/albedo"

func init() {
	session := daemon.Session{ID: "a", Workspace: shotHere}
	right := tea.KeyPressMsg{Code: tea.KeyRight}
	registerShots("folders",
		shotState{"browse", folderShot(func() FolderPicker { return NewFolderBrowser(remoteFolders("ready", ""), shotHere, "") }, "", nil)},
		shotState{"move-session", folderShot(func() FolderPicker { return NewFolderPicker(remoteFolders("ready", ""), session, nil) }, "", nil)},
		shotState{"retry-missing", folderShot(func() FolderPicker {
			return NewFolderPicker(remoteFolders("ready", ""), session, &WorkspaceRetry{Missing: "/Users/dawn/proj/gone", Prompt: "fix the bug"})
		}, "", nil)},
		shotState{"listing-host", folderShot(func() FolderPicker { return NewFolderBrowser(remoteFolders("ready", ""), shotHere, "") }, "chernobog:", nil)},
		shotState{"hosts", folderShot(func() FolderPicker { return NewFolderBrowser(remoteFolders("ready", ""), shotHere, "") }, "@", nil)},
		shotState{"listing-failed", folderShot(func() FolderPicker { return NewFolderBrowser(remoteFolders("ready", ""), shotHere, "") }, "/nowhere/", nil)},
		shotState{"host-warming", folderShot(func() FolderPicker { return NewFolderBrowser(remoteFolders("warming", ""), shotHere, "") }, "cher", nil)},
		shotState{"host-needs-sign-in", folderShot(func() FolderPicker {
			return NewFolderBrowser(remoteFolders("needs_auth", "Permission denied (publickey)"), shotHere, "")
		}, "cher", nil)},
		shotState{"host-unreachable", folderShot(func() FolderPicker {
			return NewFolderBrowser(remoteFolders("unreachable", "no route to host"), shotHere, "")
		}, "cher", nil)},
		shotState{"sessions-stepped", folderShot(func() FolderPicker { return NewFolderBrowser(remoteFolders("ready", ""), shotHere, "") }, "", func(m *FolderPicker) {
			*m, _ = m.Update(right)
		})},
		shotState{"sessions-failed", folderShot(func() FolderPicker { return NewFolderBrowser(remoteFolders("ready", ""), shotHere, "") }, "", func(m *FolderPicker) {
			m.sessionsError = "daemon did not answer"
		})},
		shotState{"notice", folderShot(func() FolderPicker { return NewFolderBrowser(remoteFolders("ready", ""), shotHere, "") }, "", func(m *FolderPicker) {
			m.Refused(errors.New("chernobog: connection refused"))
		})},
		shotState{"moving", folderShot(func() FolderPicker { return NewFolderPicker(remoteFolders("ready", ""), session, nil) }, "", func(m *FolderPicker) {
			m.moving = true
		})},
	)
}

// folderShot draws the picker built by build, after the first listing has
// settled, then typed query, then setup.
func folderShot(build func() FolderPicker, query string, setup func(*FolderPicker)) func(width, height int) string {
	return func(width, height int) string {
		m := build()
		m.SetSize(width, height)
		m = drainPicker(m, m.Init())
		m = typeText(m, query)
		if setup != nil {
			setup(&m)
		}
		return m.View()
	}
}
