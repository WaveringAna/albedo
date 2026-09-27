package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
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
			m.ForkError = msg.Err.Error()
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

		switch msg.String() {
		case "up", "ctrl+p":
			if m.Cursor > 0 {
				m.Cursor--
			}
		case "down", "ctrl+n":
			if m.Cursor < len(m.Checkpoints)-1 {
				m.Cursor++
			}
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

	b.WriteString(titleRule(m.Width, brand("albedo")+" "+m.Styles.Muted.Render("/tree"), m.Styles.Faint.Render("branch history")) + "\n")
	b.WriteString(m.Styles.Faint.Render(inkWrap("choose the checkpoint the new session should end after", m.Width)) + "\n")

	if m.Error != "" {
		b.WriteString(DefaultStyles.Error.Render("error:") + " " + m.Error + "\n")
	}
	if m.Loading || len(m.Checkpoints) == 0 {
		if m.Error == "" {
			msg := pick(m.Loading, "loading history…", "no branchable history in this session")
			b.WriteString(m.Styles.Faint.Render(msg) + "\n")
		}
		b.WriteString(keyHints(hint{"enter", "confirm"}, hint{"esc", "cancel"}))
		return b.String()
	}

	lines := make([]string, len(m.Checkpoints))
	for i, cp := range m.Checkpoints {
		lines[i] = DefaultStyles.Faint.Render(fmt.Sprintf("%-9s", cp.Type)) + " " + readablePreview(cp.Preview)
	}
	b.WriteString(selectableRows(lines, m.Cursor, m.Height, m.Height, m.Width, m.Styles) + "\n")

	if m.Confirming && m.Cursor < len(m.Checkpoints) {
		current := m.Checkpoints[m.Cursor]
		b.WriteString("\n" + DefaultStyles.Warning.Render(fmt.Sprintf("branch after %s · %s?", current.Type, readablePreview(current.Preview))) + "\n")
		b.WriteString(m.Styles.Faint.Render("new session · fresh python namespace · workspace files stay unchanged") + "\n")
		if m.ForkError != "" {
			b.WriteString(DefaultStyles.Error.Render(m.ForkError) + "\n")
		}
	}

	if m.Forking {
		b.WriteString(m.Styles.Faint.Render("creating branch…"))
	} else if m.Confirming {
		confirm := pick(m.ForkError != "", hint{"enter", "retry"}, hint{"enter", "confirm"})
		b.WriteString(keyHints(confirm, hint{"esc", "cancel"}))
	} else {
		b.WriteString(inkWrap(keyHints(hint{"↑↓", "select"}, hint{"←→/pgup/pgdn", "page"}, hint{"enter", "branch"}, hint{"esc", "return to chat"}), m.Width))
	}

	return b.String()
}
