package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

type ChatBackToSessionsMsg struct{}
type ChatQuitMsg struct{}
type ChatNewSessionMsg struct{}
type ChatOpenModelPickerMsg struct{}
type ChatOpenExtensionPickerMsg struct{}
type ChatOpenTreePickerMsg struct{}
type ChatOpenContextInspectorMsg struct{}
type ChatOpenPageMsg struct {
	Command string
}
type ChatOpenLoginMsg struct {
	Name string
}
type ChatExecuteCommandMsg struct {
	Name string
	Args string
}

type ChatStreamEventMsg struct {
	SessionID  string
	Generation int64
	Event      daemon.StreamEvent
}

type ChatProgressTickMsg struct {
	SessionID  string
	Generation int64
}

type ChatClearCopyStatusMsg struct {
	SessionID  string
	Generation int64
	Revision   uint64
}

type ChatStatusMsg struct {
	SessionID  string
	Generation int64
	Revision   uint64
	Status     *daemon.AgentStatus
	Err        error
}

type ChatStatusPollMsg struct {
	SessionID  string
	Generation int64
}

type ChatStreamClosedMsg struct {
	SessionID  string
	Generation int64
}

type ChatTurnSentMsg struct {
	SessionID  string
	Generation int64
	Prompt     string
	Image      *daemon.ImageAttachment
	OK         bool
	Queued     bool
	Err        error
}

type ChatInterruptMsg struct {
	SessionID   string
	Generation  int64
	Interrupted bool
	Err         error
}

type ChatReplaceWorkspaceMsg struct {
	SessionID  string
	Generation int64
	Workspace  string
	Err        error
}

type WorkspaceRecoveryState struct {
	Missing     string
	Replacement string
	Prompt      string
	Image       *daemon.ImageAttachment
	Saving      bool
	Error       string
}

type ActiveStreamKind string

const (
	StreamKindNone     ActiveStreamKind = ""
	StreamKindText     ActiveStreamKind = "text"
	StreamKindThinking ActiveStreamKind = "thinking"
)

type PendingUserTurn struct {
	Text   string
	Image  *daemon.ImageAttachment
	Queued bool
}

const (
	MaxLiveStreamBytes   = 64 * 1024
	MaxPendingUsers      = 10
	MaxSettledLines      = 1000
	MaxSettledLinesBytes = 256 * 1024
	fnvOffset64          = 14695981039346656037
	fnvPrime64           = 1099511628211
)

func fnv1a(h uint64, s string) uint64 {
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= fnvPrime64
	}
	return h
}

var sgrCode = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func wrapOrChunkLine(line string, width int) []string {
	if width <= 0 {
		width = 80
	}
	// Match wrap-ansi's hard:true, trim:false word placement: a separator
	// consumes a cell before deciding whether the next word fits.
	words := strings.Split(line, " ")
	rows := []string{""}
	used := 0
	for i, word := range words {
		if i > 0 {
			if used >= width {
				rows = append(rows, "")
				used = 0
			}
			rows[len(rows)-1] += " "
			used++
		}
		wordWidth := ansi.StringWidth(word)
		if wordWidth > width {
			remaining := width - used
			breaksHere := 1 + (wordWidth-remaining-1)/width
			breaksNext := (wordWidth - 1) / width
			if breaksNext < breaksHere {
				rows = append(rows, "")
				used = 0
			}
			wrapped := strings.Split(ansi.Hardwrap(rows[len(rows)-1]+word, width, true), "\n")
			rows[len(rows)-1] = wrapped[0]
			rows = append(rows, wrapped[1:]...)
			used = ansi.StringWidth(rows[len(rows)-1])
			continue
		}
		if used+wordWidth > width && used > 0 && wordWidth > 0 {
			rows = append(rows, "")
			used = 0
		}
		rows[len(rows)-1] += word
		used += wordWidth
	}
	// Every viewport row can be rendered alone after a history scroll. Reopen
	// styles that cross a physical wrap, as wrap-ansi does for the TS rows.
	style := ""
	for i, row := range rows {
		if style != "" {
			rows[i] = style + row
		}
		for _, code := range sgrCode.FindAllString(row, -1) {
			if code == "\x1b[0m" || code == "\x1b[m" {
				style = ""
			} else {
				style += code
			}
		}
		if style != "" && i < len(rows)-1 {
			rows[i] += "\x1b[0m"
		}
	}
	return rows
}

type ChatModel struct {
	SessionID          string
	Generation         int64
	AgentName          string
	Workspace          string
	Model              string
	Provider           string
	Client             *daemon.ChatClient
	History            *BoundedHistory
	Renderer           TranscriptRenderer
	Viewport           viewport.Model
	TextArea           textarea.Model
	CommandMenu        CommandMenuModel
	Flags              DisplayFlags
	Follow             bool
	TurnFailed         bool
	Stopping           bool
	Stopped            bool
	Status             daemon.AgentStatus
	Usage              *daemon.Usage
	Glances            []PageGlance
	AttachedImage      *daemon.ImageAttachment
	Notice             string
	CopyStatus         string
	copyStatusRevision uint64
	ErrorNotice        string
	ExternalNotice     string
	ExternalError      string
	ToolProgressText   string
	Progress           *daemon.ToolProgress
	ProgressFrame      int
	animationActive    bool
	statusRevision     uint64
	Width              int
	Height             int
	Styles             Styles

	settledLines        []string
	settledLinesBytes   int64
	droppedSettledLines int

	scrollOffset int

	activeKind ActiveStreamKind
	activeText string

	streamedHash uint64
	streamedLen  int64

	pendingUsers      []PendingUserTurn
	isSending         bool
	interruptDeferred bool
	// sentHere keeps replayed errors from an earlier attach from reopening
	// /login; loginRequested carries a sign-in failure out of handleStreamEvent.
	sentHere       bool
	loginRequested bool

	WorkspaceRecovery *WorkspaceRecoveryState
	RecoveryInput     textinput.Model

	dragAnchor *Point
	dragHead   Point

	streamCtx    context.Context
	streamCancel context.CancelFunc
	eventChan    chan daemon.StreamEvent
}

func NewChatModel(session *daemon.Session, client *daemon.ChatClient) ChatModel {
	ta := textarea.New()
	ta.Placeholder = ""
	ta.Prompt = "› "
	ta.ShowLineNumbers = false
	ta.KeyMap.InsertNewline.SetKeys("enter", "ctrl+m", "alt+enter", "shift+enter")
	ta.SetHeight(1)
	ta.FocusedStyle.Prompt = DefaultStyles.PromptBright
	ta.FocusedStyle.CursorLine = lipgloss.NewStyle()
	ta.Cursor.Style = lipgloss.NewStyle().Reverse(true)
	ta.Cursor.SetMode(cursor.CursorStatic)
	ta.Focus()

	vp := viewport.New(80, 20)
	vp.YPosition = 0

	bh := NewBoundedHistory(500, 2*1024*1024)

	ctx, cancel := context.WithCancel(context.Background())
	gen := time.Now().UnixNano()

	m := ChatModel{
		SessionID:   session.ID,
		Generation:  gen,
		AgentName:   "albedo",
		Workspace:   session.Workspace,
		Model:       session.Model,
		Provider:    session.Provider,
		Client:      client,
		History:     bh,
		Renderer:    NewTranscriptRenderer(),
		Viewport:    vp,
		TextArea:    ta,
		CommandMenu: NewCommandMenuModel(),
		Flags: DisplayFlags{
			Thinking:   true,
			Tools:      false,
			Compaction: false,
		},
		Follow:       true,
		Styles:       DefaultStyles,
		streamedHash: fnvOffset64,
		streamCtx:    ctx,
		streamCancel: cancel,
		eventChan:    make(chan daemon.StreamEvent, 16),
	}

	return m
}

