package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"github.com/charmbracelet/lipgloss"
	"regexp"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

var whitespaceRegex = regexp.MustCompile(`[\p{Cc}\p{Cf}\p{Z}]+`)

func readablePreview(value string) string {
	clean := strings.TrimSpace(whitespaceRegex.ReplaceAllString(value, " "))
	if clean == "" {
		return "(empty)"
	}
	runes := []rune(clean)
	if len(runes) <= 96 {
		return clean
	}
	return string(runes[:95]) + "…"
}

type TreeCheckpoint struct {
	ID        int    `json:"id"`
	Type      string `json:"type"`
	Preview   string `json:"preview"`
	Timestamp *int64 `json:"timestamp,omitempty"`
}

type TreeCancelMsg struct{}

type TreeForkSuccessMsg struct {
	Session daemon.Session
}

type treeLoadedMsg struct {
	Items      []TreeCheckpoint
	NextCursor *int
	HasMore    bool
	Err        error
	Gen        int
}

type treeForkedMsg struct {
	Session daemon.Session
	Err     error
	Gen     int
}

type TreePickerModel struct {
	Conn        *daemon.Connection
	SessionID   string
	Cursors     []int
	PageIndex   int
	Checkpoints []TreeCheckpoint
	NextCursor  *int
	HasMore     bool
	Cursor      int
	Confirming  bool
	Forking     bool
	Loading     bool
	Error       string
	ForkError   string
	Generation  int
	Width       int
	Height      int
	Styles      Styles
}

func NewTreePickerModel(conn *daemon.Connection, sessionID string) TreePickerModel {
	return TreePickerModel{
		Conn:      conn,
		SessionID: sessionID,
		Cursors:   []int{0},
		PageIndex: 0,
		Loading:   true,
		Styles:    DefaultStyles,
	}
}

func (m *TreePickerModel) SetSize(width, height int) {
	m.Width = width
	m.Height = height
}

func (m TreePickerModel) Init() tea.Cmd {
	return m.loadTreeCmd(0, m.Generation)
}

func (m TreePickerModel) loadTreeCmd(after int, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return treeLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}

		// Check capability
		health, err := daemon.Request[struct {
			Capabilities []string `json:"capabilities"`
		}](context.Background(), m.Conn, "/health", nil)
		if err != nil {
			return treeLoadedMsg{Err: err, Gen: gen}
		}
		hasCap := false
		for _, c := range health.Capabilities {
			if c == "session_tree" {
				hasCap = true
				break
			}
		}
		if !hasCap {
			return treeLoadedMsg{
				Err: errors.New("daemon upgrade needed for /tree; when ready, run albedo daemon --stop, then albedo (this clears python variables)"),
				Gen: gen,
			}
		}

		type treeResp struct {
			Items      []TreeCheckpoint `json:"items"`
			NextCursor *int             `json:"nextCursor"`
			HasMore    bool             `json:"hasMore"`
		}
		path := fmt.Sprintf("/sessions/%s/tree?after=%d&limit=50", m.SessionID, after)
		resp, err := daemon.Request[treeResp](context.Background(), m.Conn, path, nil)
		if err != nil {
			return treeLoadedMsg{Err: err, Gen: gen}
		}
		return treeLoadedMsg{
			Items:      resp.Items,
			NextCursor: resp.NextCursor,
			HasMore:    resp.HasMore,
			Gen:        gen,
		}
	}
}

func (m TreePickerModel) forkCmd(checkpointID int, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return treeForkedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		path := fmt.Sprintf("/sessions/%s/fork", m.SessionID)
		body := map[string]int{"checkpoint": checkpointID}
		branch, err := daemon.Request[daemon.Session](context.Background(), m.Conn, path, body)
		return treeForkedMsg{Session: branch, Err: err, Gen: gen}
	}
}

