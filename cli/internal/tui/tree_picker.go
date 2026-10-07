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

// previewText is a checkpoint's preview on one line, whole.
func previewText(value string) string {
	clean := strings.TrimSpace(whitespaceRegex.ReplaceAllString(value, " "))
	if clean == "" {
		return "(empty)"
	}
	return clean
}

// readablePreview is previewText cut short for a question.
func readablePreview(value string) string {
	runes := []rune(previewText(value))
	if len(runes) <= 96 {
		return string(runes)
	}
	return string(runes[:95]) + "…"
}

type TreeCancelMsg struct{}

type TreeForkSuccessMsg struct {
	Session    daemon.Session
	Generation int
}

type treeLoadedMsg struct {
	Err        error
	NextCursor *int
	Items      []daemon.TreeCheckpoint
	Gen        int
	HasMore    bool
}

type treeForkedMsg struct {
	Err     error
	Session daemon.Session
	Gen     int
}

// TreePickerModel lists a session's checkpoints. Enter asks, and a second
// enter branches the session from the checkpoint under the cursor.
type TreePickerModel struct {
	Conn        *daemon.Connection
	NextCursor  *int
	SessionID   string
	ForkError   string
	Cursors     []int
	Checkpoints []daemon.TreeCheckpoint
	pageStatus
	listView
	confirm
	PageIndex int
	HasMore   bool
	Forking   bool
}

func NewTreePickerModel(conn *daemon.Connection, sessionID string) TreePickerModel {
	return TreePickerModel{
		Conn:       conn,
		SessionID:  sessionID,
		Cursors:    []int{0},
		pageStatus: newPageStatus(true),
		listView:   newListView("Search checkpoints"),
	}
}

func (m *TreePickerModel) SetSize(width, height int) {
	m.pageStatus.SetSize(width, height)
	m.listView.setSize(width, height)
}

// Confirming reports a question waiting for enter or esc.
func (m TreePickerModel) Confirming() bool { return m.confirm.asking() }

func (m TreePickerModel) Init() tea.Cmd {
	return m.loadTreeCmd(0, m.Generation)
}

func (m TreePickerModel) loadPage(after int) (TreePickerModel, tea.Cmd) {
	m.Loading, m.Error = true, ""
	m.Generation = nextPageGeneration()
	return m, m.loadTreeCmd(after, m.Generation)
}

func (m TreePickerModel) loadTreeCmd(after int, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return treeLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}

		resp, err := daemon.GetSessionTree(context.Background(), m.Conn, m.SessionID, after, 50)
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

func (m TreePickerModel) forkCmd(checkpointID string, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return treeForkedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		branch, err := daemon.ForkSession(context.Background(), m.Conn, m.SessionID, daemon.ForkRequest{Checkpoint: checkpointID})
		return treeForkedMsg{Session: branch, Err: err, Gen: gen}
	}
}

// current is the checkpoint under the cursor.
func (m TreePickerModel) current() (daemon.TreeCheckpoint, bool) {
	row, ok := m.highlighted()
	if !ok {
		return daemon.TreeCheckpoint{}, false
	}
	i := slices.IndexFunc(m.Checkpoints, func(cp daemon.TreeCheckpoint) bool { return cp.ID == row.key })
	if i < 0 {
		return daemon.TreeCheckpoint{}, false
	}
	return m.Checkpoints[i], true
}

func (m *TreePickerModel) setCheckpoints(items []daemon.TreeCheckpoint) {
	m.Checkpoints = items
	rows := make([]listEntry, len(items))
	for i, cp := range items {
		rows[i] = listEntry{
			key:    cp.ID,
			lead:   DefaultStyles.Faint.Render(cp.Type),
			name:   previewText(cp.Preview),
			search: []string{cp.Type},
			detail: func(width int) []string { return checkpointDetails(cp, width) },
		}
	}
	m.setRows(rows)
}

// checkpointDetails is the pane: the checkpoint's type and whole preview,
// and what branching from it does.
func checkpointDetails(cp daemon.TreeCheckpoint, width int) []string {
	lines := paneTitle(previewText(cp.Preview), "", width)
	lines = append(lines, factRows("type", cp.Type, width)...)
	lines = append(lines, "")
	return append(lines, paneNote("This creates a new session with a fresh Python namespace. Workspace files stay unchanged.", width)...)
}