func (m *ChatModel) Close() {
	if m.streamCancel != nil {
		m.streamCancel()
	}
}

func (m ChatModel) chromeRows() int {
	menu := min(4, len(m.CommandMenu.Matches(m.TextArea.Value())))
	if m.WorkspaceRecovery != nil {
		menu = 2
	}
	notice := 0
	if m.Notice != "" || m.ErrorNotice != "" || m.ExternalNotice != "" || m.ExternalError != "" {
		notice = 1
	}
	return menu + notice + min(3, len(m.pendingUsers))
}

func (m *ChatModel) SetSize(width, height int) {
	if m == nil || m.History == nil {
		return
	}
	if width <= 0 {
		width = 1
	}
	if height <= 0 {
		height = 1
	}

	m.Width = width
	m.Height = height

	padding := m.padding()
	available := max(1, width-2*padding)
	chromeRows := m.chromeRows()
	transcriptWidth := available
	if m.sidebarWidth() > 0 {
		transcriptWidth -= m.sidebarWidth() + 2
	}
	m.Viewport.Width = transcriptWidth
	m.Renderer.HeadingWidth = transcriptWidth
	m.Renderer.BodyWidth = min(100, available)
	m.Viewport.Height = max(1, height-6-chromeRows)
	m.TextArea.SetHeight(1)
	m.TextArea.SetWidth(max(1, available-2))
	m.RecoveryInput.Width = max(1, available-16)

	m.rebuildSettledLines()
	m.refreshViewportContent()
}

func (m *ChatModel) rebuildSettledLines() {
	m.settledLines = nil
	m.settledLinesBytes = 0
	entries := m.History.Entries()
	for _, entry := range entries {
		block := m.Renderer.RenderEntry(entry, m.Flags, m.Viewport.Width)
		if len(m.settledLines) > 0 {
			m.appendSettledLines([]string{""}, false)
		}
		m.appendSettledLines(strings.Split(block, "\n"), entry.Kind == EntryUser || entry.Kind == EntryAssistant)
	}
}

func (m *ChatModel) appendSettledLines(rawLines []string, heading bool) {
	for i, line := range rawLines {
		width := m.Renderer.BodyWidth
		if heading && i == 0 {
			width = m.Viewport.Width
		}
		for _, chunk := range wrapOrChunkLine(line, width) {
			m.settledLines = append(m.settledLines, chunk)
			m.settledLinesBytes += int64(len(chunk))
		}
	}
	m.trimSettledLines()
}

func (m *ChatModel) trimSettledLines() {
	dropped := 0
	for len(m.settledLines) > MaxSettledLines || m.settledLinesBytes > MaxSettledLinesBytes {
		if len(m.settledLines) == 0 {
			break
		}
		removed := m.settledLines[0]
		m.settledLinesBytes -= int64(len(removed))
		m.settledLines[0] = ""
		m.settledLines = m.settledLines[1:]
		dropped++
	}

	if dropped > 0 {
		m.droppedSettledLines += dropped
		m.scrollOffset = max(0, m.scrollOffset-dropped)
		fresh := make([]string, len(m.settledLines))
		for i := range m.settledLines {
			fresh[i] = strings.Clone(m.settledLines[i])
			m.settledLines[i] = ""
		}
		m.settledLines = fresh
	}
}

func (m *ChatModel) appendSettledEntry(entry HistoryEntry) {
	m.History.Append(entry)
	block := m.Renderer.RenderEntry(entry, m.Flags, m.Viewport.Width)
	if len(m.settledLines) > 0 {
		m.appendSettledLines([]string{""}, false)
	}
	m.appendSettledLines(strings.Split(block, "\n"), entry.Kind == EntryUser || entry.Kind == EntryAssistant)
}

func (m *ChatModel) settleActiveStream() {
	if m.activeKind == StreamKindNone || m.activeText == "" {
		m.activeKind = StreamKindNone
		m.activeText = ""
		return
	}
	var kind EntryKind = EntryAssistant
	if m.activeKind == StreamKindThinking {
		kind = EntryThinking
	}
	entry := HistoryEntry{
		Kind:      kind,
		Speaker:   m.AgentName,
		Text:      m.activeText,
		Timestamp: time.Now().UnixMilli(),
	}
	m.appendSettledEntry(entry)
	m.activeKind = StreamKindNone
	m.activeText = ""
}

func (m *ChatModel) refreshViewportContent() {
	if m.Viewport.Height != max(1, m.Height-6-m.chromeRows()) {
		m.SetSize(m.Width, m.Height)
		return
	}
	var allLines []string

	if notice := m.History.TruncationNotice(); notice != "" {
		allLines = append(allLines, m.Styles.Warning.Render(notice), "")
	}
	if m.droppedSettledLines > 0 {
		allLines = append(allLines, m.Styles.Faint.Render(fmt.Sprintf("[%d scrollback lines truncated]", m.droppedSettledLines)), "")
	}

	allLines = append(allLines, m.settledLines...)

	if m.activeKind != StreamKindNone && m.activeText != "" {
		if len(m.settledLines) > 0 {
			allLines = append(allLines, "")
		}
		var kind EntryKind = EntryAssistant
		if m.activeKind == StreamKindThinking {
			kind = EntryThinking
		}
		activeEntry := HistoryEntry{Kind: kind, Speaker: m.AgentName, Text: m.activeText}
		activeBlock := m.Renderer.RenderEntry(activeEntry, m.Flags, m.Viewport.Width)
		for i, line := range strings.Split(activeBlock, "\n") {
			width := m.Renderer.BodyWidth
			if i == 0 {
				width = m.Viewport.Width
			}
			allLines = append(allLines, wrapOrChunkLine(line, width)...)
		}
	}

	if m.ToolProgressText != "" {
		if len(allLines) > 0 {
			allLines = append(allLines, "")
		}
		allLines = append(allLines, m.renderProgress())
	}

	totalLines := len(allLines)
	vpHeight := max(1, m.Viewport.Height)
	maxScroll := max(0, totalLines-vpHeight)

	var visibleSlice []string
	if m.Follow {
		m.scrollOffset = maxScroll
		visibleSlice = allLines[maxScroll:totalLines]
		m.Viewport.SetContent(strings.Join(visibleSlice, "\n"))
		m.Viewport.GotoBottom()
	} else {
		m.scrollOffset = max(0, min(m.scrollOffset, maxScroll))
		end := min(totalLines, m.scrollOffset+vpHeight)
		if m.scrollOffset < end {
			visibleSlice = allLines[m.scrollOffset:end]
		}
		m.Viewport.SetContent(strings.Join(visibleSlice, "\n"))
		m.Viewport.GotoTop()
	}
}