func (m TreePickerModel) Update(msg tea.Msg) (TreePickerModel, tea.Cmd) {
	switch msg := msg.(type) {
	case treeLoadedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Loading = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil
		}
		m.Checkpoints = msg.Items
		m.NextCursor = msg.NextCursor
		m.HasMore = msg.HasMore
		m.Cursor = 0
		m.Confirming = false
		m.ForkError = ""
		m.Error = ""
		return m, nil

	case treeForkedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Forking = false
		if msg.Err != nil {
			m.ForkError = msg.Err.Error()
			return m, nil
		}
		branch := msg.Session
		return m, func() tea.Msg {
			return TreeForkSuccessMsg{Session: branch}
		}

	case tea.KeyMsg:
		if msg.Type == tea.KeyEsc || msg.Type == tea.KeyCtrlC || msg.Type == tea.KeyCtrlD {
			if m.Confirming {
				m.Confirming = false
				m.Error = ""
				return m, nil
			}
			return m, func() tea.Msg { return TreeCancelMsg{} }
		}

		if m.Forking || m.Loading {
			return m, nil
		}

		if m.Confirming {
			if msg.Type == tea.KeyEnter && len(m.Checkpoints) > m.Cursor {
				cp := m.Checkpoints[m.Cursor]
				m.Forking = true
				m.ForkError = ""
				m.Error = ""
				m.Generation++
				return m, m.forkCmd(cp.ID, m.Generation)
			}
			return m, nil
		}

		switch msg.Type {
		case tea.KeyUp, tea.KeyCtrlP:
			if m.Cursor > 0 {
				m.Cursor--
			}
		case tea.KeyDown, tea.KeyCtrlN:
			if m.Cursor < len(m.Checkpoints)-1 {
				m.Cursor++
			}
		case tea.KeyLeft, tea.KeyPgUp:
			if m.PageIndex > 0 {
				m.PageIndex--
				m.Loading = true
				m.Error = ""
				m.Generation++
				return m, m.loadTreeCmd(m.Cursors[m.PageIndex], m.Generation)
			}
		case tea.KeyRight, tea.KeyPgDown:
			if m.HasMore && m.NextCursor != nil {
				next := *m.NextCursor
				m.Cursors = append(m.Cursors[:m.PageIndex+1], next)
				m.PageIndex++
				m.Loading = true
				m.Error = ""
				m.Generation++
				return m, m.loadTreeCmd(next, m.Generation)
			}
		case tea.KeyEnter:
			if len(m.Checkpoints) > 0 && m.Cursor < len(m.Checkpoints) {
				m.ForkError = ""
				m.Confirming = true
			}
		}
	}
	return m, nil
}

func (m TreePickerModel) View() string {
	var b strings.Builder

	b.WriteString("albedo /tree · branch history")
	b.WriteString("\n")
	b.WriteString(m.Styles.Dim.Render(inkWrap("choose the checkpoint the new session should end after", m.Width)))
	b.WriteString("\n")

	if m.Error != "" {
		b.WriteString(inkRed.Render("Error: " + m.Error))
		b.WriteByte('\n')
	}
	if m.Loading || len(m.Checkpoints) == 0 {
		if m.Error == "" && !m.Loading {
			b.WriteString(m.Styles.Dim.Render("no branchable history in this session"))
			b.WriteByte('\n')
		}
		if m.Error == "" && m.Loading {
			b.WriteString(m.Styles.Dim.Render("loading history…"))
			b.WriteByte('\n')
		}
		b.WriteString(m.Styles.Dim.Render("enter confirm · esc cancel"))
		return b.String()
	}

	lines := make([]string, len(m.Checkpoints))
	for i, cp := range m.Checkpoints {
		lines[i] = lipgloss.NewStyle().Faint(true).Render(fmt.Sprintf("%-9s", cp.Type)) + " " + readablePreview(cp.Preview)
	}
	b.WriteString(selectableRows(lines, m.Cursor, m.Height, m.Height, m.Width, m.Styles))
	b.WriteByte('\n')

	if m.Confirming && m.Cursor < len(m.Checkpoints) {
		current := m.Checkpoints[m.Cursor]
		b.WriteString("\n")
		b.WriteString(inkYellow.Render(fmt.Sprintf("branch after %s · %s?", current.Type, readablePreview(current.Preview))))
		b.WriteString("\n")
		b.WriteString("new session · fresh python namespace · workspace files stay unchanged\n")
		if m.ForkError != "" {
			b.WriteString(inkRed.Render(m.ForkError))
			b.WriteByte('\n')
		}
	}

	if m.Forking {
		b.WriteString(m.Styles.Dim.Render("creating branch…"))
	} else if m.Confirming {
		confirmAction := "enter confirm"
		if m.ForkError != "" {
			confirmAction = "enter retry"
		}
		b.WriteString(m.Styles.Dim.Render(fmt.Sprintf("%s · esc cancel", confirmAction)))
	} else {
		b.WriteString(m.Styles.Dim.Render(inkWrap("↑↓ select · ←→/pgup/pgdn page · enter branch · esc return to chat", m.Width)))
	}

	return b.String()
}