// fork branches the session from the checkpoint the question named.
func (m *TreePickerModel) fork() tea.Cmd {
	cp, ok := m.current()
	if !ok || cp.ID != m.confirm.target {
		m.confirm.dismiss()
		return nil
	}
	m.Forking, m.ForkError, m.Error = true, "", ""
	m.Generation = nextPageGeneration()
	return m.forkCmd(cp.ID, m.Generation)
}

func (m TreePickerModel) Update(msg tea.Msg) (TreePickerModel, tea.Cmd) {
	switch msg := msg.(type) {
	case treeLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.setCheckpoints(msg.Items)
		m.NextCursor, m.HasMore = msg.NextCursor, msg.HasMore
		m.confirm.dismiss()
		m.ForkError, m.Error = "", ""
		return m, nil

	case treeForkedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Forking = false
		if msg.Err != nil {
			// The question stays open, so enter retries.
			m.ForkError = operationError(msg.Err, "", "Branch may have been created; check the session list before branching again.")
			return m, nil
		}
		return m, func() tea.Msg { return TreeForkSuccessMsg{Session: msg.Session, Generation: msg.Gen} }

	case tea.KeyPressMsg:
		return m.key(msg)
	}
	cmd := m.listView.update(msg)
	return m, cmd
}

func (m TreePickerModel) key(msg tea.KeyPressMsg) (TreePickerModel, tea.Cmd) {
	key := msg.String()
	switch {
	case m.confirm.asking() && !m.Forking:
		if m.confirm.key(msg) {
			cmd := m.fork()
			return m, cmd
		}
		if !m.confirm.asking() {
			m.ForkError = ""
		}
		return m, nil
	case key == "esc" || key == "ctrl+c" || key == "ctrl+d":
		return m, func() tea.Msg { return TreeCancelMsg{} }
	case m.Forking || m.Loading:
		return m, nil
	}

	switch key {
	case "enter":
		if cp, ok := m.current(); ok {
			m.ForkError = ""
			m.confirm.ask("branch", cp.ID, "branch", fmt.Sprintf("Branch after %s · %s?", cp.Type, readablePreview(cp.Preview)))
		}
		return m, nil
	case "ctrl+r":
		return m.loadPage(m.Cursors[m.PageIndex])
	case "pgdown":
		// Past the last row, paging moves on to the next server page.
		if m.HasMore && m.NextCursor != nil && m.Cursor >= len(m.shown)-1 {
			next := *m.NextCursor
			m.Cursors = append(m.Cursors[:m.PageIndex+1], next)
			m.PageIndex++
			return m.loadPage(next)
		}
	case "pgup":
		if m.PageIndex > 0 && m.Cursor == 0 {
			m.PageIndex--
			return m.loadPage(m.Cursors[m.PageIndex])
		}
	}
	cmd := m.listView.update(msg)
	return m, cmd
}

func (m TreePickerModel) footer(width int) string {
	if m.confirm.asking() && !m.Forking {
		return m.confirm.footer(width, m.ForkError)
	}
	hints := []hint{{"↑↓", "move"}, {"enter", "branch"}, {"esc", "back"}, {"pgup/pgdn", "page"}, {"ctrl+r", "refresh"}}
	if m.Error != "" {
		hints = []hint{{"ctrl+r", "retry"}, {"esc", "back"}}
	}
	var status string
	urgent := true
	switch {
	case m.Forking:
		status = DefaultStyles.Busy.Render("branching…")
	case m.Loading:
		status, urgent = DefaultStyles.Faint.Render("loading…"), false
	case m.Error != "":
		status = DefaultStyles.Error.Render(m.Error)
	}
	return footerLine(width, hints, status, urgent)
}

func (m TreePickerModel) View() string {
	lv := m.listView
	lv.Empty = "No history checkpoints available to branch from."
	if m.Loading {
		lv.Empty = "loading history…"
	}
	title := brand("albedo") + " " + DefaultStyles.Muted.Render("/tree")
	f := lv.frame(title, DefaultStyles.Faint.Render("branch history"), m.footer(max(1, m.Width)))
	// Without the pane's room, the branch note still reads as one line.
	f.summary = "this creates a new session with a fresh Python namespace"
	return f.view(m.Width, m.Height)
}