func (m ChatModel) animating() bool {
	return m.isSending || len(m.pendingUsers) > 0 || m.Stopping || m.Progress != nil || m.Status.Running && !m.Status.Idle
}

func (m *ChatModel) startAnimation() tea.Cmd {
	if m.animationActive || !m.animating() {
		return nil
	}
	m.animationActive = true
	return m.progressTickCmd()
}

func (m ChatModel) progressTickCmd() tea.Cmd {
	id, generation := m.SessionID, m.Generation
	return tea.Tick(80*time.Millisecond, func(time.Time) tea.Msg { return ChatProgressTickMsg{SessionID: id, Generation: generation} })
}

func (m ChatModel) waitForNextEvent() tea.Cmd {
	sessID := m.SessionID
	gen := m.Generation
	ch := m.eventChan
	ctx := m.streamCtx

	return func() tea.Msg {
		select {
		case evt, ok := <-ch:
			if !ok {
				return ChatStreamClosedMsg{SessionID: sessID, Generation: gen}
			}
			return ChatStreamEventMsg{SessionID: sessID, Generation: gen, Event: evt}
		case <-ctx.Done():
			return ChatStreamClosedMsg{SessionID: sessID, Generation: gen}
		}
	}
}

func (m ChatModel) startStreamSubscription() tea.Cmd {
	if m.Client == nil {
		return nil
	}
	client := m.Client
	ctx := m.streamCtx
	ch := m.eventChan

	go func() {
		defer close(ch)
		for {
			if ctx.Err() != nil {
				return
			}
			err := client.Stream(ctx, nil, func(evt daemon.StreamEvent) error {
				select {
				case ch <- evt:
					return nil
				case <-ctx.Done():
					return ctx.Err()
				}
			})
			if ctx.Err() != nil {
				return
			}
			_ = err
			select {
			case <-ctx.Done():
				return
			case <-time.After(500 * time.Millisecond):
			}
		}
	}()

	return m.waitForNextEvent()
}

func (m ChatModel) clearCopyStatusCmd() tea.Cmd {
	id, generation, revision := m.SessionID, m.Generation, m.copyStatusRevision
	return tea.Tick(3*time.Second, func(time.Time) tea.Msg {
		return ChatClearCopyStatusMsg{SessionID: id, Generation: generation, Revision: revision}
	})
}

func (m ChatModel) statusCmd() tea.Cmd {
	if m.Client == nil {
		return nil
	}
	client, ctx, id, generation, revision := m.Client, m.streamCtx, m.SessionID, m.Generation, m.statusRevision
	return func() tea.Msg {
		value, err := client.GetStatus(ctx)
		return ChatStatusMsg{SessionID: id, Generation: generation, Revision: revision, Status: value, Err: err}
	}
}

func (m ChatModel) statusPollCmd() tea.Cmd {
	id, generation := m.SessionID, m.Generation
	return tea.Tick(750*time.Millisecond, func(time.Time) tea.Msg { return ChatStatusPollMsg{SessionID: id, Generation: generation} })
}

func (m ChatModel) Init() tea.Cmd {
	return tea.Batch(m.startStreamSubscription(), m.statusCmd())
}

