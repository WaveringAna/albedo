package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"os/exec"
	"regexp"
	"slices"
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

// ChatEditorFinishedMsg is sent after the external editor process exits.
type ChatEditorFinishedMsg struct {
	SessionID  string
	Generation int64
	Path       string
	Err        error
}

// ChatOlderLoadedMsg carries a page of history from before what is shown.
type ChatOlderLoadedMsg struct {
	SessionID  string
	Generation int64
	Page       *daemon.HistoryPage
	Err        error
}
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

// ChatWindowMsg carries the context window for the model a usage event named.
type ChatWindowMsg struct {
	SessionID  string
	Generation int64
	Model      string
	Tokens     *int
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
	Continue   bool
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

func (s *WorkspaceRecoveryState) Rows() int {
	if s == nil {
		return 0
	}
	return 3 // missing warning, input field, and help/status
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
	At     int64
}

const (
	MaxLiveStreamBytes   = 64 * 1024
	MaxPendingUsers      = 10
	MaxSettledLines      = 1000
	MaxSettledLinesBytes = 256 * 1024
	// readingSlack multiplies the caps while you are scrolled up, so output
	// arriving as you read does not shrink the transcript above you.
	readingSlack = 8
	// olderPageRows is how many transcript rows a reset replays and each
	// older page adds; the daemon widens both back to a turn's start.
	olderPageRows = 120
	fnvOffset64   = 14695981039346656037
	fnvPrime64    = 1099511628211
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
	SessionID      string
	Generation     int64
	AgentName      string
	Workspace      string
	Model          string
	Effort         string
	Provider       string
	Client         *daemon.ChatClient
	History        *BoundedHistory
	Renderer       TranscriptRenderer
	Viewport       viewport.Model
	TextArea       textarea.Model
	CommandMenu    CommandMenuModel
	effortOptions  []string
	effortSelected int
	Flags          DisplayFlags
	Follow         bool
	TurnFailed     bool
	Stopping       bool
	Stopped        bool
	Status         daemon.AgentStatus
	Usage          *daemon.Usage
	// window is the context window of windowModel, read once per model so
	// the footer can say how full the context is.
	window      *int
	windowModel *string
	// stretch is the phase run the status face animates; moodSeed picks its
	// animation.
	stretch            stretch
	moodSeed           int64
	Glances            []PageGlance
	AttachedImage      *daemon.ImageAttachment
	Notices            Notices
	CopyStatus         string
	copyStatusRevision uint64
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
	// rebuilding defers trimming until a re-render has placed the reading position.
	rebuilding bool
	// olderBefore is the first transcript row the reset or the last older page
	// carried; olderMore says rows before it exist. loadingOlder is a fetch in flight.
	olderBefore  int64
	olderMore    bool
	loadingOlder bool

	scrollOffset int
	scrollLimit  int

	activeKind ActiveStreamKind
	activeText string

	streamedHash uint64
	streamedLen  int64

	pendingUsers      []PendingUserTurn
	isSending         bool
	interruptDeferred bool
	sentHere          bool

	WorkspaceRecovery *WorkspaceRecoveryState
	RecoveryInput     textinput.Model

	dragAnchor *Point
	dragHead   Point

	turn *openTurn
	// userRows are the settled rows where your messages start, and
	// settledOffset is how many notice rows sit above the settled rows.
	userRows      []int
	settledOffset int

	streamCtx    context.Context
	streamCancel context.CancelFunc
	eventChan    chan daemon.StreamEvent
}

func NewChatModel(session *daemon.Session, client *daemon.ChatClient) ChatModel {
	ta := textarea.New()
	ta.Placeholder = ""
	ta.Prompt = promptMark
	ta.CharLimit = 0
	ta.ShowLineNumbers = false
	ta.SetPromptFunc(promptMarkWidth, func(lineIdx int) string {
		if lineIdx == 0 {
			return promptMark
		}
		return strings.Repeat(" ", promptMarkWidth)
	})
	ta.KeyMap.InsertNewline.SetKeys("enter", "ctrl+m", "alt+enter", "shift+enter")
	ta.KeyMap.WordBackward.SetKeys("alt+left", "alt+b", "ctrl+left")
	ta.KeyMap.WordForward.SetKeys("alt+right", "alt+f", "ctrl+right")
	ta.SetHeight(6)
	ta.FocusedStyle.Prompt = DefaultStyles.Prompt
	ta.FocusedStyle.CursorLine = lipgloss.NewStyle()
	ta.FocusedStyle.Placeholder = DefaultStyles.Faint
	ta.BlurredStyle.Prompt = DefaultStyles.Prompt
	ta.BlurredStyle.CursorLine = lipgloss.NewStyle()
	ta.BlurredStyle.Placeholder = DefaultStyles.Faint
	ta.Cursor.Style = DefaultStyles.Cursor
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
		Effort:      session.Effort,
		Provider:    session.Provider,
		Client:      client,
		History:     bh,
		Renderer:    NewTranscriptRenderer(),
		Viewport:    vp,
		TextArea:    ta,
		CommandMenu: NewCommandMenuModel(),
		Flags: DisplayFlags{
			Thinking:   false,
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
	if client != nil {
		// A reset replays the newest rows; loadOlder pages back from there.
		client.Tail = olderPageRows
	}

	return m
}

func (m *ChatModel) Close() {
	if m.streamCancel != nil {
		m.streamCancel()
	}
}

func (m *ChatModel) syncViewportHeight() {
	if m == nil || m.History == nil || m.Height <= 0 {
		return
	}
	m.Viewport.Height = max(1, m.Height-6-m.chromeRows())
	m.refreshViewportContent()
}

func (m *ChatModel) AddNotice(message string) {
	if m.Notices.AddNotice(message) {
		m.syncViewportHeight()
	}
}

func (m *ChatModel) AddError(message string) {
	if m.Notices.AddError(message) {
		m.syncViewportHeight()
	}
}

func (m *ChatModel) ClearNotices() {
	if len(m.Notices) == 0 {
		return
	}
	m.Notices.Clear()
	m.syncViewportHeight()
}

// wordBackwardAtStart reports whether the prompt has no word before its cursor.
// The textarea's word-backward handler loops indefinitely in this case.
func (m ChatModel) wordBackwardAtStart() bool {
	lines := strings.Split(m.TextArea.Value(), "\n")
	row := m.TextArea.Line()
	if row < 0 || row >= len(lines) {
		return false
	}
	col := m.TextArea.LineInfo().StartColumn + m.TextArea.LineInfo().ColumnOffset
	current := []rune(lines[row])
	col = max(0, min(col, len(current)))
	for _, line := range lines[:row] {
		if strings.TrimSpace(line) != "" {
			return false
		}
	}
	return strings.TrimSpace(string(current[:col])) == ""
}

func (m ChatModel) promptLines() int {
	if m.WorkspaceRecovery != nil {
		return 0
	}
	lineCount := m.TextArea.LineCount()
	if lineCount <= 1 {
		return max(1, m.TextArea.LineInfo().Height)
	}
	cp := m.TextArea
	for cp.Line() > 0 {
		cp.CursorUp()
	}
	total := 0
	for line := 0; line < lineCount; line++ {
		total += cp.LineInfo().Height
		if line < lineCount-1 {
			curr := cp.Line()
			for cp.Line() == curr {
				beforeRow := cp.LineInfo().RowOffset
				cp.CursorDown()
				if cp.Line() == curr && cp.LineInfo().RowOffset == beforeRow {
					break
				}
			}
		}
	}
	return max(1, total)
}

func (m ChatModel) maxPromptHeight() int {
	maxHeight := 6
	if m.Height > 0 {
		maxHeight = max(1, min(6, (m.Height-8)/2))
	}
	return maxHeight
}

func (m ChatModel) promptHeight() int {
	if m.WorkspaceRecovery != nil {
		return 0
	}
	lines := m.promptLines()
	return min(lines, m.maxPromptHeight())
}

func (m ChatModel) inputRows() int {
	if m.WorkspaceRecovery != nil {
		return m.WorkspaceRecovery.Rows()
	}
	if len(m.effortOptions) > 0 {
		return 4 // breathing room, title, choices, keyboard hint; no composer
	}
	menu := min(4, len(m.CommandMenu.Matches(m.TextArea.Value())))
	return m.promptHeight() + menu
}

func (m ChatModel) chromeRows() int {
	return m.inputRows() + m.Notices.ChromeRows()
}

func (m *ChatModel) syncLayout() {
	m.TextArea.SetHeight(m.maxPromptHeight())
	m.Viewport.Height = max(1, m.Height-6-m.chromeRows())
	m.refreshViewportContent()
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
	transcriptWidth := available
	if m.sidebarWidth() > 0 {
		transcriptWidth -= m.sidebarWidth() + 2
	}

	m.Viewport.Width = transcriptWidth
	m.Renderer.BodyWidth = min(100, available)
	m.TextArea.SetWidth(available)
	m.TextArea.SetHeight(m.maxPromptHeight())
	m.RecoveryInput.Width = max(1, available-16)

	m.Viewport.Height = max(1, height-6-m.chromeRows())

	m.rebuildSettledLines()
	m.refreshViewportContent()
}

func (m *ChatModel) rebuildSettledLines() {
	// Re-rendering retained history must not move the reading position: it
	// keeps its distance from the end of the settled rows, and trimming waits
	// until it is placed.
	fromEnd := m.settledOffset + len(m.settledLines) - m.scrollOffset
	m.settledLines = nil
	m.settledLinesBytes = 0
	m.droppedSettledLines = 0
	m.userRows = nil
	m.rebuilding = true
	entries := m.History.Entries()
	for i := range entries {
		m.appendBlock(entries[:i], entries[i])
	}
	m.rebuilding = false
	m.settledOffset = len(m.headerLines())
	m.scrollOffset = max(0, m.settledOffset+len(m.settledLines)-fromEnd)
	m.trimSettledLines()
}

// headerLines lead the transcript: where older history stands. Their count
// only changes with what is loaded, and refreshViewportContent keeps the
// reading position steady when it does.
func (m ChatModel) headerLines() []string {
	indent := m.Renderer.rail(laneNone)
	switch {
	case m.loadingOlder:
		return []string{indent + m.Styles.Faint.Render("↑ loading earlier messages…"), ""}
	case m.hasOlder():
		return []string{indent + m.Styles.Faint.Render("↑ earlier messages load as you scroll up"), ""}
	}
	if notice := m.History.TruncationNotice(); notice != "" {
		return []string{indent + m.Styles.Warning.Render(notice), ""}
	}
	return nil
}

// hasOlder is whether scrolling past the top can show more: rows trimmed
// from the rendering, or transcript the daemon has not sent.
func (m ChatModel) hasOlder() bool {
	_, more := m.olderCursor()
	return m.droppedSettledLines > 0 || more
}

// olderCursor is the row the next older page ends before. Evicted entries
// move it forward: everything up to the newest evicted row is re-read.
func (m ChatModel) olderCursor() (int64, bool) {
	before, more := m.olderBefore, m.olderMore
	if through := m.History.EvictedThrough(); through > 0 && through >= before {
		before, more = through+1, true
	}
	return before, more && before > 0
}

// appendBlock renders entry after the settled entries before it.
func (m *ChatModel) appendBlock(before []HistoryEntry, entry HistoryEntry) {
	rows, head := m.Renderer.Block(before, entry, m.Flags)
	if entry.Kind == EntryUser {
		m.userRows = append(m.userRows, len(m.settledLines)+head)
	}
	for _, row := range rows {
		m.settledLines = append(m.settledLines, row)
		m.settledLinesBytes += int64(len(row))
	}
	m.trimSettledLines()
}

// trimSettledLines drops the oldest rows past the caps. While you are scrolled
// up the caps stretch by readingSlack and the row you are reading is never
// dropped, so output arriving meanwhile cannot push your place off the top;
// the normal caps apply again once the transcript follows its end.
func (m *ChatModel) trimSettledLines() {
	if m.rebuilding {
		return
	}
	maxLines, maxBytes := MaxSettledLines, int64(MaxSettledLinesBytes)
	if !m.Follow {
		maxLines, maxBytes = maxLines*readingSlack, maxBytes*readingSlack
	}
	dropped := 0
	for len(m.settledLines) > maxLines || m.settledLinesBytes > maxBytes {
		if len(m.settledLines) == 0 || !m.Follow && dropped >= m.scrollOffset-m.settledOffset {
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
		kept := m.userRows[:0]
		for _, row := range m.userRows {
			if row >= dropped {
				kept = append(kept, row-dropped)
			}
		}
		m.userRows = kept
		fresh := make([]string, len(m.settledLines))
		for i := range m.settledLines {
			fresh[i] = strings.Clone(m.settledLines[i])
			m.settledLines[i] = ""
		}
		m.settledLines = fresh
	}
}

func (m *ChatModel) appendSettledEntry(entry HistoryEntry) {
	before := m.History.Entries()
	m.appendBlock(before, entry)
	m.History.Append(entry)
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

func (m *ChatModel) streamDelta(kind ActiveStreamKind, text string) {
	if text == "" {
		return
	}
	m.turnIsLive()
	m.ToolProgressText = ""
	m.Status.Running = true
	m.Status.Idle = false
	phase := daemon.PhaseReasoning
	m.Status.Phase = &phase

	if m.activeKind != kind {
		m.settleActiveStream()
		m.activeKind = kind
	}
	m.activeText += text
	if kind == StreamKindText {
		m.streamedHash = fnv1a(m.streamedHash, text)
		m.streamedLen += int64(len(text))
	}

	if len(m.activeText) > MaxLiveStreamBytes {
		m.settleActiveStream()
		m.activeKind = kind
	}
}

func (m *ChatModel) refreshViewportContent() int {
	if m.Viewport.Height != max(1, m.Height-6-m.chromeRows()) {
		m.SetSize(m.Width, m.Height)
		return m.scrollLimit
	}
	allLines := m.headerLines()
	if !m.Follow {
		// a header growing or shrinking above must not move what you read
		m.scrollOffset = max(0, m.scrollOffset+len(allLines)-m.settledOffset)
	}
	m.settledOffset = len(allLines)
	allLines = append(allLines, m.settledLines...)

	last, stacks := laneNone, false
	if entries := m.History.Entries(); len(entries) > 0 {
		last = laneOf(entries[len(entries)-1])
		stacks = Compact(entries[len(entries)-1], m.Flags)
	}
	if m.activeKind != StreamKindNone && m.activeText != "" {
		var kind EntryKind = EntryAssistant
		if m.activeKind == StreamKindThinking {
			kind = EntryThinking
		}
		activeEntry := HistoryEntry{Kind: kind, Speaker: m.AgentName, Text: m.activeText}
		rows, _ := m.Renderer.Block(m.History.Entries(), activeEntry, m.Flags)
		allLines = append(allLines, rows...)
		last, stacks = laneOf(activeEntry), false
	}

	if m.ToolProgressText != "" {
		// the live row stacks under tool rows like the row it settles into
		if len(allLines) > 0 && !stacks {
			allLines = append(allLines, strings.TrimRight(m.Renderer.rail(joint(last, laneBusy)), " "))
		}
		allLines = append(allLines, m.Renderer.rail(laneBusy)+m.renderProgress())
	}
	allLines = append(allLines, m.pendingRows()...)

	totalLines := len(allLines)
	vpHeight := max(1, m.Viewport.Height)
	maxScroll := max(0, totalLines-vpHeight)
	m.scrollLimit = maxScroll

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
	return maxScroll
}

// pendingRows are your messages the daemon has not echoed yet, greyed out at
// the end of the transcript where they will settle. Each follows whatever is
// live above it, so the rails and names join up as they will once settled.
func (m ChatModel) pendingRows() []string {
	if len(m.pendingUsers) == 0 {
		return nil
	}
	before := slices.Clone(m.History.Entries())
	if m.activeKind != StreamKindNone && m.activeText != "" {
		before = append(before, HistoryEntry{Kind: EntryAssistant, Speaker: m.AgentName})
	}
	if m.ToolProgressText != "" {
		before = append(before, HistoryEntry{Kind: EntryTool, Speaker: m.AgentName})
	}
	var rows []string
	for _, p := range m.pendingUsers {
		state := sending
		if p.Queued {
			state = queued
		}
		entry := HistoryEntry{Kind: EntryUser, Speaker: "You", Text: p.Text, Timestamp: p.At, Pending: state}
		block, _ := m.Renderer.Block(before, entry, m.Flags)
		rows = append(rows, block...)
		before = append(before, entry)
	}
	return rows
}

// jumpToYou scrolls to the start of your previous or next message. Past
// your newest message it follows the live transcript again.
func (m *ChatModel) jumpToYou(back bool) {
	at := m.scrollOffset
	if m.Follow {
		at = m.scrollLimit
	}
	target := -1
	for _, row := range m.userRows {
		row += m.settledOffset
		if back && row < at {
			target = row
		}
		if !back && row > at {
			target = row
			break
		}
	}
	switch {
	case target >= 0 && target < m.scrollLimit:
		m.Follow = false
		m.scrollOffset = target
	case !back || target >= 0:
		m.Follow = true
	}
	m.refreshViewportContent()
}

// scrollBy moves through the complete rendered transcript, including live output.
func (m *ChatModel) scrollBy(rows int) {
	if rows < 0 {
		m.Follow = false
	} else if m.Follow {
		return
	}
	m.scrollOffset = max(0, m.scrollOffset+rows)
	maxScroll := m.refreshViewportContent()
	if rows > 0 && m.scrollOffset >= maxScroll {
		m.Follow = true
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

// windowCmd reads the context window when usage names a model whose window
// has not been read yet.
func (m ChatModel) windowCmd() tea.Cmd {
	if m.Client == nil || m.Usage == nil || m.windowModel != nil && *m.windowModel == m.Usage.Model {
		return nil
	}
	client, ctx, id, generation, model := m.Client, m.streamCtx, m.SessionID, m.Generation, m.Usage.Model
	return func() tea.Msg {
		tokens, err := client.ContextWindow(ctx)
		return ChatWindowMsg{SessionID: id, Generation: generation, Model: model, Tokens: tokens, Err: err}
	}
}

func (m ChatModel) statusPollCmd() tea.Cmd {
	id, generation := m.SessionID, m.Generation
	return tea.Tick(750*time.Millisecond, func(time.Time) tea.Msg { return ChatStatusPollMsg{SessionID: id, Generation: generation} })
}

func (m ChatModel) Init() tea.Cmd {
	return tea.Batch(m.startStreamSubscription(), m.statusCmd())
}

// Update handles msg, then fetches older history when it left you at the top.
func (m ChatModel) Update(msg tea.Msg) (ChatModel, tea.Cmd) {
	if loaded, ok := msg.(ChatOlderLoadedMsg); ok {
		return m.showOlder(loaded), nil
	}
	m, cmd := m.update(msg)
	if older := m.loadOlder(); older != nil {
		return m, tea.Batch(cmd, older)
	}
	return m, cmd
}

// loadOlder runs when you are scrolled to the top of the transcript: rows
// trimmed from the rendering come back from retained history first, then a
// page is asked of the daemon.
func (m *ChatModel) loadOlder() tea.Cmd {
	if m.Follow || m.scrollOffset > 0 || m.loadingOlder {
		return nil
	}
	if m.droppedSettledLines > 0 {
		m.rebuildSettledLines()
		m.refreshViewportContent()
		return nil
	}
	before, more := m.olderCursor()
	if !more || m.Client == nil {
		return nil
	}
	m.loadingOlder = true
	m.refreshViewportContent()
	client, id, generation := m.Client, m.SessionID, m.Generation
	return func() tea.Msg {
		page, err := client.History(context.Background(), before, olderPageRows)
		return ChatOlderLoadedMsg{SessionID: id, Generation: generation, Page: page, Err: err}
	}
}

// showOlder puts a fetched page above what is shown without moving it.
func (m *ChatModel) showOlder(msg ChatOlderLoadedMsg) ChatModel {
	if msg.SessionID != m.SessionID || msg.Generation != m.Generation || !m.loadingOlder {
		return *m
	}
	m.loadingOlder = false
	if msg.Err != nil {
		m.AddError(fmt.Sprintf("could not load earlier messages: %v", msg.Err))
		return *m
	}
	// The page renders exactly as a reset would, in a scratch transcript.
	scratch := NewChatModel(&daemon.Session{ID: m.SessionID}, nil)
	scratch.AgentName = m.AgentName
	scratch.History = NewBoundedHistory(1<<30, 1<<40)
	for _, evt := range msg.Page.Events {
		scratch.handleStreamEvent(evt)
	}
	scratch.settleActiveStream()
	m.History.Prepend(scratch.History.Entries())
	m.olderBefore, m.olderMore = msg.Page.Before, msg.Page.More && msg.Page.Before > 0
	m.rebuildSettledLines()
	m.refreshViewportContent()
	return *m
}

func (m ChatModel) update(msg tea.Msg) (ChatModel, tea.Cmd) {
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

		// The selector owns keys while open, before chat navigation or composer input.
		if len(m.effortOptions) > 0 {
			switch msg.Type {
			case tea.KeyLeft, tea.KeyUp:
				m.effortSelected = max(0, m.effortSelected-1)
			case tea.KeyRight, tea.KeyDown:
				m.effortSelected = min(len(m.effortOptions)-1, m.effortSelected+1)
			case tea.KeyEnter:
				level := m.effortOptions[m.effortSelected]
				m.effortOptions = nil
				m.syncLayout()
				return m, func() tea.Msg { return ChatExecuteCommandMsg{Name: "/effort", Args: level} }
			case tea.KeyEsc:
				m.effortOptions = nil
				m.syncLayout()
			case tea.KeyCtrlC:
				if m.streamCancel != nil {
					m.streamCancel()
				}
				return m, func() tea.Msg { return ChatQuitMsg{} }
			}
			return m, nil
		}

		if msg.Type == tea.KeyLeft && m.TextArea.Value() == "" {
			return m, func() tea.Msg { return ChatBackToSessionsMsg{} }
		}

		if msg.Type == tea.KeyCtrlC || (msg.Type == tea.KeyCtrlD && m.TextArea.Focused() && m.TextArea.Value() == "") {
			if m.streamCancel != nil {
				m.streamCancel()
			}
			return m, func() tea.Msg { return ChatQuitMsg{} }
		}
		if msg.Type == tea.KeyCtrlN {
			return m, func() tea.Msg { return ChatNewSessionMsg{} }
		}
		if msg.Type == tea.KeyCtrlO {
			return m, func() tea.Msg { return ChatOpenAgentsMsg{} }
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
			m.syncLayout()
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
		if msg.Type == tea.KeyCtrlG {
			return m, m.openEditorCmd()
		}

		if msg.Type == tea.KeyPgUp {
			m.scrollBy(-m.Viewport.Height)
			return m, nil
		}
		if msg.Type == tea.KeyPgDown {
			m.scrollBy(m.Viewport.Height)
			return m, nil
		}
		if msg.Type == tea.KeyUp && m.TextArea.Line() == 0 && m.TextArea.LineInfo().RowOffset == 0 {
			m.scrollBy(-1)
			return m, nil
		}
		if msg.Type == tea.KeyDown && m.TextArea.Line() >= m.TextArea.LineCount()-1 && m.TextArea.LineInfo().RowOffset >= m.TextArea.LineInfo().Height-1 {
			m.scrollBy(1)
			return m, nil
		}
		if msg.Type == tea.KeyShiftUp || msg.Type == tea.KeyShiftDown {
			m.jumpToYou(msg.Type == tea.KeyShiftUp)
			return m, nil
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

		// Bubbles wordLeft never terminates when everything before the cursor
		// is whitespace. Move to the input start directly in that case.
		if msg.Type == tea.KeyCtrlLeft && m.wordBackwardAtStart() {
			var cmd tea.Cmd
			m.TextArea, cmd = m.TextArea.Update(tea.KeyMsg{Type: tea.KeyCtrlHome})
			return m, cmd
		}

		if msg.Type == tea.KeyEnter && !msg.Alt {
			trimmed := strings.TrimSpace(m.TextArea.Value())
			if trimmed != "" {
				m.TextArea.Reset()
				m.syncLayout()
				m.submitInput(trimmed, &cmds)
				return m, tea.Batch(cmds...)
			}
			return m, nil
		}

	case tea.MouseMsg:
		firstRow := 2 + m.Notices.ChromeRows()
		point := func() Point {
			return Point{Row: max(0, min(m.Viewport.Height-1, msg.Y-firstRow)), Col: max(0, min(m.Viewport.Width, msg.X-m.padding()))}
		}
		if msg.Action == tea.MouseActionRelease && m.dragAnchor != nil {
			m.dragHead = point()
			sel := Selection{Anchor: *m.dragAnchor, Head: m.dragHead, Gutter: railWidth}
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
			m.scrollBy(-3)
			return m, nil
		case tea.MouseButtonWheelDown:
			m.scrollBy(3)
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
			m.AddError(fmt.Sprintf("image paste failed: %v", msg.Err))
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
			defer m.reseedMood()
			if !m.Status.Running || m.Status.Idle {
				m.Progress = nil
				m.ToolProgressText = ""
				m.settleActiveStream()
				if m.turn != nil && m.turn.begun() {
					m.closeTurn(false)
				}
				m.refreshViewportContent()
			}
		}
		return m, tea.Batch(m.startAnimation(), m.statusPollCmd())

	case ChatStreamEventMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		// only a live event outdates a status reply in flight
		if !msg.Event.Replayed {
			m.statusRevision++
		}
		m.handleStreamEvent(msg.Event)
		m.refreshViewportContent()

		return m, tea.Batch(m.waitForNextEvent(), m.startAnimation(), m.windowCmd())

	case ChatWindowMsg:
		if msg.SessionID == m.SessionID && msg.Generation == m.Generation && msg.Err == nil {
			m.window, m.windowModel = msg.Tokens, &msg.Model
		}
		return m, nil

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
				if !msg.Continue {
					if len(m.pendingUsers) > 0 {
						m.pendingUsers = m.pendingUsers[1:]
					}
					if m.TextArea.Value() == "" {
						m.TextArea.SetValue(msg.Prompt)
					}
				}
				if m.AttachedImage == nil && msg.Image != nil {
					m.AttachedImage = msg.Image
				}
				ti := textinput.New()
				ti.SetValue(wsErr.Workspace)
				ti.Focus()
				ti.Prompt = "new workspace › "
				ti.PromptStyle = m.Styles.Prompt
				ti.Cursor.Style = DefaultStyles.Cursor
				ti.Cursor.SetMode(cursor.CursorStatic)
				m.RecoveryInput = ti
				recoveryPrompt := msg.Prompt
				if msg.Continue {
					recoveryPrompt = ""
				}
				m.WorkspaceRecovery = &WorkspaceRecoveryState{
					Missing:     wsErr.Workspace,
					Replacement: wsErr.Workspace,
					Prompt:      recoveryPrompt,
					Image:       msg.Image,
				}
				m.refreshViewportContent()
				return m, nil
			}

			m.AddError(fmt.Sprintf("send failed: %v", msg.Err))
			if msg.Queued {
				m.appendSettledEntry(HistoryEntry{Kind: EntryError, Text: "message not queued: " + msg.Err.Error()})
			} else {
				m.appendSettledEntry(HistoryEntry{Kind: EntryError, Text: msg.Err.Error()})
			}
			if !msg.Continue {
				if m.TextArea.Value() == "" {
					m.TextArea.SetValue(msg.Prompt)
				}
				if len(m.pendingUsers) > 0 {
					m.pendingUsers = m.pendingUsers[1:]
				}
			}
			if m.AttachedImage == nil && msg.Image != nil {
				m.AttachedImage = msg.Image
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
		m.syncLayout()
		m.submitInput(prompt, &cmds)
		return m, tea.Batch(cmds...)

	case ChatEditorFinishedMsg:
		if msg.Path != "" {
			defer os.Remove(msg.Path)
		}
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, tea.EnableMouseCellMotion
		}
		if msg.Err != nil {
			m.AddError("editor error: " + msg.Err.Error())
			return m, tea.EnableMouseCellMotion
		}
		data, err := os.ReadFile(msg.Path)
		if err != nil {
			m.AddError("could not read edited prompt: " + err.Error())
			return m, tea.EnableMouseCellMotion
		}
		m.TextArea.SetValue(strings.TrimRight(string(data), "\r\n"))
		m.syncLayout()
		return m, tea.EnableMouseCellMotion

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
	menuMatches := m.CommandMenu.Matches(m.TextArea.Value())
	oldMenuRows := min(4, len(menuMatches))
	oldPromptHeight := m.promptHeight()
	m.TextArea, taCmd = m.TextArea.Update(msg)
	newMatches := m.CommandMenu.Matches(m.TextArea.Value())
	newMenuRows := min(4, len(newMatches))
	newPromptHeight := m.promptHeight()
	if newMenuRows != oldMenuRows || newPromptHeight != oldPromptHeight {
		m.syncLayout()
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

func (m ChatModel) openEditorCmd() tea.Cmd {
	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = os.Getenv("VISUAL")
	}
	if editor == "" {
		editor = "nano"
	}
	args := strings.Fields(editor)
	if len(args) == 0 {
		args = []string{"nano"}
	}

	tmpFile, err := os.CreateTemp("", "albedo-prompt-*.md")
	if err != nil {
		sessID := m.SessionID
		gen := m.Generation
		return func() tea.Msg {
			return ChatEditorFinishedMsg{
				SessionID:  sessID,
				Generation: gen,
				Err:        fmt.Errorf("could not create temporary file: %w", err),
			}
		}
	}

	if _, err := tmpFile.WriteString(m.TextArea.Value()); err != nil {
		tmpFile.Close()
		os.Remove(tmpFile.Name())
		sessID := m.SessionID
		gen := m.Generation
		return func() tea.Msg {
			return ChatEditorFinishedMsg{
				SessionID:  sessID,
				Generation: gen,
				Err:        fmt.Errorf("could not write to temporary file: %w", err),
			}
		}
	}
	tmpFile.Close()

	cmdArgs := append(args[1:], tmpFile.Name())
	c := exec.Command(args[0], cmdArgs...)

	sessID := m.SessionID
	gen := m.Generation
	path := tmpFile.Name()

	return tea.ExecProcess(c, func(err error) tea.Msg {
		return ChatEditorFinishedMsg{
			SessionID:  sessID,
			Generation: gen,
			Path:       path,
			Err:        err,
		}
	})
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

func (m *ChatModel) sendContinueCmd() tea.Cmd {
	client := m.Client
	sessID := m.SessionID
	gen := m.Generation

	return func() tea.Msg {
		if client == nil {
			return ChatTurnSentMsg{SessionID: sessID, Generation: gen, Prompt: ".", Continue: true, Err: fmt.Errorf("no client available")}
		}
		res, err := client.Continue(context.Background())
		if err != nil {
			return ChatTurnSentMsg{SessionID: sessID, Generation: gen, Prompt: ".", Continue: true, Err: err}
		}
		return ChatTurnSentMsg{SessionID: sessID, Generation: gen, Prompt: ".", Continue: true, OK: res.OK, Queued: res.Queued}
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
		"/status", "/login", "/mouse", "/skills", "/instructions", "/mcp":
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

	if input == "." {
		if len(m.pendingUsers) >= MaxPendingUsers {
			m.AddError("too many pending turns; wait for current turn to complete")
			m.refreshViewportContent()
			return
		}

		m.ClearNotices()
		m.isSending = true
		m.reseedMood()
		m.sentHere = true
		m.Follow = true
		m.refreshViewportContent()

		*cmds = append(*cmds, m.sendContinueCmd(), m.startAnimation())
		return
	}

	if len(m.pendingUsers) >= MaxPendingUsers {
		m.AddError("too many pending turns; wait for current turn to complete")
		m.refreshViewportContent()
		return
	}

	m.ClearNotices()

	img := m.AttachedImage
	m.AttachedImage = nil
	m.pendingUsers = append(m.pendingUsers, PendingUserTurn{
		Text:  input,
		Image: img,
		At:    time.Now().UnixMilli(),
	})
	m.isSending = true
	m.reseedMood()
	m.sentHere = true
	m.Follow = true
	m.refreshViewportContent()

	*cmds = append(*cmds, m.sendTurnCmd(input, img), m.startAnimation())
}

func (m *ChatModel) handleSubmittedCommand(input string, cmds *[]tea.Cmd) {
	m.TextArea.Reset()
	m.syncLayout()
	trimmed := strings.TrimSpace(input)

	switch {
	case trimmed == "/agents":
		*cmds = append(*cmds, func() tea.Msg { return ChatOpenAgentsMsg{} })
	case trimmed == "/a" || trimmed == "/sessions":
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
		if m.Effort != "" {
			statusText += fmt.Sprintf("\neffort: %s", m.Effort)
		}
		if m.Usage != nil {
			statusText += fmt.Sprintf("\ntokens: %s", formatUsage(m.Usage))
		}
		m.appendSettledEntry(HistoryEntry{
			Kind: EntryNote,
			Text: statusText,
		})
		m.refreshViewportContent()
	case trimmed == "/skills" || trimmed == "/instructions" || trimmed == "/mcp":
		kind := strings.TrimPrefix(trimmed, "/")
		*cmds = append(*cmds, func() tea.Msg { return ChatOpenCapabilityPageMsg{Kind: kind} })
	case trimmed == "/webhooks":
		*cmds = append(*cmds, func() tea.Msg { return ChatOpenWebhooksPageMsg{} })
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
	defer m.reseedMood()
	if evt.Replayed {
		// the snapshot rebuilds the transcript; whether albedo is working
		// now is for /status to say, so reopening a session never flashes
		// the phase its last turn ended in
		defer func(live daemon.AgentStatus) { m.Status = live }(m.Status)
	}
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
		m.ClearNotices()
		m.TurnFailed = false
		m.Stopping = false
		m.Stopped = false
		m.Follow = true
		m.scrollOffset = 0
		m.pendingUsers = nil
		m.turn = nil
		m.olderBefore, m.olderMore, m.loadingOlder = evt.Before, evt.More, false

	case daemon.EventCommitted:
		m.History.Stamp(evt.Seq)

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
		if !evt.Replayed {
			m.ClearNotices()
		}

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
		// Your message starts a turn and closes the one before it. Another
		// source only opens a turn when none is in flight.
		opens := m.turn == nil || speaker == "You"
		if opens {
			m.closeTurn(false)
		}
		m.appendSettledEntry(entry)
		if opens {
			if ts == 0 {
				ts = time.Now().UnixMilli()
			}
			m.turn = &openTurn{start: ts, last: ts}
		}

	case daemon.EventText:
		m.streamDelta(StreamKindText, evt.Text)

	case daemon.EventThinking:
		m.streamDelta(StreamKindThinking, evt.Text)

	case daemon.EventToolProgress:
		m.turnIsLive()
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
		if m.turn == nil {
			ts := time.Now().UnixMilli()
			m.turn = &openTurn{start: ts, last: ts}
		}
		m.turn.tools++
		m.turn.touch(evt.Timestamp)

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
		if m.turn == nil {
			start := ts
			if start == 0 {
				start = time.Now().UnixMilli()
			}
			m.turn = &openTurn{start: start, last: start}
		}
		m.turn.touch(evt.Timestamp)

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
		if m.turn != nil {
			m.turn.failed = true
			m.closeTurn(false)
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

		if m.turn != nil {
			m.closeTurn(true)
			return
		}
		m.appendSettledEntry(HistoryEntry{
			Kind:      EntryNote,
			Text:      "stopped by you",
			Timestamp: time.Now().UnixMilli(),
		})
	}
}

// openTurn follows the turn in flight until its signoff.
type openTurn struct {
	// start and last are daemon timestamps in milliseconds.
	start, last int64
	tools       int
	// live marks a turn streamed to this client, which ends now rather
	// than at its last replayed event.
	live   bool
	failed bool
}

func (t *openTurn) touch(ts *int64) {
	if ts != nil && *ts > t.last {
		t.last = *ts
	}
}

// begun reports whether the turn has done anything, so an idle status
// that races its first event cannot sign it off early.
func (t *openTurn) begun() bool {
	return t.live || t.tools > 0 || t.last > t.start
}

func (m *ChatModel) turnIsLive() {
	if m.turn == nil {
		ts := time.Now().UnixMilli()
		m.turn = &openTurn{start: ts, last: ts}
	}
	m.turn.live = true
}

// stretch is one run of a phase: a thinking or replying spell, or one tool
// call, which keeps a single animation from start to end.
type stretch struct {
	mood mood
	call string
}

// reseedMood draws a new animation when a new stretch starts, at random, so
// the same one may well come up twice.
func (m *ChatModel) reseedMood() {
	now := stretch{mood: m.phaseMood()}
	if m.Progress != nil {
		now.call = m.Progress.CallID
	}
	if now != m.stretch {
		m.stretch, m.moodSeed = now, rand.Int64()
	}
}

// closeTurn signs off the turn in flight, if there is one.
func (m *ChatModel) closeTurn(stopped bool) {
	t := m.turn
	if t == nil {
		return
	}
	m.turn = nil
	end := t.last
	if t.live {
		end = max(end, time.Now().UnixMilli())
	}
	elapsed := end - t.start
	m.appendSettledEntry(HistoryEntry{
		Kind:      EntryTurnEnd,
		Mood:      outcome(t.failed, stopped, elapsed),
		ElapsedMs: elapsed,
		Tools:     t.tools,
		Timestamp: end,
	})
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

// renderProgress is the live row for the tool call in flight. It is shaped
// like the tool row it settles into, and code being written shows its
// newest end.
func (m ChatModel) renderProgress() string {
	if m.Progress == nil {
		return ""
	}
	width := max(1, m.Renderer.BodyWidth-railWidth)
	row := oneLine(m.ToolProgressText)
	if code := m.Progress.Code; m.Progress.Phase == "generating" && code != nil {
		if text := oneLine(code.Text); text != "" {
			row += " · "
			if room := width - ansi.StringWidth(row); room >= 12 && ansi.StringWidth(text) > room {
				text = ansi.TruncateLeft(text, ansi.StringWidth(text)-room+1, "…")
			}
			row += text
		}
	}
	return m.Styles.Faint.Render(ansi.Truncate(row, width, "…"))
}

func (m ChatModel) statusLine() string {
	if m.TurnFailed || m.Notices.HasError() {
		return "turn failed · see error above"
	}
	if m.Stopping {
		return "stopping…"
	}
	// an idle session says nothing unless verbose: the transcript already
	// ends in the turn's signoff.
	if m.Stopped {
		return m.verbose("stopped")
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
	return m.verbose("ready")
}

func (m ChatModel) verbose(status string) string {
	if m.Flags.Tools {
		return status
	}
	return ""
}

// phaseMood is the face class for the phase statusLine names.
func (m ChatModel) phaseMood() mood {
	switch {
	case m.Stopping:
		return moodStopping
	case m.isSending || len(m.pendingUsers) > 0 && !m.Status.Running:
		return moodPreparing
	case m.Progress != nil:
		return moodWorking
	case m.activeKind == StreamKindText:
		return moodResponding
	case m.Status.Phase != nil && *m.Status.Phase == daemon.PhaseTool:
		return moodWorking
	case m.Status.Phase != nil && *m.Status.Phase == daemon.PhaseCompacting:
		return moodCompacting
	case m.Status.Phase != nil && *m.Status.Phase == daemon.PhasePreparing:
		return moodPreparing
	}
	return moodThinking
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
	if m.Effort != "" {
		model = fmt.Sprintf("%s:%s", m.Model, m.Effort)
	}
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
	room := width - lipgloss.Width("✦ "+m.AgentName+" on ") - lipgloss.Width(right) - 5
	header := titleRule(width, located(m.AgentName, truncateMiddle(homePath(workspace), max(1, room))), m.Styles.Faint.Render(right))
	rows = append(rows, header, "")
	for _, n := range m.Notices {
		if n.Error {
			rows = append(rows, m.Renderer.errorRow(n.Message))
		} else {
			rows = append(rows, m.Styles.Faint.Render(n.Message))
		}
	}
	if len(m.Notices) > 0 {
		rows = append(rows, "")
	}

	view := m.Viewport.View()
	if m.History.Len() == 0 && m.activeText == "" && m.ToolProgressText == "" {
		view = m.Renderer.rail(laneNone) + m.Styles.Faint.Render("what are we working on?")
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
		content = HighlightSelection(content, Selection{Anchor: *m.dragAnchor, Head: m.dragHead, Gutter: railWidth})
	}
	rows = append(rows, content...)
	status := m.statusLine()
	// the face trails the text, so its frames never move anything
	if m.animating() && !m.TurnFailed && !m.Notices.HasError() {
		status = m.Styles.Faint.Render(status) + " " + m.Styles.Agent.Render(m.phaseMood().frame(m.moodSeed, m.ProgressFrame))
	}
	if !m.Follow && m.Flags.Tools {
		status = fmt.Sprintf("history · %d rows below · pgdn", max(0, m.scrollLimit-m.scrollOffset))
	}
	if m.AttachedImage != nil {
		status = daemon.ImageLabel(m.AttachedImage.ImageMetadata) + " attached · esc remove"
	}
	if m.CopyStatus != "" {
		status = m.CopyStatus
	}
	if m.TurnFailed || m.Notices.HasError() {
		rows = append(rows, m.Styles.Error.Render(status))
	} else {
		rows = append(rows, m.Styles.Faint.Render(status))
	}
	rows = append(rows, m.Styles.Decor.Render(strings.Repeat("─", width)))
	if m.WorkspaceRecovery != nil {
		rows = append(rows, m.Styles.Warning.Render("workspace not found: "+m.WorkspaceRecovery.Missing), m.RecoveryInput.View())
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
	} else if len(m.effortOptions) > 0 {
		rows = append(rows, "", m.Styles.Bold.Render(ansi.Truncate("Reasoning effort", width, "")), m.effortSelectorView(), m.Styles.Faint.Render(ansi.Truncate("← → choose  ·  enter apply  ·  esc cancel", width, "")))
	} else {
		rows = append(rows, strings.Split(strings.TrimSuffix(m.composerView(), "\n"), "\n")...)
		if menu := m.CommandMenu.View(m.TextArea.Value()); menu != "" {
			rows = append(rows, strings.Split(strings.TrimSuffix(menu, "\n"), "\n")...)
		}
	}
	rows = append(rows, m.Styles.Decor.Render(strings.Repeat("─", width)))
	rows = append(rows, m.renderFooter())
	for i, row := range rows {
		rows[i] = pad + row
	}
	return strings.Join(rows, "\n")
}

func (m ChatModel) composerView() string {
	ta := m.TextArea
	if m.waitingForInput() && ta.Value() == "" {
		ta.Placeholder = "ctrl+g editor"
	} else {
		ta.Placeholder = ""
	}
	lines := strings.Split(ta.View(), "\n")
	h := m.promptHeight()
	if h < len(lines) {
		lines = lines[:h]
	}
	return strings.Join(lines, "\n")
}

// waitingForInput reports an opened session with no turn in flight, so an
// empty composer reads as the agent's cue rather than a stalled turn.
func (m ChatModel) waitingForInput() bool {
	return m.Status.Phase != nil && !m.animating() && m.WorkspaceRecovery == nil
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
				style = m.Styles.Success
			case ToneWarning:
				mark = "!"
				style = m.Styles.Warning
			case ToneMuted:
				mark = "✓"
			}
			label := item.Text
			if item.ID != "" {
				label = "#" + item.ID + " " + label
			}
			rows = append(rows, style.Render(mark)+" "+label)
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
	right, compact := m.contextStat()
	commands := hint{"/", "commands"}
	candidates := []struct {
		left  []hint
		right string
	}{
		{[]hint{commands, {"shift+↑↓", "turns"}, {"drag", "copy"}, {"ctrl+j", "diffs"}, {"ctrl+o", "agents"}}, right},
		{[]hint{commands, {"drag", "copy"}, {"ctrl+j", "diffs"}, {"ctrl+o", "agents"}}, right},
		{[]hint{commands, {"ctrl+j", "diffs"}, {"ctrl+o", "agents"}}, right},
		{[]hint{commands, {"drag", "copy"}}, right},
		{[]hint{commands, {"ctrl+o", "agents"}}, compact},
		{[]hint{commands, {"ctrl+j", "diffs"}}, compact},
		{[]hint{commands}, compact},
		{[]hint{{"/", ""}}, compact},
	}
	for _, c := range candidates {
		left := keyHints(c.left...)
		if gap := width - lipgloss.Width(left) - lipgloss.Width(c.right); gap > 0 {
			return left + strings.Repeat(" ", gap) + c.right
		}
	}
	return ansi.Truncate(keyHints(commands), width, "…")
}

// contextStat is how much of the prompt was cached and how full the context
// is: "392k/396k cached (38%)", with a shorter form for narrow footers. The
// share turns yellow near the window, where compaction starts.
func (m ChatModel) contextStat() (full, short string) {
	usage := m.Usage
	if usage == nil || usage.Model != "" && m.Model != "" && usage.Model != m.Model {
		return m.Styles.Faint.Render("—/— cached"), m.Styles.Faint.Render("—/—")
	}
	count := func(n *int) string {
		if n == nil || *n < 0 {
			return "—"
		}
		return shortCount(*n)
	}
	ratio := m.Styles.Muted.Render(count(usage.CachedPromptTokens) + "/" + count(usage.PromptTokens))
	share := ""
	if total := contextTokens(usage); total != nil && m.window != nil && m.windowModel != nil && *m.windowModel == usage.Model {
		pct := int(math.Round(100 * float64(*total) / float64(*m.window)))
		style := m.Styles.Faint
		if pct >= 90 {
			style = m.Styles.Warning
		}
		share = " " + style.Render(fmt.Sprintf("(%d%%)", pct))
	}
	return ratio + m.Styles.Faint.Render(" cached") + share, ratio + share
}

// contextTokens is what the context holds after a reply: the prompt and the
// completion, when the provider did not report a total.
func contextTokens(u *daemon.Usage) *int {
	if u.TotalTokens != nil && *u.TotalTokens >= 0 {
		return u.TotalTokens
	}
	if u.PromptTokens == nil || *u.PromptTokens < 0 {
		return nil
	}
	total := *u.PromptTokens
	if u.CompletionTokens != nil && *u.CompletionTokens > 0 {
		total += *u.CompletionTokens
	}
	return &total
}

// shortCount keeps token counts to about three digits: 812, 4.2k, 392k, 1.2m.
func shortCount(n int) string {
	switch {
	case n < 1_000:
		return strconv.Itoa(n)
	case n < 10_000:
		return strings.TrimSuffix(fmt.Sprintf("%.1f", float64(n)/1_000), ".0") + "k"
	case n < 999_500:
		return fmt.Sprintf("%dk", int(math.Round(float64(n)/1_000)))
	default:
		return strings.TrimSuffix(fmt.Sprintf("%.1f", float64(n)/1_000_000), ".0") + "m"
	}
}
