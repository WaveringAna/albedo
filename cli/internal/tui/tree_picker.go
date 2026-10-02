package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"slices"
	"strings"

	tea "charm.land/bubbletea/v2"
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
	Timestamp *int64 `json:"timestamp,omitempty"`
	Type      string `json:"type"`
	Preview   string `json:"preview"`
	ID        int    `json:"id"`
}

type TreeCancelMsg struct{}

type TreeForkSuccessMsg struct {
	Session daemon.Session
}

type treeLoadedMsg struct {
	Err        error
	NextCursor *int
	Items      []TreeCheckpoint
	Gen        int
	HasMore    bool
}

type treeForkedMsg struct {
	Err     error
	Session daemon.Session
	Gen     int
}

type TreePickerModel struct {
	Styles      Styles
	Conn        *daemon.Connection
	NextCursor  *int
	SessionID   string
	ForkError   string
	Cursors     []int
	Checkpoints []TreeCheckpoint
	page
	PageIndex  int
	HasMore    bool
	Confirming bool
	Forking    bool
}

func NewTreePickerModel(conn *daemon.Connection, sessionID string) TreePickerModel {
	return TreePickerModel{
		Conn:      conn,
		SessionID: sessionID,
		Cursors:   []int{0},
		PageIndex: 0,
		page:      page{Loading: true},
		Styles:    DefaultStyles,
	}
}

func (m TreePickerModel) Init() tea.Cmd {
	return m.loadTreeCmd(0, m.Generation)
}

func (m TreePickerModel) loadPage(after int) (TreePickerModel, tea.Cmd) {
	m.Loading, m.Error = true, ""
	m.Generation++
	return m, m.loadTreeCmd(after, m.Generation)
}

func (m TreePickerModel) loadTreeCmd(after int, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return treeLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}

		caps, err := daemon.Capabilities(context.Background(), m.Conn)
		if err == nil && !slices.Contains(caps, "session_tree") {
			err = daemon.UpgradeNeeded("for /tree")
		}
		if err != nil {
			return treeLoadedMsg{Err: err, Gen: gen}
		}

		type treeResp struct {
			NextCursor *int             `json:"nextCursor"`
			Items      []TreeCheckpoint `json:"items"`
			HasMore    bool             `json:"hasMore"`
		}
		path := fmt.Sprintf("/sessions/%s/tree?after=%d&limit=50", m.SessionID, after)
		resp, err := daemon.RequestOperation[treeResp](context.Background(), m.Conn, daemon.Operation{Name: "load tree", Method: http.MethodGet, Path: path, Body: nil, Policy: daemon.ReadRecovery})
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
		branch, err := daemon.ForkSession(context.Background(), m.Conn, m.SessionID, map[string]any{"checkpoint": checkpointID})
		return treeForkedMsg{Session: branch, Err: err, Gen: gen}
	}
}

func (m TreePickerModel) Update(msg tea.Msg) (TreePickerModel, tea.Cmd) {
	switch msg := msg.(type) {
	case treeLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.Checkpoints, m.NextCursor, m.HasMore = msg.Items, msg.NextCursor, msg.HasMore
		m.Cursor, m.Confirming = 0, false
		m.ForkError, m.Error = "", ""
		return m, nil

	case treeForkedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Forking = false
		if msg.Err != nil {
			m.ForkError = operationError(msg.Err, "", "Branch may have been created; check the session list before branching again.")
			return m, nil
		}
		return m, func() tea.Msg { return TreeForkSuccessMsg{Session: msg.Session} }

	case tea.KeyPressMsg:
		if msg.String() == "esc" || msg.String() == "ctrl+c" || msg.String() == "ctrl+d" {
			if m.Confirming {
				m.Confirming, m.Error = false, ""
				return m, nil
			}
			return m, func() tea.Msg { return TreeCancelMsg{} }
		}

		if m.Forking || m.Loading {
			return m, nil
		}

		if m.Confirming {
			if msg.String() == "enter" && len(m.Checkpoints) > m.Cursor {
				cp := m.Checkpoints[m.Cursor]
				m.Forking = true
				m.ForkError, m.Error = "", ""
				m.Generation++
				return m, m.forkCmd(cp.ID, m.Generation)
			}
			return m, nil
		}

		if m.step(msg.String(), len(m.Checkpoints)) {
			return m, nil
		}
		switch msg.String() {
		case "left", "pgup":
			if m.PageIndex > 0 {
				m.PageIndex--
				return m.loadPage(m.Cursors[m.PageIndex])
			}
		case "right", "pgdown":
			if m.HasMore && m.NextCursor != nil {
				next := *m.NextCursor
				m.Cursors = append(m.Cursors[:m.PageIndex+1], next)
				m.PageIndex++
				return m.loadPage(next)
			}
		case "enter":
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

	b.WriteString(titleRule(m.Width, brand("albedo")+" "+m.Styles.Muted.Render("/tree"), m.Styles.Faint.Render("branch history")))
	b.WriteByte('\n')
	b.WriteString(m.Styles.Faint.Render(inkWrap("Choose where the new session should branch from.", m.Width)))
	b.WriteByte('\n')

	if m.Error != "" {
		b.WriteString(DefaultStyles.Error.Render("error:"))
		b.WriteByte(' ')
		b.WriteString(m.Error)
		b.WriteByte('\n')
	}
	if m.Loading || len(m.Checkpoints) == 0 {
		if m.Error == "" {
			msg := "No history checkpoints available to branch from."
			if m.Loading {
				msg = "loading history…"
			}
			b.WriteString(m.Styles.Faint.Render(msg))
			b.WriteByte('\n')
		}
		b.WriteString(keyHints(hint{"enter", "confirm"}, hint{"esc", "cancel"}))
		return b.String()
	}

	lines := make([]string, len(m.Checkpoints))
	for i, cp := range m.Checkpoints {
		lines[i] = DefaultStyles.Faint.Render(fmt.Sprintf("%-9s", cp.Type)) + " " + readablePreview(cp.Preview)
	}
	b.WriteString(selectableRows(lines, m.Cursor, m.Height, m.Height, m.Width, m.Styles))
	b.WriteByte('\n')

	if m.Confirming && m.Cursor < len(m.Checkpoints) {
		current := m.Checkpoints[m.Cursor]
		b.WriteByte('\n')
		b.WriteString(m.Styles.Faint.Render(inkWrap("This creates a new session with a fresh Python namespace. Workspace files stay unchanged.", m.Width)))
		b.WriteByte('\n')
		b.WriteString(DefaultStyles.Warning.Render(fmt.Sprintf("Branch after %s · %s?", current.Type, readablePreview(current.Preview))))
		b.WriteByte('\n')
		if m.ForkError != "" {
			b.WriteString(DefaultStyles.Error.Render(m.ForkError))
			b.WriteByte('\n')
		}
	}

	if m.Forking {
		b.WriteString(m.Styles.Faint.Render("Creating the new session…"))
	} else if m.Confirming {
		confirm := hint{"enter", "confirm"}
		if m.ForkError != "" {
			confirm = hint{"enter", "retry"}
		}
		b.WriteString(keyHints(confirm, hint{"esc", "cancel"}))
	} else {
		b.WriteString(inkWrap(keyHints(hint{"↑↓", "select"}, hint{"←→/pgup/pgdn", "page"}, hint{"enter", "branch"}, hint{"esc", "return to chat"}), m.Width))
	}

	return b.String()
}