func (m ChatModel) Update(msg tea.Msg) (ChatModel, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.KeyMsg:
		if m.WorkspaceRecovery != nil {
			if msg.Type == tea.KeyEsc {
				prompt := m.WorkspaceRecovery.Prompt
				img := m.WorkspaceRecovery.Image
				m.WorkspaceRecovery = nil
				if m.TextArea.Value() == "" {
					m.TextArea.SetValue(prompt)
				}
				if m.AttachedImage == nil && img != nil {
					m.AttachedImage = img
				}
				m.refreshViewportContent()
				return m, nil
			}
			if msg.Type == tea.KeyEnter {
				m.RecoveryInput.CursorStart()
				replacement := strings.TrimSpace(m.RecoveryInput.Value())
				if replacement != "" && !m.WorkspaceRecovery.Saving {
					m.WorkspaceRecovery.Saving = true
					m.WorkspaceRecovery.Replacement = replacement
					m.WorkspaceRecovery.Error = ""
					return m, m.replaceWorkspaceCmd(replacement)
				}
				return m, nil
			}
			var riCmd tea.Cmd
			m.RecoveryInput, riCmd = m.RecoveryInput.Update(msg)
			return m, riCmd
		}

		if msg.Type == tea.KeyLeft && m.TextArea.Value() == "" {
			return m, func() tea.Msg { return ChatBackToSessionsMsg{} }
		}

		if msg.Type == tea.KeyCtrlC {
			if m.streamCancel != nil {
				m.streamCancel()
			}
			return m, func() tea.Msg { return ChatQuitMsg{} }
		}
		if msg.Type == tea.KeyCtrlN {
			return m, func() tea.Msg { return ChatNewSessionMsg{} }
		}
		if msg.Type == tea.KeyEsc && m.dragAnchor != nil {
			m.dragAnchor = nil
			return m, nil
		}

		inputVal := m.TextArea.Value()
		consumed := m.CommandMenu.OnKey(
			msg,
			inputVal,
			func(replacement string) {
				m.TextArea.SetValue(replacement)
			},
			func(commandName string) {
				m.handleSubmittedCommand(commandName, &cmds)
			},
		)
		if consumed {
			m.SetSize(m.Width, m.Height)
			return m, tea.Batch(cmds...)
		}

		if msg.Type == tea.KeyEsc {
			if m.AttachedImage != nil {
				m.AttachedImage = nil
				m.CopyStatus = "image removed"
				return m, nil
			}
			if m.isSending {
				m.interruptDeferred = true
				m.Stopping = true
				return m, nil
			}
			if m.Status.Running || len(m.pendingUsers) > 0 {
				m.Stopping = true
				if m.Client != nil {
					cmds = append(cmds, m.interruptCmd())
				}
				return m, tea.Batch(cmds...)
			}
		}

		if msg.Type == tea.KeyCtrlV {
			return m, PasteClipboardImageCmd(m.SessionID, m.Generation)
		}

		if msg.Type == tea.KeyPgUp {
			m.Follow = false
			m.scrollOffset = max(0, m.scrollOffset-m.Viewport.Height)
			m.refreshViewportContent()
			return m, nil
		}
		if msg.Type == tea.KeyPgDown {
			m.scrollOffset += m.Viewport.Height
			m.refreshViewportContent()
			if m.scrollOffset >= max(0, len(m.settledLines)-m.Viewport.Height) {
				m.Follow = true
			}
			return m, nil
		}
		if msg.Type == tea.KeyUp {
			if m.TextArea.Line() == 0 {
				m.Follow = false
				m.scrollOffset = max(0, m.scrollOffset-1)
				m.refreshViewportContent()
				return m, nil
			}
		}
		if msg.Type == tea.KeyDown {
			if m.TextArea.Line() >= m.TextArea.LineCount()-1 {
				m.scrollOffset += 1
				m.refreshViewportContent()
				if m.scrollOffset >= max(0, len(m.settledLines)-m.Viewport.Height) {
					m.Follow = true
				}
				return m, nil
			}
		}
		if msg.Type == tea.KeyCtrlHome {
			m.Follow = false
			m.scrollOffset = 0
			m.refreshViewportContent()
			return m, nil
		}
		if msg.Type == tea.KeyCtrlEnd {
			m.Follow = true
			m.refreshViewportContent()
			return m, nil
		}

		if msg.Type == tea.KeyCtrlJ {
			m.Flags.Diffs = !m.Flags.Diffs
			m.rebuildSettledLines()
			m.refreshViewportContent()
			return m, nil
		}
		if msg.Type == tea.KeyCtrlK {
			m.Flags.Compaction = !m.Flags.Compaction
			m.rebuildSettledLines()
			m.refreshViewportContent()
			return m, nil
		}

		if msg.Type == tea.KeyEnter && !msg.Alt {
			trimmed := strings.TrimSpace(m.TextArea.Value())
			if trimmed != "" {
				m.TextArea.Reset()
				m.submitInput(trimmed, &cmds)
				return m, tea.Batch(cmds...)
			}
			return m, nil
		}

	case tea.MouseMsg:
		firstRow := 2
		if m.Notice != "" || m.ErrorNotice != "" || m.ExternalNotice != "" || m.ExternalError != "" {
			firstRow++
		}
		point := func() Point {
			return Point{Row: max(0, min(m.Viewport.Height-1, msg.Y-firstRow)), Col: max(0, min(m.Viewport.Width, msg.X-m.padding()))}
		}
		if msg.Action == tea.MouseActionRelease && m.dragAnchor != nil {
			m.dragHead = point()
			sel := Selection{Anchor: *m.dragAnchor, Head: m.dragHead}
			m.dragAnchor = nil
			if !sel.IsEmpty() {
				lines := strings.Split(m.Viewport.View(), "\n")
				if text := SelectedText(lines, sel); text != "" {
					if err := CopyText(text); err != nil {
						m.CopyStatus = "copy failed: " + err.Error()
					} else {
						m.CopyStatus = "copied"
					}
					m.copyStatusRevision++
					return m, m.clearCopyStatusCmd()
				}
			}
			return m, nil
		}
		if msg.Action == tea.MouseActionMotion && m.dragAnchor != nil {
			m.dragHead = point()
			return m, nil
		}
		if msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft {
			if msg.Y < firstRow || msg.Y >= firstRow+m.Viewport.Height {
				return m, nil
			}
			pt := point()
			m.dragAnchor = &pt
			m.dragHead = pt
			return m, nil
		}
		switch msg.Button {
		case tea.MouseButtonWheelUp:
			m.Follow = false
			m.scrollOffset = max(0, m.scrollOffset-3)
			m.refreshViewportContent()
			return m, nil
		case tea.MouseButtonWheelDown:
			m.scrollOffset += 3
			m.refreshViewportContent()
			if m.scrollOffset >= max(0, len(m.settledLines)-m.Viewport.Height) {
				m.Follow = true
			}
			return m, nil
		}

	case ClipboardImagePastedMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		if msg.Err == nil && msg.Image != nil {
			m.AttachedImage = msg.Image
			m.CopyStatus = ""
			m.refreshViewportContent()
		} else if msg.Err != nil && msg.Err.Error() != "no image in clipboard" {
			m.ErrorNotice = fmt.Sprintf("image paste failed: %v", msg.Err)
		}
		return m, nil

	case ChatStatusPollMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		return m, m.statusCmd()

	case ChatStatusMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		if msg.Err == nil && msg.Status != nil && msg.Revision == m.statusRevision {
			m.Status = *msg.Status
			if !m.Status.Running || m.Status.Idle {
				m.Progress = nil
				m.ToolProgressText = ""
				m.settleActiveStream()
				m.refreshViewportContent()
			}
		}
		return m, tea.Batch(m.startAnimation(), m.statusPollCmd())

	case ChatStreamEventMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		m.statusRevision++
		m.handleStreamEvent(msg.Event)
		m.refreshViewportContent()
		if m.loginRequested {
			m.loginRequested = false
			return m, tea.Batch(m.waitForNextEvent(), func() tea.Msg { return ChatOpenLoginMsg{} })
		}
		return m, tea.Batch(m.waitForNextEvent(), m.startAnimation())

	case ChatClearCopyStatusMsg:
		if msg.SessionID == m.SessionID && msg.Generation == m.Generation && msg.Revision == m.copyStatusRevision {
			m.CopyStatus = ""
		}
		return m, nil

	case ChatProgressTickMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		if !m.animating() {
			m.animationActive = false
			return m, nil
		}
		m.ProgressFrame++
		m.refreshViewportContent()
		return m, m.progressTickCmd()

	case ChatStreamClosedMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		return m, nil

	case ChatTurnSentMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		m.isSending = false
		if msg.Err != nil {
			m.interruptDeferred = false
			var wsErr *daemon.WorkspaceMissingError
			if errors.As(msg.Err, &wsErr) {
				m.Status.Running = false
				m.Status.Idle = true
				if len(m.pendingUsers) > 0 {
					m.pendingUsers = m.pendingUsers[1:]
				}
				if m.TextArea.Value() == "" {
					m.TextArea.SetValue(msg.Prompt)
				}
				if m.AttachedImage == nil && msg.Image != nil {
					m.AttachedImage = msg.Image
				}
				ti := textinput.New()
				ti.SetValue(wsErr.Workspace)
				ti.Focus()
				ti.Prompt = "new workspace › "
				ti.PromptStyle = m.Styles.PromptBright
				ti.Cursor.Style = lipgloss.NewStyle().Reverse(true)
				ti.Cursor.SetMode(cursor.CursorStatic)
				m.RecoveryInput = ti
				m.WorkspaceRecovery = &WorkspaceRecoveryState{
					Missing:     wsErr.Workspace,
					Replacement: wsErr.Workspace,
					Prompt:      msg.Prompt,
					Image:       msg.Image,
				}
				m.refreshViewportContent()
				return m, nil
			}

			m.ErrorNotice = fmt.Sprintf("send failed: %v", msg.Err)
			if msg.Queued {
				m.appendSettledEntry(HistoryEntry{Kind: EntryError, Text: "message not queued: " + msg.Err.Error()})
			} else {
				m.appendSettledEntry(HistoryEntry{Kind: EntryError, Text: msg.Err.Error()})
			}
			if m.TextArea.Value() == "" {
				m.TextArea.SetValue(msg.Prompt)
			}
			if m.AttachedImage == nil && msg.Image != nil {
				m.AttachedImage = msg.Image
			}
			if len(m.pendingUsers) > 0 {
				m.pendingUsers = m.pendingUsers[1:]
			}
			m.refreshViewportContent()
			return m, nil
		}

		if msg.Queued {
			for i := range m.pendingUsers {
				if m.pendingUsers[i].Text == msg.Prompt && !m.pendingUsers[i].Queued {
					m.pendingUsers[i].Queued = true
					break
				}
			}
		}

		// If user pressed Esc while this send was in flight, dispatch interrupt now that send is accepted
		if m.interruptDeferred {
			m.interruptDeferred = false
			m.Stopping = true
			if m.Client != nil {
				cmds = append(cmds, m.interruptCmd())
			}
		}
		return m, tea.Batch(cmds...)

	case ChatReplaceWorkspaceMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		if m.WorkspaceRecovery == nil {
			return m, nil
		}
		if msg.Err != nil {
			m.WorkspaceRecovery.Saving = false
			m.WorkspaceRecovery.Error = msg.Err.Error()
			return m, nil
		}
		m.Workspace = msg.Workspace
		prompt := m.WorkspaceRecovery.Prompt
		img := m.WorkspaceRecovery.Image
		m.WorkspaceRecovery = nil

		cmds = append(cmds, func() tea.Msg {
			return ChatWorkspaceChangedMsg{Workspace: msg.Workspace}
		})
		// Set original image BEFORE submitInput so submitInput captures and sends it!
		if img != nil && m.AttachedImage == nil {
			m.AttachedImage = img
		}
		m.TextArea.Reset()
		m.submitInput(prompt, &cmds)
		return m, tea.Batch(cmds...)

	case ChatInterruptMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		if msg.Err != nil || !msg.Interrupted {
			m.Stopping = false
			if msg.Err != nil {
				m.appendSettledEntry(HistoryEntry{Kind: EntryError, Text: "could not stop turn: " + msg.Err.Error()})
			}
		}
		return m, nil
	}

	var taCmd tea.Cmd
	oldMenuRows := min(4, len(m.CommandMenu.Matches(m.TextArea.Value())))
	m.TextArea, taCmd = m.TextArea.Update(msg)
	if min(4, len(m.CommandMenu.Matches(m.TextArea.Value()))) != oldMenuRows {
		m.SetSize(m.Width, m.Height)
	}
	cmds = append(cmds, taCmd)

	return m, tea.Batch(cmds...)
}

