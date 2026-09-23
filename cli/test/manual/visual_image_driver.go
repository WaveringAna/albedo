//go:build ignore

// Manual PTY driver for ChatModel's image event. No clipboard or daemon call occurs.
package main

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"
	tea "github.com/charmbracelet/bubbletea"
	"os"
)

type imageModel struct{ chat tui.ChatModel }

func (m imageModel) Init() tea.Cmd {
	id, gen := m.chat.SessionID, m.chat.Generation
	return func() tea.Msg {
		return tui.ClipboardImagePastedMsg{SessionID: id, Generation: gen, Image: &daemon.ImageAttachment{ImageMetadata: daemon.ImageMetadata{MimeType: daemon.ImagePNG, Width: 2, Height: 3, Bytes: 42}, Data: "fake-driver-only"}}
	}
}
func (m imageModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if size, ok := msg.(tea.WindowSizeMsg); ok {
		m.chat.SetSize(size.Width, size.Height)
		return m, nil
	}
	if key, ok := msg.(tea.KeyMsg); ok && key.Type == tea.KeyCtrlC {
		return m, tea.Quit
	}
	var cmd tea.Cmd
	m.chat, cmd = m.chat.Update(msg)
	return m, cmd
}
func (m imageModel) View() string { return m.chat.View() }
func main() {
	if os.Getenv("ALBEDO_NO_BROWSER") != "1" || os.Getenv("ALBEDO_HOME") == "" {
		panic("manual image driver requires isolated ALBEDO_HOME and ALBEDO_NO_BROWSER=1")
	}
	session := &daemon.Session{ID: "manual-image", Workspace: "/tmp/albedo-visual-fixture", Model: "gpt-4o"}
	chat := tui.NewChatModel(session, nil)
	phase := daemon.PhaseResting
	chat.Status = daemon.AgentStatus{Idle: true, Phase: &phase}
	_, err := tea.NewProgram(imageModel{chat: chat}, tea.WithMouseCellMotion()).Run()
	if err != nil {
		panic(err)
	}
}