func (m *ChatModel) replaceWorkspaceCmd(newWorkspace string) tea.Cmd {
	client := m.Client
	sessID := m.SessionID
	gen := m.Generation

	return func() tea.Msg {
		if client == nil {
			return ChatReplaceWorkspaceMsg{SessionID: sessID, Generation: gen, Err: fmt.Errorf("no client available")}
		}
		upd, err := client.ReplaceWorkspace(context.Background(), newWorkspace)
		if err != nil {
			return ChatReplaceWorkspaceMsg{SessionID: sessID, Generation: gen, Err: err}
		}
		return ChatReplaceWorkspaceMsg{SessionID: sessID, Generation: gen, Workspace: upd.Workspace}
	}
}

func (m *ChatModel) sendTurnCmd(content string, image *daemon.ImageAttachment) tea.Cmd {
	client := m.Client
	sessID := m.SessionID
	gen := m.Generation

	return func() tea.Msg {
		if client == nil {
			return ChatTurnSentMsg{SessionID: sessID, Generation: gen, Prompt: content, Image: image, Err: fmt.Errorf("no client available")}
		}
		res, err := client.Send(context.Background(), content, image)
		if err != nil {
			return ChatTurnSentMsg{SessionID: sessID, Generation: gen, Prompt: content, Image: image, Err: err}
		}
		return ChatTurnSentMsg{SessionID: sessID, Generation: gen, Prompt: content, Image: image, OK: res.OK, Queued: res.Queued}
	}
}

func (m *ChatModel) interruptCmd() tea.Cmd {
	client := m.Client
	sessID := m.SessionID
	gen := m.Generation

	return func() tea.Msg {
		if client == nil {
			return ChatInterruptMsg{SessionID: sessID, Generation: gen, Err: fmt.Errorf("no client available")}
		}
		ok, err := client.Interrupt(context.Background())
		return ChatInterruptMsg{SessionID: sessID, Generation: gen, Interrupted: ok, Err: err}
	}
}

func (m *ChatModel) isRecognizedCommand(input string) bool {
	trimmed := strings.TrimSpace(input)
	if !strings.HasPrefix(trimmed, "/") {
		return false
	}
	parts := strings.Fields(trimmed)
	if len(parts) == 0 {
		return false
	}
	token := parts[0]
	switch token {
	case "/a", "/agents", "/sessions", "/q", "/quit", "/exit", "/new", "/model", "/extensions",
		"/plugins", "/tree", "/context", "/t", "/thinking", "/v", "/verbose",
		"/status", "/login", "/mouse":
		return true
	}
	for _, cmd := range m.CommandMenu.Catalog {
		if cmd.Name == token {
			return true
		}
	}
	return false
}

func (m *ChatModel) submitInput(input string, cmds *[]tea.Cmd) {
	if strings.HasPrefix(input, "/") && m.isRecognizedCommand(input) {
		m.handleSubmittedCommand(input, cmds)
		return
	}

	if len(m.pendingUsers) >= MaxPendingUsers {
		m.ErrorNotice = "too many pending turns; wait for current turn to complete"
		m.refreshViewportContent()
		return
	}

	img := m.AttachedImage
	m.AttachedImage = nil
	m.pendingUsers = append(m.pendingUsers, PendingUserTurn{
		Text:  input,
		Image: img,
	})
	m.isSending = true
	m.sentHere = true
	m.Follow = true
	m.refreshViewportContent()

	*cmds = append(*cmds, m.sendTurnCmd(input, img), m.startAnimation())
}

func (m *ChatModel) handleSubmittedCommand(input string, cmds *[]tea.Cmd) {
	m.TextArea.Reset()
	trimmed := strings.TrimSpace(input)

	switch {
	case trimmed == "/a" || trimmed == "/agents" || trimmed == "/sessions":
		*cmds = append(*cmds, func() tea.Msg { return ChatBackToSessionsMsg{} })
	case trimmed == "/q" || trimmed == "/quit" || trimmed == "/exit":
		if m.streamCancel != nil {
			m.streamCancel()
		}
		*cmds = append(*cmds, func() tea.Msg { return ChatQuitMsg{} })
	case trimmed == "/new":
		*cmds = append(*cmds, func() tea.Msg { return ChatNewSessionMsg{} })
	case trimmed == "/model":
		*cmds = append(*cmds, func() tea.Msg { return ChatOpenModelPickerMsg{} })
	case strings.HasPrefix(trimmed, "/model "):
		modelArg := strings.TrimSpace(trimmed[7:])
		*cmds = append(*cmds, func() tea.Msg {
			return ChatExecuteCommandMsg{Name: "/model", Args: modelArg}
		})
	case trimmed == "/extensions" || trimmed == "/plugins":
		*cmds = append(*cmds, func() tea.Msg { return ChatOpenExtensionPickerMsg{} })
	case trimmed == "/tree":
		*cmds = append(*cmds, func() tea.Msg { return ChatOpenTreePickerMsg{} })
	case trimmed == "/context":
		*cmds = append(*cmds, func() tea.Msg { return ChatOpenContextInspectorMsg{} })
	case trimmed == "/t" || trimmed == "/thinking":
		m.Flags.Thinking = !m.Flags.Thinking
		m.rebuildSettledLines()
		m.refreshViewportContent()
	case trimmed == "/v" || trimmed == "/verbose":
		m.Flags.Tools = !m.Flags.Tools
		m.rebuildSettledLines()
		m.refreshViewportContent()
	case trimmed == "/status":
		statusText := fmt.Sprintf("session: %s\nworkspace: %s\nmodel: %s", m.SessionID, m.Workspace, m.Model)
		if m.Usage != nil {
			statusText += fmt.Sprintf("\ntokens: %s", formatUsage(m.Usage))
		}
		m.appendSettledEntry(HistoryEntry{
			Kind: EntryNote,
			Text: statusText,
		})
		m.refreshViewportContent()
	case strings.HasPrefix(trimmed, "/login"):
		name := strings.TrimSpace(strings.TrimPrefix(trimmed, "/login"))
		*cmds = append(*cmds, func() tea.Msg { return ChatOpenLoginMsg{Name: name} })
	default:
		for _, cmd := range m.CommandMenu.Catalog {
			if cmd.Name == trimmed && cmd.Page != nil && *cmd.Page {
				*cmds = append(*cmds, func() tea.Msg { return ChatOpenPageMsg{Command: trimmed} })
				return
			}
		}
		parts := strings.SplitN(trimmed, " ", 2)
		cmdName := parts[0]
		cmdArgs := ""
		if len(parts) > 1 {
			cmdArgs = parts[1]
		}
		*cmds = append(*cmds, func() tea.Msg {
			return ChatExecuteCommandMsg{Name: cmdName, Args: cmdArgs}
		})
	}
}

func (m *ChatModel) handleStreamEvent(evt daemon.StreamEvent) {
	if evt.Type != daemon.EventToolProgress {
		m.Progress = nil
	}
	switch evt.Type {
	case daemon.EventReset:
		m.settleActiveStream()
		m.History.Clear()
		m.settledLines = nil
		m.settledLinesBytes = 0
		m.droppedSettledLines = 0
		m.activeKind = StreamKindNone
		m.activeText = ""
		m.streamedHash = fnvOffset64
		m.streamedLen = 0
		m.ToolProgressText = ""
		m.Usage = nil
		m.Notice = ""
		m.ErrorNotice = ""
		m.TurnFailed = false
		m.Stopping = false
		m.Stopped = false
		m.Follow = true
		m.scrollOffset = 0
		m.pendingUsers = nil

	case daemon.EventRetry:
		m.activeKind = StreamKindNone
		m.activeText = ""
		m.streamedHash = fnvOffset64
		m.streamedLen = 0
		m.ToolProgressText = ""

	case daemon.EventUser:
		m.Stopped = false
		m.TurnFailed = false
		m.settleActiveStream()

		if m.Client != nil && evt.ClientID == m.Client.ClientID() {
			for i, p := range m.pendingUsers {
				if p.Text == evt.Text {
					m.pendingUsers = append(m.pendingUsers[:i], m.pendingUsers[i+1:]...)
					break
				}
			}
		}

		speaker := "You"
		if evt.Source != "" && evt.Source != "chat" {
			speaker = evt.Source
		}
		var ts int64
		if evt.Timestamp != nil && *evt.Timestamp > 0 {
			ts = *evt.Timestamp
		} else if evt.TriggeredAt != "" {
			if parsedT, err := time.Parse(time.RFC3339, evt.TriggeredAt); err == nil {
				ts = parsedT.UnixMilli()
			}
		}
		entry := HistoryEntry{
			Kind:      EntryUser,
			Speaker:   speaker,
			Text:      evt.Text,
			ClientID:  evt.ClientID,
			Timestamp: ts,
		}
		m.appendSettledEntry(entry)

	case daemon.EventText:
		m.ToolProgressText = ""
		m.Status.Running = true
		m.Status.Idle = false
		phase := daemon.PhaseReasoning
		m.Status.Phase = &phase

		if m.activeKind != StreamKindText {
			m.settleActiveStream()
			m.activeKind = StreamKindText
		}
		m.activeText += evt.Text
		m.streamedHash = fnv1a(m.streamedHash, evt.Text)
		m.streamedLen += int64(len(evt.Text))

		if len(m.activeText) > MaxLiveStreamBytes {
			m.settleActiveStream()
			m.activeKind = StreamKindText
		}

	case daemon.EventThinking:
		m.ToolProgressText = ""
		m.Status.Running = true
		m.Status.Idle = false
		phase := daemon.PhaseReasoning
		m.Status.Phase = &phase

		if m.activeKind != StreamKindThinking {
			m.settleActiveStream()
			m.activeKind = StreamKindThinking
		}
		m.activeText += evt.Text

		if len(m.activeText) > MaxLiveStreamBytes {
			m.settleActiveStream()
			m.activeKind = StreamKindThinking
		}

	case daemon.EventToolProgress:
		m.Progress = evt.Progress
		if evt.Progress != nil {
			m.settleActiveStream()
			m.Status.Running = true
			m.Status.Idle = false
			phase := daemon.PhaseTool
			m.Status.Phase = &phase
			m.ToolProgressText = progressLabel(*evt.Progress)
		} else {
			m.ToolProgressText = ""
		}

	case daemon.EventTool:
		m.settleActiveStream()
		m.ToolProgressText = ""
		m.Status.Running = true
		m.Status.Idle = false

		entry := HistoryEntry{
			Kind:       EntryTool,
			ToolName:   evt.ToolName,
			ToolArgs:   evt.ToolArgs,
			ToolResult: evt.ToolResult,
			ToolTrace:  evt.ToolTrace,
			Timestamp:  time.Now().UnixMilli(),
		}
		m.appendSettledEntry(entry)

	case daemon.EventMessage:
		m.ToolProgressText = ""

		targetHash := fnv1a(fnvOffset64, evt.Text)
		isDuplicate := (m.streamedLen == int64(len(evt.Text))) && (m.streamedHash == targetHash)
		m.streamedHash = fnvOffset64
		m.streamedLen = 0

		m.settleActiveStream()

		if isDuplicate {
			return
		}

		var ts int64
		if evt.Timestamp != nil && *evt.Timestamp > 0 {
			ts = *evt.Timestamp
		}
		entry := HistoryEntry{
			Kind:      EntryAssistant,
			Speaker:   m.AgentName,
			Text:      evt.Text,
			Timestamp: ts,
		}
		m.appendSettledEntry(entry)

	case daemon.EventNote:
		m.settleActiveStream()
		entry := HistoryEntry{
			Kind:      EntryNote,
			Text:      evt.Text,
			Timestamp: time.Now().UnixMilli(),
		}
		m.appendSettledEntry(entry)

	case daemon.EventError:
		m.TurnFailed = true
		m.settleActiveStream()
		m.ToolProgressText = ""
		m.Status.Running = false
		m.Status.Idle = true
		phase := daemon.PhaseResting
		m.Status.Phase = &phase

		entry := HistoryEntry{
			Kind:      EntryError,
			Text:      evt.Text,
			Timestamp: time.Now().UnixMilli(),
		}
		m.appendSettledEntry(entry)
		// The daemon ends errors that only a new sign-in can fix with "run /login".
		if m.sentHere && strings.HasSuffix(evt.Text, "run /login") {
			m.loginRequested = true
		}

	case daemon.EventCompacted:
		m.settleActiveStream()
		m.ToolProgressText = ""

		entry := HistoryEntry{
			Kind:      EntryCompacted,
			Text:      evt.Summary,
			Evicted:   evt.Evicted,
			Timestamp: time.Now().UnixMilli(),
		}
		m.appendSettledEntry(entry)

	case daemon.EventUsage:
		m.settleActiveStream()
		m.Usage = evt.Usage

	case daemon.EventInterrupted:
		m.Stopping = false
		m.Stopped = true
		m.TurnFailed = false
		m.settleActiveStream()
		m.ToolProgressText = ""
		m.Status.Running = false
		m.Status.Idle = true
		phase := daemon.PhaseResting
		m.Status.Phase = &phase

		entry := HistoryEntry{
			Kind:      EntryNote,
			Text:      "stopped by you",
			Timestamp: time.Now().UnixMilli(),
		}
		m.appendSettledEntry(entry)
	}
}

func formatUsage(u *daemon.Usage) string {
	if u == nil {
		return "—"
	}
	total := 0
	if u.TotalTokens != nil {
		total = *u.TotalTokens
	}
	rate := ""
	if u.TokensPerSecond != nil && *u.TokensPerSecond > 0 {
		rate = fmt.Sprintf(" · %.1f tok/s", *u.TokensPerSecond)
	}
	return fmt.Sprintf("%s tokens%s", formatTokens(total), rate)
}

func formatTokens(val int) string {
	if val >= 1_000_000 {
		return fmt.Sprintf("%.1fm", float64(val)/1_000_000.0)
	}
	if val >= 1_000 {
		return fmt.Sprintf("%.1fk", float64(val)/1_000.0)
	}
	return fmt.Sprintf("%d", val)
}

func (m ChatModel) padding() int {
	if m.Width >= 50 {
		return 2
	}
	return 1
}

func (m ChatModel) chatWidth() int { return max(1, m.Width-2*m.padding()) }
func (m ChatModel) sidebarWidth() int {
	for _, glance := range m.Glances {
		if len(glance.Rows) > 0 {
			margin := m.chatWidth() - min(100, m.chatWidth()) - 2
			if margin >= 16 {
				return min(32, margin)
			}
			break
		}
	}
	return 0
}

func progressLabel(progress daemon.ToolProgress) string {
	if intent := progress.Intent; intent != nil {
		verbs := map[string]string{"write": "writing", "edit": "editing", "read": "reading", "run": "running"}
		verb := verbs[intent.Kind]
		if intent.Kind == "run" && progress.Phase == "generating" {
			verb = "preparing"
		}
		return verb + " " + intent.Target
	}
	if progress.Phase == "generating" {
		return "making a " + progress.Name + " call"
	}
	return "running " + progress.Name
}

func (m ChatModel) renderProgress() string {
	if m.Progress == nil {
		return ""
	}
	width := m.Renderer.BodyWidth
	label := strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return ' '
		}
		return r
	}, m.ToolProgressText)
	codeWidth := 0
	if m.Progress.Phase == "generating" && m.Progress.Code != nil {
		labelWidth := min(ansi.StringWidth(label), max(0, (width-5)/2))
		codeWidth = max(0, width-2-labelWidth-3)
	}
	spinner := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}[m.ProgressFrame%10]
	prefix := spinner + " "
	if width < 2 {
		return "\x1b[36m" + spinner + "\x1b[0m"
	}
	label = ansi.Truncate(label, max(0, width-ansi.StringWidth(prefix)-max(0, codeWidth+3)), "…")
	line := "\x1b[36m" + prefix + "\x1b[0m\x1b[37m" + label + "\x1b[0m"
	if codeWidth > 0 {
		line += "\x1b[90m · \x1b[0m\x1b[37m" + ansi.Truncate(m.Progress.Code.Text, codeWidth, "…") + "\x1b[0m"
	}
	return line
}

func (m ChatModel) statusLine() string {
	if m.TurnFailed || m.ErrorNotice != "" || m.ExternalError != "" {
		return "turn failed · see error above"
	}
	if m.Stopping {
		return "stopping…"
	}
	if m.Stopped {
		return "stopped"
	}
	if m.isSending || len(m.pendingUsers) > 0 && !m.Status.Running {
		return "preparing"
	}
	if m.Progress != nil {
		if m.Progress.Phase == "generating" {
			return "generating call"
		}
		return "running " + m.Progress.Name
	}
	if m.Status.Running && !m.Status.Idle {
		if m.activeKind == StreamKindText {
			return "responding"
		}
		if m.Status.Phase != nil {
			switch *m.Status.Phase {
			case daemon.PhaseTool:
				return "running tool"
			case daemon.PhaseCompacting:
				return "compacting context"
			case daemon.PhasePreparing:
				return "preparing"
			}
		}
		return "thinking"
	}
	if m.Status.Phase == nil && m.Client != nil {
		return "connecting…"
	}
	if m.Status.Phase == nil {
		return "opening session…"
	}
	return "ready"
}

func truncateMiddle(text string, width int) string {
	if width <= 0 {
		return ""
	}
	runes := []rune(text)
	if len(runes) <= width {
		return text
	}
	if width == 1 {
		return "…"
	}
	left := (width - 1 + 1) / 2
	return string(runes[:left]) + "…" + string(runes[len(runes)-(width-1-left):])
}

func (m ChatModel) View() string {
	width := m.chatWidth()
	pad := strings.Repeat(" ", m.padding())
	var rows []string
	workspace := m.Workspace
	if workspace == "" {
		workspace = "chat"
	}
	model := m.Model
	var glance *PageGlance
	for i := range m.Glances {
		if len(m.Glances[i].Rows) > 0 {
			glance = &m.Glances[i]
			break
		}
	}
	right := model
	if glance != nil && width-100 < 26 {
		right = fmt.Sprintf("%s %d", glance.Title, len(glance.Rows)) + "  " + right
	}
	nameWidth := lipgloss.Width(m.AgentName)
	workspaceWidth := max(1, width-nameWidth-2-lipgloss.Width(right)-2)
	workspace = truncateMiddle(workspace, workspaceWidth)
	header := m.Styles.Bold.Render(m.AgentName) + "  " + m.Styles.Faint.Render(workspace)
	if right != "" {
		space := max(1, width-lipgloss.Width(header)-lipgloss.Width(right))
		header += strings.Repeat(" ", space) + m.Styles.Faint.Render(right)
	}
	rows = append(rows, header, "")
	errorNotice := m.ExternalError
	if m.ErrorNotice != "" {
		errorNotice = m.ErrorNotice
	}
	notice := m.ExternalNotice
	if m.Notice != "" {
		notice = m.Notice
	}
	if errorNotice != "" {
		rows = append(rows, m.Styles.Error.Render("error: "+errorNotice))
	} else if notice != "" {
		rows = append(rows, lipgloss.NewStyle().Foreground(lipgloss.Color("14")).Render(notice))
	}

	view := m.Viewport.View()
	if m.History.Len() == 0 && m.activeText == "" && m.ToolProgressText == "" {
		view = m.Styles.Faint.Render("what are we working on?")
	}
	if m.sidebarWidth() > 0 {
		view = lipgloss.JoinHorizontal(lipgloss.Top, view, "  ", m.renderGlances())
	}
	content := strings.Split(view, "\n")
	for len(content) < m.Viewport.Height {
		content = append(content, "")
	}
	content = content[:min(len(content), m.Viewport.Height)]
	if m.dragAnchor != nil {
		content = HighlightSelection(content, Selection{Anchor: *m.dragAnchor, Head: m.dragHead})
	}
	rows = append(rows, content...)
	pendingRows := min(3, len(m.pendingUsers))
	for i := 0; i < pendingRows; i++ {
		if i == 2 && len(m.pendingUsers) > 2 {
			rows = append(rows, m.Styles.ChatWarning.Render(fmt.Sprintf("+%d more pending", len(m.pendingUsers)-2)))
			break
		}
		label := "sending"
		if m.pendingUsers[i].Queued {
			label = fmt.Sprintf("queued %d", i+1)
		}
		rows = append(rows, m.Styles.ChatWarning.Render(label+" · "+strings.Join(strings.Fields(m.pendingUsers[i].Text), " ")))
	}
	status := m.statusLine()
	if m.Follow && m.animating() && m.Progress == nil && !m.TurnFailed && m.ErrorNotice == "" && m.ExternalError == "" {
		spinner := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}[m.ProgressFrame%10]
		status = spinner + " " + status
	}
	if !m.Follow {
		status = fmt.Sprintf("history · %d rows below · pgdn", max(0, len(m.settledLines)-m.scrollOffset-m.Viewport.Height))
	}
	if m.AttachedImage != nil {
		status = daemon.ImageLabel(m.AttachedImage.ImageMetadata) + " attached · esc remove"
	}
	if m.CopyStatus != "" {
		status = m.CopyStatus
	}
	if m.TurnFailed || m.ErrorNotice != "" || m.ExternalError != "" {
		rows = append(rows, m.Styles.Error.Render(status))
	} else {
		rows = append(rows, m.Styles.Faint.Render(status))
	}
	rows = append(rows, m.Styles.Faint.Render(strings.Repeat("─", width)))
	if m.WorkspaceRecovery != nil {
		rows = append(rows, m.Styles.ChatWarning.Render("workspace not found: "+m.WorkspaceRecovery.Missing), m.RecoveryInput.View())
		help := "enter confirms and retries · esc cancels"
		if m.WorkspaceRecovery.Saving {
			help = "updating workspace…"
		}
		if m.WorkspaceRecovery.Error != "" {
			help = m.WorkspaceRecovery.Error
		}
		if m.WorkspaceRecovery.Error != "" {
			rows = append(rows, m.Styles.Error.Render(help))
		} else {
			rows = append(rows, m.Styles.Faint.Render(help))
		}
	} else {
		rows = append(rows, m.composerView())
		if menu := m.CommandMenu.View(m.TextArea.Value()); menu != "" {
			rows = append(rows, strings.Split(strings.TrimSuffix(menu, "\n"), "\n")...)
		}
	}
	rows = append(rows, m.renderFooter())
	for i, row := range rows {
		rows[i] = pad + row
	}
	return strings.Join(rows, "\n")
}

func (m ChatModel) composerView() string {
	value := m.TextArea.Value()
	lines := strings.Split(value, "\n")
	cursor := 0
	for i := 0; i < min(m.TextArea.Line(), len(lines)); i++ {
		cursor += len([]rune(lines[i])) + 1
	}
	cursor += m.TextArea.LineInfo().StartColumn + m.TextArea.LineInfo().ColumnOffset
	shown := []rune(strings.ReplaceAll(value, "\n", " "))
	cursor = min(cursor, len(shown))
	columns := max(1, m.chatWidth()-2)
	first := max(0, cursor-columns+1)
	end := min(len(shown), first+columns)
	before := string(shown[first:cursor])
	block := " "
	if cursor < len(shown) {
		block = string(shown[cursor : cursor+1])
	}
	after := ""
	if cursor+1 < end {
		after = string(shown[cursor+1 : end])
	}
	return m.Styles.PromptBright.Render("› ") + before + lipgloss.NewStyle().Reverse(true).Render(block) + after
}

func (m ChatModel) renderGlances() string {
	for _, g := range m.Glances {
		if len(g.Rows) == 0 {
			continue
		}
		room := max(0, min(m.Viewport.Height, 12)-1)
		shown := min(room, len(g.Rows))
		if len(g.Rows) > room {
			shown = max(0, room-1)
		}
		rows := []string{m.Styles.Faint.Render(fmt.Sprintf("%s · %d", g.Title, len(g.Rows)))}
		for _, item := range g.Rows[:shown] {
			mark := "○"
			style := m.Styles.Faint
			switch item.Tone {
			case ToneActive:
				mark = "●"
				style = m.Styles.ChatSuccess
			case ToneWarning:
				mark = "!"
				style = m.Styles.ChatWarning
			case ToneMuted:
				mark = "✓"
			}
			rows = append(rows, style.Render(mark)+" "+item.Text)
		}
		if shown < len(g.Rows) {
			rows = append(rows, m.Styles.Faint.Render(fmt.Sprintf("+%d more", len(g.Rows)-shown)))
		}
		return lipgloss.NewStyle().Width(m.sidebarWidth()).Render(strings.Join(rows, "\n"))
	}
	return ""
}

func (m ChatModel) renderFooter() string {
	width := m.chatWidth()
	context, cache := "—", "—/—"
	usage := m.Usage
	if usage != nil && (usage.Model == "" || m.Model == "" || usage.Model == m.Model) {
		total := usage.TotalTokens
		if total == nil && usage.PromptTokens != nil {
			fallback := *usage.PromptTokens
			if usage.CompletionTokens != nil {
				fallback += *usage.CompletionTokens
			}
			total = &fallback
		}
		if total != nil && *total >= 0 {
			context = formatTokens(*total)
		}
		prompt, cached := "—", "—"
		if usage.PromptTokens != nil && *usage.PromptTokens >= 0 {
			prompt = formatGroupedCount(*usage.PromptTokens)
		}
		if usage.CachedPromptTokens != nil && *usage.CachedPromptTokens >= 0 {
			cached = formatGroupedCount(*usage.CachedPromptTokens)
		}
		cache = cached + "/" + prompt
	}
	modes := fmt.Sprintf("thinking %s · verbose %s", onOff(m.Flags.Thinking), onOff(m.Flags.Tools))
	brief := fmt.Sprintf("t:%s v:%s", onOff(m.Flags.Thinking), onOff(m.Flags.Tools))
	right := "ctx " + context + " · cached " + cache
	compact := context + " · " + cache
	candidates := [][2]string{
		{"/ commands · drag to copy · ctrl+j diffs · ctrl+k summary · " + modes, right},
		{"/ commands · drag to copy · ctrl+k summary · " + modes, right},
		{"/ commands · drag to copy · " + modes, right},
		{"/ commands · ctrl+j diffs · " + brief, compact},
		{"/ commands · drag copy · " + brief, compact},
		{"/ commands · " + brief, compact},
		{"/", compact},
	}
	for _, pair := range candidates {
		if lipgloss.Width(pair[0])+lipgloss.Width(pair[1]) < width {
			return m.Styles.Footer.Render(pair[0] + strings.Repeat(" ", width-lipgloss.Width(pair[0])-lipgloss.Width(pair[1])) + pair[1])
		}
	}
	return m.Styles.Footer.Render(string([]rune("/ commands")[:min(width, len([]rune("/ commands")))]))
}

func formatGroupedCount(count int) string {
	digits := strconv.Itoa(count)
	for i := len(digits) - 3; i > 0; i -= 3 {
		digits = digits[:i] + "," + digits[i:]
	}
	return digits
}

func onOff(enabled bool) string {
	if enabled {
		return "on"
	}
	return "off"
}
