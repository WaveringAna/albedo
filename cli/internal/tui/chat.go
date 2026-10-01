package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"errors"
	"fmt"
	"maps"
	"math"
	"math/rand/v2"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

type ChatBackToSessionsMsg struct{}
type ChatQuitMsg struct{}

// ChatEditorFinishedMsg is sent after the external editor process exits.
type ChatEditorFinishedMsg struct {
	Err        error
	SessionID  string
	Text       string
	Generation int64
	Edited     bool
}

// ChatOlderLoadedMsg carries a page of history from before what is shown.
type ChatOlderLoadedMsg struct {
	Err        error
	Page       *daemon.HistoryPage
	SessionID  string
	Generation int64
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
	Event      daemon.StreamEvent
	Generation int64
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
	Err        error
	Status     *daemon.AgentStatus
	SessionID  string
	Generation int64
	Revision   uint64
}

// ChatHostMsg is the probe of the host a remote workspace is on.
type ChatHostMsg struct {
	Err        error
	SessionID  string
	Workspace  string
	Status     daemon.HostStatus
	Generation int64
}

// ChatWindowMsg carries the context window for the model a usage event named.
type ChatWindowMsg struct {
	Err        error
	Tokens     *int
	SessionID  string
	Model      string
	Generation int64
}

// ChatCacheFadeMsg arrives when Usage's cached count reaches its next step.
type ChatCacheFadeMsg struct {
	Usage      *daemon.Usage
	SessionID  string
	Generation int64
}

type ChatStatusPollMsg struct {
	SessionID  string
	Generation int64
}

// ChatStreamResultMsg follows all accepted events from the same subscription.
type ChatStreamResultMsg struct {
	SessionID  string
	Generation int64
	Err        error
	Recovering bool
}

type streamDelivery struct {
	Event      *daemon.StreamEvent
	Err        error
	Recovering bool
}

type ChatStreamClosedMsg struct {
	SessionID  string
	Generation int64
}

type ChatOperationResolvedMsg struct {
	SessionID  string
	Generation int64
	Handle     *daemon.OperationHandle
	Receipt    daemon.OperationReceipt
	Err        error
}

type ChatTurnSentMsg struct {
	Handle      *daemon.OperationHandle
	OperationID string
	Err         error
	Image       *daemon.ImageAttachment
	SessionID   string
	Prompt      string
	Generation  int64
	Continue    bool
	OK          bool
	Queued      bool
}

type ChatInterruptMsg struct {
	Err         error
	SessionID   string
	Generation  int64
	Interrupted bool
}

// ChatOpenFolderPickerMsg asks for the folder picker; Retry is the turn a
// missing workspace refused.
type ChatOpenFolderPickerMsg struct{ Retry *WorkspaceRetry }

type ActiveStreamKind string

const (
	StreamKindNone     ActiveStreamKind = ""
	StreamKindText     ActiveStreamKind = "text"
	StreamKindThinking ActiveStreamKind = "thinking"
)

type pendingOperation struct {
	Handle  *daemon.OperationHandle
	Expired bool
}

type ChatOperationPollMsg struct {
	SessionID  string
	Generation int64
	Handle     *daemon.OperationHandle
}

type PendingUserTurn struct {
	Expired        bool
	Handle         *daemon.OperationHandle
	OperationID    string
	BlockingReason string
	Image          *daemon.ImageAttachment
	Text           string
	At             int64
	Queued         bool
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

var (
	sgrCode        = regexp.MustCompile(`\x1b\[[0-9;]*m`)
	phaseResting   = daemon.PhaseResting
	phaseReasoning = daemon.PhaseReasoning
	phaseTool      = daemon.PhaseTool
)

func wrapOrChunkLine(line string, width int) []string {
	if width <= 0 {
		width = 80
	}
	if ansi.StringWidth(line) <= width {
		return []string{line}
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

// burstRowsKey is what the cached live burst rows were rendered for: which
// entries end the transcript (count and evictions, since an eviction swaps the
// head without changing the count), how wide they render, where paths are
// named from, and which of them group at all.
type burstRowsKey struct {
	workspace string
	entries   int
	evicted   int
	epoch     int
	width     int
	flags     DisplayFlags
}

type ChatModel struct {
	Styles Styles

	streamCtx context.Context
	Usage     *daemon.Usage
	// inFlight is the last progress of the call the action row follows. It
	// outlives Progress, which the result clears, so the row can still say
	// what the call did once it ends.
	inFlight      *daemon.ToolProgress
	eventChan     chan streamDelivery
	streamStopped bool
	AttachedImage *daemon.ImageAttachment
	// window is the context window of windowModel, read once per model so
	// the footer can say how full the context is.
	window  *int
	client  *daemon.ChatClient
	History *BoundedHistory

	// Selection coordinates use frameLines, the whole transcript as last
	// drawn, so a selection can extend beyond the viewport.
	dragAnchor   *Point
	streamCancel context.CancelFunc
	windowModel  *string
	Progress     *daemon.ToolProgress
	// stretch is the phase run the status face animates.
	stretch             stretch
	SessionID           string
	Status              daemon.AgentStatus
	AgentName           string
	Workspace           string
	Host                string // the label of a remote workspace's host; "" when local
	Model               string
	Effort              string
	Provider            string
	CopyStatus          string
	ToolProgressText    string
	ThoughtProgressText string
	Renderer            TranscriptRenderer

	// hostHome is the remote home ~ names in the header, once the host's
	// probe reported it for hostAsked, the workspace it was asked for.
	hostHome, hostAsked string

	// userRows are the settled rows where user messages start.
	userRows      []int
	effortOptions []string

	// burstRows is the rendered frame of the trailing run of compact entries.
	// Its key names every input the rows depend on, so a refresh that changes
	// nothing redraws nothing, and nothing can ask for a stale frame.
	burstRows    []string
	Notices      Notices
	settledLines []string

	pendingUsers         []PendingUserTurn
	pendingContinuations map[string]pendingOperation
	Glances              []PageGlance
	frameLines           []string
	CommandMenu          CommandMenuModel
	Viewport             viewport.Model

	transcript         transcriptState
	TextArea           textarea.Model
	burstRowsKey       burstRowsKey
	dragHead           Point
	effortSelected     int
	Generation         int64
	copyStatusRevision uint64
	burstEpoch         int
	// burstRenders counts frame builds; tests watch it to catch a cache that
	// redraws every refresh or misses an invalidation.
	burstRenders  int
	ProgressFrame int
	Width         int
	// moodSeed selects the status-face animation for the current stretch.
	moodSeed            int64
	Height              int
	droppedSettledLines int
	settledLinesBytes   int64
	statusRevision      uint64
	scrollOffset        int

	scrollLimit int
	dragDir     int
	dragGen     int
	// olderBefore is the first transcript row carried by the reset or last older page.
	olderBefore int64
	// settledOffset counts notice rows above the settled transcript.
	settledOffset   int
	Flags           DisplayFlags
	Follow          bool
	TurnFailed      bool
	Stopping        bool
	Stopped         bool
	animationActive bool
	// rebuilding defers trimming until a re-render has placed the reading position.
	rebuilding bool

	// olderMore reports whether transcript rows precede olderBefore.
	olderMore bool
	// loadingOlder prevents overlapping history fetches.
	loadingOlder      bool
	isSending         bool
	interruptDeferred bool
	hostAuth          *hostSignIn
	sentHere          bool
	// graphemes says the terminal measures grapheme clusters (mode 2027),
	// which Bubble Tea turns off when it hands the terminal to the editor.
	graphemes bool
}

// NewChatModel requires a session client. A nil client panics.
func NewChatModel(session *daemon.Session, client *daemon.ChatClient) ChatModel {
	if client == nil {
		panic("tui.NewChatModel: nil client")
	}
	ta := textarea.New()
	ta.Placeholder = ""
	ta.Prompt = promptMark
	ta.CharLimit = 0
	ta.ShowLineNumbers = false
	ta.SetPromptFunc(promptMarkWidth, func(info textarea.PromptInfo) string {
		if info.LineNumber == 0 {
			return promptMark
		}
		return strings.Repeat(" ", promptMarkWidth)
	})
	ta.KeyMap.InsertNewline.SetKeys("enter", "ctrl+m", "alt+enter", "shift+enter")
	ta.KeyMap.WordBackward.SetKeys("alt+left", "alt+b", "ctrl+left")
	ta.KeyMap.WordForward.SetKeys("alt+right", "alt+f", "ctrl+right")
	ta.SetHeight(6)
	st := ta.Styles()
	st.Focused.Prompt, st.Blurred.Prompt = DefaultStyles.Prompt, DefaultStyles.Prompt
	st.Focused.CursorLine, st.Blurred.CursorLine = lipgloss.NewStyle(), lipgloss.NewStyle()
	st.Focused.Placeholder, st.Blurred.Placeholder = DefaultStyles.Faint, DefaultStyles.Faint
	st.Cursor.Blink, st.Cursor.Color = false, nil
	ta.SetStyles(st)
	ta.Focus()

	vp := viewport.New(viewport.WithWidth(80), viewport.WithHeight(20))
	vp.YPosition = 0

	bh := NewBoundedHistory(500, 2*1024*1024)

	ctx, cancel := context.WithCancel(context.Background())
	gen := time.Now().UnixNano()

	m := ChatModel{
		SessionID:    session.ID,
		Generation:   gen,
		AgentName:    "albedo",
		Workspace:    session.Workspace,
		Host:         sessionHost(*session),
		Model:        session.Model,
		Effort:       session.Effort,
		Provider:     session.Provider,
		client:       client,
		History:      bh,
		Renderer:     TranscriptRenderer{Styles: DefaultStyles, Workspace: session.Workspace},
		Viewport:     vp,
		TextArea:     ta,
		CommandMenu:  NewCommandMenuModel(),
		Flags:        DisplayFlags{},
		Follow:       true,
		Styles:       DefaultStyles,
		transcript:   newTranscriptState(),
		streamCtx:    ctx,
		streamCancel: cancel,
		eventChan:    make(chan streamDelivery, 16),
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
	m.Viewport.SetHeight(max(1, m.Height-6-m.chromeRows()))
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
	// A successful mutation does not repair a stopped subscription.
	if m.streamStopped {
		return
	}
	if len(m.Notices) > 0 {
		m.Notices.Clear()
		m.syncViewportHeight()
	}
}

// wordBackwardAtStart reports whether the prompt has no word before its cursor.
// The textarea's word-backward handler loops indefinitely in this case.
func (m ChatModel) wordBackwardAtStart() bool {
	lines := strings.Split(m.TextArea.Value(), "\n")
	row := m.TextArea.Line()
	if row < 0 || row >= len(lines) {
		return false
	}
	if slices.ContainsFunc(lines[:row], func(line string) bool { return strings.TrimSpace(line) != "" }) {
		return false
	}
	col := m.TextArea.LineInfo().StartColumn + m.TextArea.LineInfo().ColumnOffset
	current := []rune(lines[row])
	col = max(0, min(col, len(current)))
	return strings.TrimSpace(string(current[:col])) == ""
}

func (m ChatModel) promptLines() int {
	lineCount := m.TextArea.LineCount()
	if lineCount <= 1 {
		return max(1, m.TextArea.LineInfo().Height)
	}
	cp := m.TextArea
	for cp.Line() > 0 {
		cp.CursorUp()
	}
	total := 0
	for line := range lineCount {
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
	if m.Height > 0 {
		return max(1, min(6, (m.Height-8)/2))
	}
	return 6
}

func (m ChatModel) promptHeight() int {
	return min(m.promptLines(), m.maxPromptHeight())
}

func (m ChatModel) inputRows() int {
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
	m.Viewport.SetHeight(max(1, m.Height-6-m.chromeRows()))
	m.refreshViewportContent()
}

func (m *ChatModel) SetSize(width, height int) {
	if m == nil || m.History == nil {
		return
	}
	m.Width, m.Height = max(1, width), max(1, height)

	available := max(1, m.Width-2*m.padding())
	transcriptWidth := available
	if sw := m.sidebarWidth(); sw > 0 {
		transcriptWidth -= sw + 2
	}

	m.Viewport.SetWidth(transcriptWidth)
	m.TextArea.SetWidth(available)
	m.TextArea.SetHeight(m.maxPromptHeight())
	m.Viewport.SetHeight(max(1, m.Height-6-m.chromeRows()))

	// settled rows are rendered at the body width alone, so only a new body
	// width renders them again
	if body := min(100, available); body != m.Renderer.BodyWidth {
		m.Renderer.BodyWidth = body
		m.rebuildSettledLines()
	}
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
	var line string
	switch {
	case m.loadingOlder:
		line = m.Styles.Faint.Render("↑ loading earlier messages…")
	case m.hasOlder():
		line = m.Styles.Faint.Render("↑ earlier messages load as you scroll up")
	case m.History.TruncationNotice() != "":
		line = m.Styles.Warning.Render(m.History.TruncationNotice())
	default:
		return nil
	}
	return []string{markChrome + m.Renderer.rail(laneNone) + line, ""}
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

// appendBlock settles entry after the entries before it.
func (m *ChatModel) appendBlock(before []HistoryEntry, entry HistoryEntry) {
	rows, head := m.Renderer.Settle(before, entry, m.Flags)
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
		// Rendered rows own their text: body chunks are concatenated with a
		// nonempty rail; separators retain only small rail strings or empty text.
		fresh := make([]string, len(m.settledLines))
		copy(fresh, m.settledLines)
		clear(m.settledLines)
		m.settledLines = fresh
	}
}

// replaceSettled swaps the n settled rows at from for rows, and returns how
// many rows the caps then dropped from the top.
func (m *ChatModel) replaceSettled(from, n int, rows []string) int {
	m.settledLinesBytes += rowBytes(rows) - rowBytes(m.settledLines[from:from+n])
	m.settledLines = slices.Replace(m.settledLines, from, from+n, rows...)
	for i, at := range m.userRows {
		if at >= from+n {
			m.userRows[i] += len(rows) - n
		}
	}
	dropped := m.droppedSettledLines
	m.trimSettledLines()
	return m.droppedSettledLines - dropped
}

func rowBytes(rows []string) int64 {
	var n int64
	for _, row := range rows {
		n += int64(len(row))
	}
	return n
}

// clearAction drops the live action row; the next action starts a new one.
func (m *ChatModel) clearAction() {
	m.ToolProgressText = ""
	m.inFlight = nil
	m.ThoughtProgressText = ""
}

func (m *ChatModel) appendSettledEntry(entry HistoryEntry) {
	if Compact(entry, m.Flags) {
		facts := factsOf(entry)
		entry.facts = &facts
	}
	m.appendBlock(m.History.Entries(), entry)
	m.History.Append(entry)
}

// settleActiveStream appends assembled text and retains a live thought's last
// line as the compact action until the next action replaces it.
func (m *ChatModel) settleActiveStream() {
	watched := !m.transcript.thinkingSince.IsZero()
	for _, entry := range m.transcript.settle(m.AgentName) {
		if watched && entry.Kind == EntryThinking {
			m.ThoughtProgressText = cmp.Or(thinkingLine(entry.Text), "thinking")
		}
		m.appendSettledEntry(entry)
	}
}

func (m *ChatModel) refreshViewportContent() int {
	if m.Viewport.Height() != max(1, m.Height-6-m.chromeRows()) {
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
		if burst := trailingBurst(entries, m.Flags); len(burst) > 0 {
			key := burstRowsKey{entries: len(entries), evicted: m.History.EvictedCount(), epoch: m.burstEpoch, width: m.Renderer.BodyWidth, workspace: m.Renderer.Workspace, flags: m.Flags}
			if key != m.burstRowsKey {
				m.burstRows = m.Renderer.BurstBlock(entries[:len(entries)-len(burst)], burst, m.Flags)
				m.burstRowsKey = key
				m.burstRenders++
			}
			allLines = append(allLines, m.burstRows...)
		}
	}
	if m.transcript.activeKind != StreamKindNone && m.transcript.activeText != "" &&
		(m.transcript.activeKind != StreamKindThinking || m.Flags.Thinking) {
		activeEntry := HistoryEntry{Kind: m.transcript.activeEntryKind(), Speaker: m.AgentName, Text: m.transcript.activeText, Live: true}
		rows, _ := m.Renderer.Block(m.History.Entries(), activeEntry, m.Flags)
		allLines = append(allLines, rows...)
		last, stacks = laneOf(activeEntry), false
	}

	// One live-tail slot stays occupied by the last action until another begins.
	action := ""
	switch {
	case m.transcript.activeKind == StreamKindThinking && m.transcript.activeText != "" && !m.Flags.Thinking:
		action = m.renderThought()
	case m.ToolProgressText != "" && (m.Progress != nil || !m.Flags.Tools):
		action = m.renderProgress()
	case m.ThoughtProgressText != "" && !m.Flags.Thinking:
		width := max(1, m.Renderer.BodyWidth-railWidth)
		action = markChrome + m.Styles.Faint.Render(ansi.Truncate(m.ThoughtProgressText, width, "…"))
	}
	if action != "" {
		if len(allLines) > 0 && !stacks {
			allLines = append(allLines, strings.TrimRight(m.Renderer.rail(joint(last, laneBusy)), " "))
		}
		allLines = append(allLines, m.Renderer.rail(laneBusy)+action)
	}
	allLines = append(allLines, m.pendingRows()...)
	m.frameLines = allLines

	totalLines := len(allLines)
	vpHeight := max(1, m.Viewport.Height())
	maxScroll := max(0, totalLines-vpHeight)
	m.scrollLimit = maxScroll

	var visibleSlice []string
	if m.Follow {
		m.scrollOffset = maxScroll
		visibleSlice = allLines[maxScroll:totalLines]
	} else {
		m.scrollOffset = max(0, min(m.scrollOffset, maxScroll))
		end := min(totalLines, m.scrollOffset+vpHeight)
		if m.scrollOffset < end {
			visibleSlice = allLines[m.scrollOffset:end]
		}
	}
	m.Viewport.SetContent(strings.Join(visibleSlice, "\n"))
	if m.Follow {
		m.Viewport.GotoBottom()
	} else {
		m.Viewport.GotoTop()
	}
	return maxScroll
}

// pendingRows are your messages the daemon has not echoed yet, greyed out at
// the end of the transcript where they will settle. Each follows whatever is
// live above it, so the rails and names join up as they will once settled.
func (m ChatModel) pendingRows() []string {
	if len(m.pendingUsers) == 0 && len(m.pendingContinuations) == 0 {
		return nil
	}
	before := slices.Clone(m.History.Entries())
	if m.transcript.activeKind != StreamKindNone && m.transcript.activeText != "" {
		before = append(before, HistoryEntry{Kind: m.transcript.activeEntryKind(), Speaker: m.AgentName})
	}
	if m.ToolProgressText != "" && (m.Progress != nil || !m.Flags.Tools) {
		before = append(before, HistoryEntry{Kind: EntryTool, Speaker: m.AgentName})
	} else if m.ThoughtProgressText != "" && !m.Flags.Thinking {
		before = append(before, HistoryEntry{Kind: EntryThinking, Speaker: m.AgentName})
	}
	var rows []string
	for _, p := range m.pendingUsers {
		state := sending
		if p.Queued {
			state = queued
		}
		text := p.Text
		if p.Expired {
			state = unresolved
			text += "\nOperation " + p.OperationID + " expired; its outcome is unknown."
		}
		if p.BlockingReason != "" && !p.Expired {
			text += "\nWaiting: " + p.BlockingReason
		}
		entry := HistoryEntry{Kind: EntryUser, Speaker: "You", Text: text, Timestamp: p.At, Pending: state}
		block, _ := m.Renderer.Block(before, entry, m.Flags)
		rows = append(rows, block...)
		before = append(before, entry)
	}
	for _, id := range slices.Sorted(maps.Keys(m.pendingContinuations)) {
		if m.pendingContinuations[id].Expired {
			entry := HistoryEntry{Kind: EntryError, Text: "Continue operation " + id + " expired; its outcome is unresolved."}
			block, _ := m.Renderer.Block(before, entry, m.Flags)
			rows = append(rows, block...)
		}
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
	return m.isSending || m.pendingSendCount() > 0 || m.Stopping || m.Progress != nil || m.Status.Running && !m.Status.Idle
}

func (m *ChatModel) startAnimation() tea.Cmd {
	if m.streamStopped || m.animationActive || !m.animating() {
		return nil
	}
	m.animationActive = true
	return m.progressTickCmd()
}

func (m ChatModel) progressTickCmd() tea.Cmd {
	id, generation := m.SessionID, m.Generation
	return tea.Tick(faceInterval, func(time.Time) tea.Msg { return ChatProgressTickMsg{SessionID: id, Generation: generation} })
}

func (m ChatModel) waitForNextEvent() tea.Cmd {
	sessID, gen, ch, ctx := m.SessionID, m.Generation, m.eventChan, m.streamCtx
	return func() tea.Msg {
		select {
		case evt, ok := <-ch:
			if !ok {
				return ChatStreamClosedMsg{SessionID: sessID, Generation: gen}
			}
			if evt.Event != nil {
				return ChatStreamEventMsg{SessionID: sessID, Generation: gen, Event: *evt.Event}
			}
			return ChatStreamResultMsg{SessionID: sessID, Generation: gen, Err: evt.Err, Recovering: evt.Recovering}
		case <-ctx.Done():
			return ChatStreamClosedMsg{SessionID: sessID, Generation: gen}
		}
	}
}

func (m ChatModel) startStreamSubscription() tea.Cmd {
	client, ctx, ch := m.client, m.streamCtx, m.eventChan
	go func() {
		defer close(ch)
		defer client.ResetStream()
		deliver := func(value streamDelivery) bool {
			select {
			case ch <- value:
				return true
			case <-ctx.Done():
				return false
			}
		}
		recovered := false
		delay := 500 * time.Millisecond
		for ctx.Err() == nil {
			err := client.StreamWithProgress(ctx, olderPageRows, func(evt daemon.StreamEvent) error {
				if !deliver(streamDelivery{Event: &evt}) {
					return ctx.Err()
				}
				return nil
			}, func() { delay = 500 * time.Millisecond })
			if ctx.Err() != nil {
				return
			}
			var failure *daemon.StreamError
			if errors.As(err, &failure) {
				switch failure.Kind {
				case daemon.StreamProtocol:
					if recovered {
						deliver(streamDelivery{Err: err})
						return
					}
					recovered = true
					if !deliver(streamDelivery{Err: err, Recovering: true}) {
						return
					}
					client.ResetStream()
				case daemon.StreamTerminal:
					deliver(streamDelivery{Err: err})
					return
				}
			}
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
			delay = min(delay*2, 5*time.Second)
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
	client, ctx, id, generation, revision := m.client, m.streamCtx, m.SessionID, m.Generation, m.statusRevision
	return func() tea.Msg {
		value, err := client.GetStatus(ctx)
		return ChatStatusMsg{SessionID: id, Generation: generation, Revision: revision, Status: value, Err: err}
	}
}

// windowCmd reads the context window when usage names a model whose window
// has not been read yet.
func (m ChatModel) windowCmd() tea.Cmd {
	if m.Usage == nil || m.windowModel != nil && *m.windowModel == m.Usage.Model {
		return nil
	}
	client, ctx, id, generation, model := m.client, m.streamCtx, m.SessionID, m.Generation, m.Usage.Model
	return func() tea.Msg {
		tokens, err := client.ContextWindow(ctx)
		return ChatWindowMsg{SessionID: id, Generation: generation, Model: model, Tokens: tokens, Err: err}
	}
}

// cacheFadeCmd wakes the footer when the cached count reaches its next step.
func (m ChatModel) cacheFadeCmd() tea.Cmd {
	if m.Usage == nil {
		return nil
	}
	now := time.Now().UnixMilli()
	for _, step := range m.Usage.CacheFade {
		if step.At > now {
			id, generation, usage := m.SessionID, m.Generation, m.Usage
			return tea.Tick(time.Duration(step.At-now)*time.Millisecond, func(time.Time) tea.Msg {
				return ChatCacheFadeMsg{SessionID: id, Generation: generation, Usage: usage}
			})
		}
	}
	return nil
}

// hostHomeCmd asks a remote workspace's host where its home is, once per
// workspace, after the kernel attached: the probe has answered by then.
func (m *ChatModel) hostHomeCmd() tea.Cmd {
	host, _ := daemon.SplitLocation(m.Workspace)
	if host == "" || m.hostAsked == m.Workspace || m.Status.KernelLink != "attached" {
		return nil
	}
	m.hostAsked = m.Workspace
	client, ctx, id, generation, workspace := m.client, m.streamCtx, m.SessionID, m.Generation, m.Workspace
	return func() tea.Msg {
		status, err := client.Host(ctx, host)
		return ChatHostMsg{SessionID: id, Generation: generation, Workspace: workspace, Status: status, Err: err}
	}
}

func (m ChatModel) statusPollCmd() tea.Cmd {
	id, generation := m.SessionID, m.Generation
	return tea.Tick(750*time.Millisecond, func(time.Time) tea.Msg { return ChatStatusPollMsg{SessionID: id, Generation: generation} })
}

func (m ChatModel) Init() tea.Cmd {
	commands := []tea.Cmd{m.startStreamSubscription(), m.statusCmd()}
	for _, pending := range m.pendingUsers {
		if pending.Handle != nil && !pending.Expired {
			commands = append(commands, m.queryOperationCmd(pending.Handle))
		}
	}
	for _, pending := range m.pendingContinuations {
		if !pending.Expired {
			commands = append(commands, m.queryOperationCmd(pending.Handle))
		}
	}
	return tea.Batch(commands...)
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
	if !more {
		return nil
	}
	m.loadingOlder = true
	m.refreshViewportContent()
	client, id, generation := m.client, m.SessionID, m.Generation
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
		m.AddError(fmt.Sprintf("Could not load earlier messages: %v", msg.Err))
		return *m
	}
	older := replayTranscript(msg.Page.Events, m.AgentName)
	for i := range older {
		if Compact(older[i], m.Flags) {
			facts := factsOf(older[i])
			older[i].facts = &facts
		}
	}
	m.History.Prepend(older)
	m.olderBefore, m.olderMore = msg.Page.Before, msg.Page.More && msg.Page.Before > 0
	m.rebuildSettledLines()
	m.refreshViewportContent()
	return *m
}

func (m ChatModel) update(msg tea.Msg) (ChatModel, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.KeyPressMsg:
		// The selector owns keys while open, before chat navigation or composer input.
		if len(m.effortOptions) > 0 {
			switch msg.String() {
			case "left", "up":
				m.effortSelected = max(0, m.effortSelected-1)
			case "right", "down":
				m.effortSelected = min(len(m.effortOptions)-1, m.effortSelected+1)
			case "enter", "esc":
				level := m.effortOptions[m.effortSelected]
				m.effortOptions = nil
				m.syncLayout()
				if msg.String() == "enter" {
					return m, func() tea.Msg { return ChatExecuteCommandMsg{Name: "/effort", Args: level} }
				}
			case "ctrl+c":
				m.Close()
				return m, func() tea.Msg { return ChatQuitMsg{} }
			}
			return m, nil
		}

		if msg.String() == "left" && m.TextArea.Value() == "" {
			return m, func() tea.Msg { return ChatBackToSessionsMsg{} }
		}

		if msg.String() == "ctrl+c" || (msg.String() == "ctrl+d" && m.TextArea.Focused() && m.TextArea.Value() == "") {
			m.Close()
			return m, func() tea.Msg { return ChatQuitMsg{} }
		}
		if msg.String() == "ctrl+n" {
			return m, func() tea.Msg { return ChatNewSessionMsg{} }
		}
		if msg.String() == "ctrl+o" {
			return m, func() tea.Msg { return ChatOpenAgentsMsg{} }
		}
		if msg.String() == "esc" && m.dragAnchor != nil {
			m.dragAnchor, m.dragDir = nil, 0
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

		switch msg.String() {
		case "esc":
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
				cmds = append(cmds, m.interruptCmd())
				return m, tea.Batch(cmds...)
			}
		case "ctrl+v":
			return m, PasteClipboardImageCmd(m.SessionID, m.Generation)
		case "ctrl+g":
			return m, m.openEditorCmd()
		case "ctrl+l":
			if m.hostAuth != nil && m.hostAuth.here {
				return m, m.signInCmd()
			}
		case "pgup", "pgdown":
			delta := m.Viewport.Height()
			if msg.String() == "pgup" {
				delta = -delta
			}
			m.scrollBy(delta)
			return m, nil
		case "up":
			if m.TextArea.Line() == 0 && m.TextArea.LineInfo().RowOffset == 0 {
				m.scrollBy(-1)
				return m, nil
			}
		case "down":
			if m.TextArea.Line() >= m.TextArea.LineCount()-1 && m.TextArea.LineInfo().RowOffset >= m.TextArea.LineInfo().Height-1 {
				m.scrollBy(1)
				return m, nil
			}
		case "shift+up", "shift+down":
			m.jumpToYou(msg.String() == "shift+up")
			return m, nil
		case "ctrl+home", "ctrl+end":
			m.Follow = msg.String() == "ctrl+end"
			if !m.Follow {
				m.scrollOffset = 0
			}
			m.refreshViewportContent()
			return m, nil
		case "ctrl+j", "ctrl+k":
			if msg.String() == "ctrl+j" {
				m.Flags.Diffs = !m.Flags.Diffs
			} else {
				m.Flags.Compaction = !m.Flags.Compaction
			}
			m.rebuildSettledLines()
			m.refreshViewportContent()
			return m, nil
		case "ctrl+left":
			// Bubbles wordLeft never terminates when everything before the cursor
			// is whitespace. Move to the input start directly in that case.
			if m.wordBackwardAtStart() {
				var cmd tea.Cmd
				m.TextArea, cmd = m.TextArea.Update(tea.KeyPressMsg{Code: tea.KeyHome, Mod: tea.ModCtrl})
				return m, cmd
			}
		case "enter":
			trimmed := strings.TrimSpace(m.TextArea.Value())
			// a draft typed while connecting waits in the composer
			if m.connecting() && (!strings.HasPrefix(trimmed, "/") || !m.isRecognizedCommand(trimmed)) {
				return m, nil
			}
			if trimmed != "" {
				m.TextArea.Reset()
				m.syncLayout()
				m.submitInput(trimmed, &cmds)
				return m, tea.Batch(cmds...)
			}
			return m, nil
		}

	case dragScrollMsg:
		cmd := m.dragScrolled(msg)
		return m, cmd

	case tea.MouseMsg:
		firstRow := 2 + m.Notices.ChromeRows()
		mouse := msg.Mouse()
		point := func() Point {
			screen := max(0, min(m.Viewport.Height()-1, mouse.Y-firstRow))
			return Point{Row: m.scrollOffset + screen, Col: max(0, min(m.Viewport.Width(), mouse.X-m.padding()))}
		}
		switch msg := msg.(type) {
		case tea.MouseReleaseMsg:
			if m.dragAnchor == nil {
				return m, nil
			}
			m.dragHead = point()
			sel := Selection{Anchor: *m.dragAnchor, Head: m.dragHead, Gutter: railWidth}
			m.dragAnchor, m.dragDir = nil, 0
			if sel.IsEmpty() {
				cmd := m.actAt(sel.Head.Row)
				return m, cmd
			}
			if text := SelectedText(m.frameLines, sel); text != "" {
				cmd := m.copied(text)
				return m, cmd
			}
		case tea.MouseMotionMsg:
			if m.dragAnchor != nil {
				m.dragHead = point()
				cmd := m.steerDragScroll(mouse.Y - firstRow)
				return m, cmd
			}
		case tea.MouseClickMsg:
			if msg.Button == tea.MouseLeft && mouse.Y >= firstRow && mouse.Y < firstRow+m.Viewport.Height() {
				pt := point()
				m.dragAnchor = &pt
				m.dragHead = pt
			}
		case tea.MouseWheelMsg:
			switch msg.Button {
			case tea.MouseWheelUp:
				m.scrollBy(-3)
			case tea.MouseWheelDown:
				m.scrollBy(3)
			}
			if m.dragAnchor != nil {
				m.dragHead = point()
			}
		}
		return m, nil

	case ClipboardImagePastedMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		if msg.Err == nil && msg.Image != nil {
			m.AttachedImage = msg.Image
			m.CopyStatus = ""
			m.refreshViewportContent()
		} else if msg.Err != nil {
			m.AddError(fmt.Sprintf("Could not paste the image: %v", msg.Err))
		}
		return m, nil

	case ChatStatusPollMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation || m.streamStopped {
			return m, nil
		}
		return m, m.statusCmd()

	case ChatStatusMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation || m.streamStopped {
			return m, nil
		}
		if msg.Err == nil && msg.Status != nil && msg.Revision == m.statusRevision {
			m.Status = *msg.Status
			defer m.reseedMood()
			// most polls find the session idle with nothing live to settle
			live := m.Progress != nil || m.ToolProgressText != "" || m.ThoughtProgressText != "" || m.transcript.activeKind != StreamKindNone || m.transcript.turn != nil && m.transcript.turn.begun()
			if live && (!m.Status.Running || m.Status.Idle) {
				m.Progress = nil
				m.settleActiveStream()
				m.ToolProgressText = ""
				m.ThoughtProgressText = ""
				if m.transcript.turn != nil && m.transcript.turn.begun() {
					for _, entry := range m.transcript.closeTurn(false) {
						m.appendSettledEntry(entry)
					}
				}
				m.refreshViewportContent()
			}
		}
		home := m.hostHomeCmd()
		return m, tea.Batch(m.startAnimation(), m.statusPollCmd(), home)

	case ChatHostMsg:
		if msg.SessionID == m.SessionID && msg.Generation == m.Generation && msg.Workspace == m.Workspace && msg.Err == nil {
			_, m.hostHome = daemon.SplitLocation(msg.Status.Home)
		}
		return m, nil

	case ChatStreamEventMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation || m.streamStopped {
			return m, nil
		}
		// only a live event outdates a status reply in flight
		if !msg.Event.Replayed {
			m.statusRevision++
		}
		m.handleStreamEvent(msg.Event)
		m.refreshViewportContent()

		var fade tea.Cmd
		if msg.Event.Type == daemon.EventUsage {
			fade = m.cacheFadeCmd()
		}
		return m, tea.Batch(m.waitForNextEvent(), m.startAnimation(), m.windowCmd(), fade)

	case ChatWindowMsg:
		if msg.SessionID == m.SessionID && msg.Generation == m.Generation && msg.Err == nil {
			m.window, m.windowModel = msg.Tokens, &msg.Model
		}
		return m, nil

	case ChatCacheFadeMsg:
		// newer usage has its own countdown
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation || msg.Usage != m.Usage {
			return m, nil
		}
		return m, m.cacheFadeCmd()

	case ChatClearCopyStatusMsg:
		if msg.SessionID == m.SessionID && msg.Generation == m.Generation && msg.Revision == m.copyStatusRevision {
			m.CopyStatus = ""
		}
		return m, nil

	case ChatProgressTickMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation || m.streamStopped {
			return m, nil
		}
		if !m.animating() {
			m.animationActive = false
			return m, nil
		}
		// the face lives in the status line, so the transcript stays as it is
		m.ProgressFrame++
		return m, m.progressTickCmd()

	case ChatStreamResultMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation || m.streamStopped {
			return m, nil
		}
		m.Progress = nil
		m.clearAction()
		if msg.Recovering {
			m.AddNotice(fmt.Sprintf("Stream data could not be read; refreshing history: %v", msg.Err))
			return m, m.waitForNextEvent()
		}
		m.streamStopped = true
		m.animationActive = false
		m.AddError(fmt.Sprintf("Session stream stopped: %v. Reopen the session to reconnect.", msg.Err))
		m.refreshViewportContent()
		return m, nil

	case ChatStreamClosedMsg:
		return m, nil

	case ChatOperationPollMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation || !m.operationRecoverable(msg.Handle.ID()) {
			return m, nil
		}
		return m, m.queryOperationCmd(msg.Handle)

	case ChatOperationResolvedMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		index := slices.IndexFunc(m.pendingUsers, func(p PendingUserTurn) bool { return p.OperationID == msg.Handle.ID() })
		if !m.operationRecoverable(msg.Handle.ID()) {
			return m, nil
		}
		if daemon.IsOperationExpired(msg.Err) {
			if index >= 0 {
				m.pendingUsers[index].Expired = true
			} else {
				pending := m.pendingContinuations[msg.Handle.ID()]
				pending.Expired = true
				m.pendingContinuations[msg.Handle.ID()] = pending
			}
			m.refreshViewportContent()
			return m, nil
		}
		if msg.Err == nil && (msg.Receipt.Status == "rejected" || msg.Receipt.DeliveryStatus == "cancelled" || msg.Receipt.DeliveryStatus == "committed") {
			delete(m.pendingContinuations, msg.Handle.ID())
			m.dropSignIn()
			if rejection := msg.Receipt.Rejection(); rejection != nil {
				m.ClearNotices()
				m.AddError(rejection.Error())
			}
			if index >= 0 {
				m.pendingUsers = slices.Delete(m.pendingUsers, index, index+1)
			}
			m.refreshViewportContent()
			return m, nil
		}
		if index >= 0 && msg.Err == nil {
			m.pendingUsers[index].Queued = true
			m.pendingUsers[index].BlockingReason = msg.Receipt.BlockingReason
			m.refreshViewportContent()
		}
		return m, tea.Batch(m.resolveOperationCmd(msg.Handle), m.hostAuthCmd(msg.Receipt.BlockingReason))

	case chatHostAuthMsg:
		m.offerSignIn(msg)
		return m, nil

	case chatSignedInMsg:
		m.signedIn(msg)
		return m, nil

	case ChatTurnSentMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		m.isSending = false
		if msg.Err != nil {
			m.interruptDeferred = false
			if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](msg.Err); uncertain {
				if msg.Handle != nil && m.operationRecoverable(msg.Handle.ID()) && daemon.IsOperationExpired(msg.Err) {
					return m.Update(ChatOperationResolvedMsg{SessionID: m.SessionID, Generation: m.Generation, Handle: msg.Handle, Err: msg.Err})
				}
				message := "Message admission is uncertain. Checking its operation receipt."
				if msg.Continue {
					message = "Continue admission is uncertain. Checking its operation receipt."
				}
				m.AddError(message)
				m.refreshViewportContent()
				if msg.Handle != nil && m.operationRecoverable(msg.Handle.ID()) {
					return m, m.resolveOperationCmd(msg.Handle)
				}
				return m, nil
			}
			delete(m.pendingContinuations, msg.OperationID)
			if !msg.Continue {
				if i := slices.IndexFunc(m.pendingUsers, func(p PendingUserTurn) bool { return p.OperationID == msg.OperationID }); i >= 0 {
					m.pendingUsers = slices.Delete(m.pendingUsers, i, i+1)
				}
				if m.TextArea.Value() == "" {
					m.TextArea.SetValue(msg.Prompt)
				}
			}
			if m.AttachedImage == nil && msg.Image != nil {
				m.AttachedImage = msg.Image
			}
			if wsErr, ok := errors.AsType[*daemon.WorkspaceMissingError](msg.Err); ok {
				m.Status.Running, m.Status.Idle = false, true
				retry := &WorkspaceRetry{Missing: wsErr.Workspace, Prompt: msg.Prompt, Continue: msg.Continue, Image: msg.Image}
				cmds = append(cmds, func() tea.Msg { return ChatOpenFolderPickerMsg{Retry: retry} })
			} else {
				m.AddError(fmt.Sprintf("Could not send the message: %v", msg.Err))
				errText := msg.Err.Error()
				if msg.Queued {
					errText = "Message was not queued: " + errText
				}
				m.appendSettledEntry(HistoryEntry{Kind: EntryError, Text: errText})
			}
			m.refreshViewportContent()
			return m, tea.Batch(cmds...)
		}

		if msg.Queued {
			if i := slices.IndexFunc(m.pendingUsers, func(p PendingUserTurn) bool {
				return p.OperationID == msg.OperationID && !p.Queued
			}); i >= 0 {
				m.pendingUsers[i].Queued = true
			}
		}
		if msg.Handle != nil && (msg.Continue || slices.ContainsFunc(m.pendingUsers, func(p PendingUserTurn) bool { return p.OperationID == msg.OperationID })) {
			cmds = append(cmds, m.resolveOperationCmd(msg.Handle))
		}

		// If user pressed Esc while this send was in flight, dispatch interrupt now that send is accepted
		if m.interruptDeferred {
			m.interruptDeferred = false
			m.Stopping = true
			cmds = append(cmds, m.interruptCmd())
		}
		return m, tea.Batch(cmds...)

	case ChatEditorFinishedMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		if msg.Edited {
			m.TextArea.SetValue(strings.TrimRight(msg.Text, "\r\n"))
			m.syncLayout()
		}
		if msg.Err != nil {
			m.AddError("Could not finish editing the prompt: " + msg.Err.Error())
		}
		return m, nil

	case ChatInterruptMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return m, nil
		}
		if msg.Err != nil || !msg.Interrupted {
			m.Stopping = false
			if msg.Err != nil {
				m.appendSettledEntry(HistoryEntry{Kind: EntryError, Text: "Could not stop the current reply: " + msg.Err.Error()})
			}
		}
		return m, nil
	}

	oldMenu, oldH := min(4, len(m.CommandMenu.Matches(m.TextArea.Value()))), m.promptHeight()
	var taCmd tea.Cmd
	m.TextArea, taCmd = m.TextArea.Update(msg)
	if min(4, len(m.CommandMenu.Matches(m.TextArea.Value()))) != oldMenu || m.promptHeight() != oldH {
		m.syncLayout()
	}
	cmds = append(cmds, taCmd)

	return m, tea.Batch(cmds...)
}

// Moved takes the session's new folder, then sends again the turn a
// missing folder refused.
func (m *ChatModel) Moved(moved daemon.Session, retry *WorkspaceRetry) tea.Cmd {
	workspace := moved.Workspace
	m.Workspace, m.Host, m.hostHome = workspace, sessionHost(moved), ""
	m.Renderer.Workspace = workspace
	m.rebuildSettledLines() // settled rows name paths from the old workspace
	m.refreshViewportContent()
	return m.resend(retry)
}

// resend sends again a turn the daemon refused, once what refused it is fixed.
func (m *ChatModel) resend(retry *WorkspaceRetry) tea.Cmd {
	if retry == nil {
		return nil
	}
	if retry.Image != nil && m.AttachedImage == nil {
		m.AttachedImage = retry.Image
	}
	m.TextArea.Reset()
	m.syncLayout()
	var cmds []tea.Cmd
	prompt := retry.Prompt
	if retry.Continue {
		prompt = "."
	}
	m.submitInput(prompt, &cmds)
	return tea.Batch(cmds...)
}

func (m ChatModel) queryOperationCmd(handle *daemon.OperationHandle) tea.Cmd {
	client, id, gen, ctx := m.client, m.SessionID, m.Generation, m.streamCtx
	return func() tea.Msg {
		receipt, err := client.ResolveOperation(ctx, handle)
		return ChatOperationResolvedMsg{SessionID: id, Generation: gen, Handle: handle, Receipt: receipt, Err: err}
	}
}
func (m ChatModel) resolveOperationCmd(handle *daemon.OperationHandle) tea.Cmd {
	id, gen := m.SessionID, m.Generation
	return tea.Tick(15*time.Second, func(time.Time) tea.Msg { return ChatOperationPollMsg{SessionID: id, Generation: gen, Handle: handle} })
}
func (m *ChatModel) sendCmd(handle *daemon.OperationHandle, prompt string, image *daemon.ImageAttachment, isCont bool) tea.Cmd {
	client, id, gen := m.client, m.SessionID, m.Generation
	return func() tea.Msg {
		msg := ChatTurnSentMsg{SessionID: id, Generation: gen, Prompt: prompt, Image: image, Continue: isCont, Handle: handle, OperationID: handle.ID()}
		result, err := client.SubmitOperation(context.Background(), handle)
		msg.Err = err
		if err == nil && result != nil {
			msg.OK, msg.Queued = result.OK, result.Queued
		}
		return msg
	}
}

func (m *ChatModel) interruptCmd() tea.Cmd {
	client, id, gen := m.client, m.SessionID, m.Generation
	return func() tea.Msg {
		ok, err := client.Interrupt(context.Background())
		return ChatInterruptMsg{SessionID: id, Generation: gen, Interrupted: ok, Err: err}
	}
}

func (m *ChatModel) isRecognizedCommand(input string) bool {
	trimmed := strings.TrimSpace(input)
	if !strings.HasPrefix(trimmed, "/") {
		return false
	}
	token := strings.Fields(trimmed)[0]
	switch token {
	case "/a", "/agents", "/sessions", "/q", "/quit", "/exit", "/new", "/model", "/extensions",
		"/plugins", "/tree", "/context", "/t", "/thinking", "/v", "/verbose",
		"/status", "/login", "/mouse", "/skills", "/instructions", "/mcp", "/cd":
		return true
	}
	return slices.ContainsFunc(m.CommandMenu.Catalog, func(cmd daemon.SessionCommand) bool {
		return cmd.Name == token
	})
}

func (m *ChatModel) submitInput(input string, cmds *[]tea.Cmd) {
	if strings.HasPrefix(input, "/") && m.isRecognizedCommand(input) {
		m.handleSubmittedCommand(input, cmds)
		return
	}

	if m.pendingSendCount() >= MaxPendingUsers {
		m.AddError("Too many messages are waiting. Wait for the current reply to finish before sending another message.")
		m.refreshViewportContent()
		return
	}

	m.ClearNotices()
	m.TurnFailed = false
	m.Stopped = false

	continuation := input == "."
	image := m.AttachedImage
	if continuation {
		image = nil
	}
	handle, err := m.client.PrepareTurn(input, image, continuation)
	if err != nil {
		m.AddError(err.Error())
		return
	}
	cmd := m.sendCmd(handle, input, image, continuation)
	if continuation {
		if m.pendingContinuations == nil {
			m.pendingContinuations = make(map[string]pendingOperation)
		}
		m.pendingContinuations[handle.ID()] = pendingOperation{Handle: handle}
	}
	if !continuation {
		m.AttachedImage = nil
		m.pendingUsers = append(m.pendingUsers, PendingUserTurn{Text: input, Image: image, At: time.Now().UnixMilli(), Handle: handle, OperationID: handle.ID()})
	}
	m.isSending, m.sentHere, m.Follow = true, true, true
	m.reseedMood()
	m.refreshViewportContent()
	*cmds = append(*cmds, cmd, m.startAnimation())
}

func (m *ChatModel) handleSubmittedCommand(input string, cmds *[]tea.Cmd) {
	m.TextArea.Reset()
	m.syncLayout()
	trimmed := strings.TrimSpace(input)
	emit := func(msg tea.Msg) { *cmds = append(*cmds, func() tea.Msg { return msg }) }

	name, args, _ := strings.Cut(trimmed, " ")
	if slices.ContainsFunc(m.CommandMenu.Catalog, func(command daemon.SessionCommand) bool { return command.Name == name && command.Skill }) {
		if m.pendingSendCount() >= MaxPendingUsers {
			m.AddError("Too many messages are waiting.")
			return
		}
		handle, err := m.client.PrepareSkill(name, args)
		if err != nil {
			m.AddError(err.Error())
			return
		}
		m.pendingUsers = append(m.pendingUsers, PendingUserTurn{Text: trimmed, At: time.Now().UnixMilli(), Handle: handle, OperationID: handle.ID()})
		m.isSending, m.sentHere, m.Follow = true, true, true
		m.TurnFailed, m.Stopped = false, false
		*cmds = append(*cmds, m.sendCmd(handle, trimmed, nil, false), m.startAnimation())
		m.refreshViewportContent()
		return
	}

	switch trimmed {
	case "/agents":
		emit(ChatOpenAgentsMsg{})
	case "/a", "/sessions":
		emit(ChatBackToSessionsMsg{})
	case "/q", "/quit", "/exit":
		m.Close()
		emit(ChatQuitMsg{})
	case "/new":
		emit(ChatNewSessionMsg{})
	case "/model":
		emit(ChatOpenModelPickerMsg{})
	case "/extensions", "/plugins":
		emit(ChatOpenExtensionPickerMsg{})
	case "/tree":
		emit(ChatOpenTreePickerMsg{})
	case "/context":
		emit(ChatOpenContextInspectorMsg{})
	case "/webhooks":
		emit(ChatOpenWebhooksPageMsg{})
	case "/skills", "/instructions", "/mcp":
		emit(ChatOpenCapabilityPageMsg{Kind: trimmed[1:]})
	case "/t", "/thinking", "/v", "/verbose":
		if trimmed == "/t" || trimmed == "/thinking" {
			m.Flags.Thinking = !m.Flags.Thinking
		} else {
			m.Flags.Tools = !m.Flags.Tools
		}
		m.rebuildSettledLines()
		m.refreshViewportContent()
	case "/status":
		statusText := fmt.Sprintf("session: %s\nworkspace: %s\nmodel: %s", m.SessionID, m.Workspace, m.Model)
		if m.Effort != "" {
			statusText += "\neffort: " + m.Effort
		}
		if m.Usage != nil {
			statusText += "\ntokens: " + formatUsage(m.Usage)
		}
		m.appendSettledEntry(HistoryEntry{Kind: EntryNote, Text: statusText})
		m.refreshViewportContent()
	default:
		switch {
		case strings.HasPrefix(trimmed, "/model "):
			emit(ChatExecuteCommandMsg{Name: "/model", Args: strings.TrimSpace(trimmed[7:])})
		case strings.HasPrefix(trimmed, "/login"):
			emit(ChatOpenLoginMsg{Name: strings.TrimSpace(strings.TrimPrefix(trimmed, "/login"))})
		default:
			for _, cmd := range m.CommandMenu.Catalog {
				if cmd.Name == trimmed && cmd.Page != nil && *cmd.Page {
					emit(ChatOpenPageMsg{Command: trimmed})
					return
				}
			}
			cmdName, cmdArgs, _ := strings.Cut(trimmed, " ")
			emit(ChatExecuteCommandMsg{Name: cmdName, Args: cmdArgs})
		}
	}
}

func (m *ChatModel) handleStreamEvent(evt daemon.StreamEvent) {
	defer m.reseedMood()
	if evt.Replayed {
		// Replayed events do not describe current activity; preserve live status.
		defer func(live daemon.AgentStatus) { m.Status = live }(m.Status)
	}
	if evt.Type != daemon.EventToolProgress {
		m.Progress = nil
	}
	watchedThought := !m.transcript.thinkingSince.IsZero()
	entries := m.transcript.apply(evt, m.AgentName)
	for _, entry := range entries {
		m.appendSettledEntry(entry)
	}

	switch evt.Type {
	case daemon.EventReset:
		m.History.Clear()
		m.burstEpoch++
		m.settledLines = nil
		m.settledLinesBytes, m.droppedSettledLines = 0, 0
		m.clearAction()
		m.Usage = nil
		m.ClearNotices()
		m.TurnFailed, m.Stopping, m.Stopped = false, false, false
		m.Follow, m.scrollOffset = true, 0
		m.olderBefore, m.olderMore, m.loadingOlder = evt.Before, evt.More, false
	case daemon.EventCommitted:
		m.History.Stamp(evt.Seq)
	case daemon.EventRetry:
		m.clearAction()
	case daemon.EventUser:
		m.Stopped, m.TurnFailed = false, false
		m.clearAction()
		if !evt.Replayed {
			m.ClearNotices()
		}
		if evt.OperationID != "" {
			if i := slices.IndexFunc(m.pendingUsers, func(p PendingUserTurn) bool { return p.OperationID == evt.OperationID }); i >= 0 {
				m.pendingUsers = slices.Delete(m.pendingUsers, i, i+1)
			}
		}
	case daemon.EventText, daemon.EventThinking:
		if evt.Text != "" {
			m.ToolProgressText, m.ThoughtProgressText = "", ""
			m.Status.Running, m.Status.Idle, m.Status.Phase = true, false, &phaseReasoning
			// A thought flushed at the buffer cap keeps its last compact line
			// until the next delta, just like an explicitly settled thought.
			if evt.Type == daemon.EventThinking && m.transcript.activeText == "" && !m.transcript.thinkingSince.IsZero() {
				for _, entry := range entries {
					if entry.Kind == EntryThinking {
						m.ThoughtProgressText = cmp.Or(thinkingLine(entry.Text), "thinking")
					}
				}
			}
		}
	case daemon.EventToolProgress:
		if evt.Replayed {
			break // A progress snapshot is not an action happening now.
		}
		m.Progress = evt.Progress
		if evt.Progress != nil {
			m.ThoughtProgressText = ""
			m.Status.Running, m.Status.Idle, m.Status.Phase = true, false, &phaseTool
			m.inFlight = evt.Progress
			m.ToolProgressText = actionLabel(evt.Progress, nil)
		}
	case daemon.EventTool:
		m.ThoughtProgressText = ""
		m.Status.Running, m.Status.Idle = true, false
		m.ToolProgressText = ""
		if !evt.Replayed {
			for i := len(entries) - 1; i >= 0; i-- {
				if entries[i].Kind == EntryTool {
					m.ToolProgressText = actionLabel(m.inFlight, &entries[i])
					break
				}
			}
		}
		m.inFlight = nil
	case daemon.EventMessage, daemon.EventNote, daemon.EventCompacted:
		m.clearAction()
	case daemon.EventError:
		m.TurnFailed = true
		m.clearAction()
		m.Status.Running, m.Status.Idle, m.Status.Phase = false, true, &phaseResting
	case daemon.EventUsage:
		m.Usage = evt.Usage
		if watchedThought {
			for _, entry := range entries {
				if entry.Kind == EntryThinking {
					m.ThoughtProgressText = cmp.Or(thinkingLine(entry.Text), "thinking")
				}
			}
		}
	case daemon.EventInterrupted:
		m.Stopping, m.Stopped, m.TurnFailed = false, true, false
		m.clearAction()
		m.Status.Running, m.Status.Idle, m.Status.Phase = false, true, &phaseResting
	}
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
	return formatTokens(total) + " tokens" + rate
}

func formatTokens(val int) string {
	switch {
	case val >= 1_000_000:
		return fmt.Sprintf("%.1fm", float64(val)/1_000_000.0)
	case val >= 1_000:
		return fmt.Sprintf("%.1fk", float64(val)/1_000.0)
	default:
		return strconv.Itoa(val)
	}
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

// intentVerbs name an intent while its call is written, while it runs, and
// once it ran.
var intentVerbs = map[string]struct{ generating, running, done string }{
	"read":  {"reading", "reading", "read"},
	"write": {"writing", "writing", "wrote"},
	"edit":  {"editing", "editing", "edited"},
	"run":   {"preparing", "running", "ran"},
}

// actionLabel is the action row for a call, live from its progress and then
// from its result, so the row holds the last action until the next begins.
// A call that said what it does (read a file, ran a command) is named by
// that; any other is named by the call itself, as its settled tool row is.
func actionLabel(progress *daemon.ToolProgress, result *HistoryEntry) string {
	if progress != nil && progress.Intent != nil {
		verbs := intentVerbs[progress.Intent.Kind]
		verb := verbs.running
		switch {
		case result != nil:
			verb = verbs.done
		case progress.Phase == "generating":
			verb = verbs.generating
		}
		label := verb + " " + progress.Intent.Target
		if result != nil && toolFailed(*result) {
			label += " · failed"
		}
		return label
	}
	switch {
	case result != nil:
		head, tail := toolRowParts(*result, toolFailed(*result), "")
		return head + tail
	case progress.Phase == "generating":
		return "making a " + progress.Name + " call"
	case progress.Code != nil && progress.Code.Text != "":
		return toolSummary(HistoryEntry{ToolName: progress.Name, ToolArgs: map[string]any{"code": progress.Code.Text}})
	}
	return "running " + progress.Name
}

// renderProgress holds the last tool action in one row; a call still being
// generated also shows the newest end of its code.
func (m ChatModel) renderProgress() string {
	width := max(1, m.Renderer.BodyWidth-railWidth)
	row := oneLine(m.ToolProgressText)
	if m.Progress != nil && m.Progress.Phase == "generating" && m.Progress.Code != nil {
		code := m.Progress.Code
		if text := oneLine(code.Text); text != "" {
			row += " · "
			if room := width - ansi.StringWidth(row); room >= 12 && ansi.StringWidth(text) > room {
				text = ansi.TruncateLeft(text, ansi.StringWidth(text)-room+1, "…")
			}
			row += text
		}
	}
	return markChrome + m.Styles.Faint.Render(ansi.Truncate(row, width, "…"))
}

// renderThought follows the newest line while the thought streams.
func (m ChatModel) renderThought() string {
	header := cmp.Or(thinkingLine(m.transcript.activeText), "thinking")
	width := max(1, m.Renderer.BodyWidth-railWidth)
	return markChrome + m.Styles.Faint.Render(ansi.Truncate(header+"…", width, "…"))
}

func (m ChatModel) statusLine() string {
	if m.TurnFailed || m.Notices.HasError() {
		return "Reply failed · see error above"
	}
	if m.Stopping {
		return "stopping…"
	}
	// an idle session says nothing unless verbose: the transcript already
	// ends in the turn's signoff.
	if m.Stopped {
		if m.Flags.Tools {
			return "stopped"
		}
		return ""
	}
	if host := m.reaching(); host != "" {
		return "connecting to " + host + "…"
	}
	// the port owner gave up and forgot the kernel, so nothing reattaches
	if host, _ := daemon.SplitLocation(m.Workspace); host != "" && m.Status.KernelLink == "lost" {
		return "kernel on " + cmp.Or(m.Host, host) + " lost · the next turn starts a fresh one"
	}
	if m.isSending || m.pendingSendCount() > 0 && !m.Status.Running {
		return "preparing"
	}
	if m.Progress != nil {
		if m.Progress.Phase == "generating" {
			return "generating call"
		}
		return "running " + m.Progress.Name
	}
	if m.Status.Running && !m.Status.Idle {
		if m.transcript.activeKind == StreamKindText {
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
	if m.connecting() {
		return "connecting…"
	}
	if m.Flags.Tools {
		return "ready"
	}
	return ""
}

// Phase is optional display metadata, not evidence of an unanswered status.
func (m ChatModel) connecting() bool {
	return m.Status.Phase == nil && !m.Status.Running && !m.Status.Idle
}

// phaseMood is the face class for the phase statusLine names.
func (m ChatModel) phaseMood() mood {
	switch {
	case m.Stopping:
		return moodStopping
	case m.isSending || m.pendingSendCount() > 0 && !m.Status.Running:
		return moodPreparing
	case m.Progress != nil:
		return moodWorking
	case m.transcript.activeKind == StreamKindText:
		return moodResponding
	case m.Status.Phase != nil:
		switch *m.Status.Phase {
		case daemon.PhaseTool:
			return moodWorking
		case daemon.PhaseCompacting:
			return moodCompacting
		case daemon.PhasePreparing:
			return moodPreparing
		}
	}
	return moodThinking
}

// header fits the workspace and the model on one rule without cutting either
// short, shedding the least useful parts first: the middle of the path, the
// brand, the glance counts from the last, then the path down to its name,
// which alone may squeeze the rule to one cell.
func (m ChatModel) header(width int) string {
	host, workspace := daemon.SplitLocation(cmp.Or(m.Workspace, "chat"))
	// a remote workspace's host stays whole in every layout
	lead := ""
	if host == "" {
		workspace = homePath(workspace)
	} else {
		host = cmp.Or(m.Host, host)
		lead = host + ":"
		workspace = underHome(workspace, m.hostHome)
	}
	model := m.Model
	if m.Effort != "" {
		model += ":" + m.Effort
	}
	counts := m.glanceCounts()
	folds := pathFolds(workspace)
	type layout struct {
		place  string
		counts int
		rule   int
		brand  bool
	}
	var layouts []layout
	for _, place := range folds {
		layouts = append(layouts, layout{brand: true, place: place, counts: len(counts), rule: 3})
	}
	for n := len(counts); n >= 0; n-- {
		layouts = append(layouts, layout{brand: false, place: folds[len(folds)-1], counts: n, rule: 3})
	}
	layouts = append(layouts, layout{brand: false, place: filepath.Base(workspace), counts: 0, rule: 1})
	for _, l := range layouts {
		right := strings.Join(append(counts[:l.counts:l.counts], model), "  ")
		left := lead + l.place
		if l.brand {
			left = "✦ " + m.AgentName + " on " + left
		}
		if lipgloss.Width(left)+lipgloss.Width(right)+l.rule+2 > width {
			continue
		}
		place := m.Styles.Muted.Render(l.place)
		if host != "" {
			place = m.hostSegment(host) + m.Styles.Muted.Render(":"+l.place)
		}
		if l.brand {
			return titleRule(width, brand(m.AgentName)+m.Styles.Faint.Render(" on ")+place, m.Styles.Faint.Render(right))
		}
		return titleRule(width, place, m.Styles.Faint.Render(right))
	}
	return m.Styles.Faint.Render(ansi.Truncate(model, width, "…"))
}

// hostSegment is the header's host in its own color once the kernel there is
// attached: faint while it boots or reattaches, the error color once lost.
func (m ChatModel) hostSegment(host string) string {
	switch m.Status.KernelLink {
	case "booting", "reattaching":
		return m.Styles.Faint.Render(host)
	case "lost":
		return m.Styles.Error.Render(host)
	}
	return hostStyle(host).Render(host)
}

// reaching is the remote host a booting or reattaching kernel is on.
func (m ChatModel) reaching() string {
	host, _ := daemon.SplitLocation(m.Workspace)
	if link := m.Status.KernelLink; host == "" || link != "booting" && link != "reattaching" {
		return ""
	}
	return cmp.Or(m.Host, host)
}

func (m ChatModel) View() string {
	width := m.chatWidth()
	pad := strings.Repeat(" ", m.padding())
	var rows []string
	rows = append(rows, m.header(width), "")
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
	if m.History.Len() == 0 && len(m.pendingUsers) == 0 && m.transcript.activeText == "" && m.ToolProgressText == "" {
		textWidth := max(1, min(m.Renderer.BodyWidth, m.Viewport.Width())-railWidth)
		var emptyRows []string
		for _, line := range wrapOrChunkLine("What would you like to work on?", textWidth) {
			emptyRows = append(emptyRows, m.Renderer.rail(laneNone)+m.Styles.Faint.Render(line))
		}
		view = strings.Join(emptyRows, "\n")
	}
	if m.sidebarWidth() > 0 {
		view = lipgloss.JoinHorizontal(lipgloss.Top, view, "  ", m.renderGlances())
	}
	content := strings.Split(view, "\n")
	for len(content) < m.Viewport.Height() {
		content = append(content, "")
	}
	content = content[:min(len(content), m.Viewport.Height())]
	if m.dragAnchor != nil {
		// the selection is in transcript rows; the viewport shows from scrollOffset
		anchor, head := *m.dragAnchor, m.dragHead
		anchor.Row, head.Row = anchor.Row-m.scrollOffset, head.Row-m.scrollOffset
		content = HighlightSelection(content, Selection{Anchor: anchor, Head: head, Gutter: railWidth})
	}
	rows = append(rows, content...)
	status := m.statusLine()
	// the face trails the text, so its frames never move anything
	if m.animating() && !m.TurnFailed && !m.Notices.HasError() {
		status = m.Styles.Faint.Render(status) + " " + m.Styles.Agent.Render(m.phaseMood().frame(m.moodSeed, m.ProgressFrame))
	}
	if !m.Follow {
		status = fmt.Sprintf("history · %d rows below · pgdn", max(0, m.scrollLimit-m.scrollOffset))
	}
	if m.AttachedImage != nil {
		status = daemon.ImageLabel(m.AttachedImage.ImageMetadata) + " attached · esc remove"
	}
	if m.CopyStatus != "" {
		status = m.CopyStatus
	}
	statusStyle := m.Styles.Faint
	if m.TurnFailed || m.Notices.HasError() {
		statusStyle = m.Styles.Error
	}
	rows = append(rows, statusStyle.Render(status))
	rows = append(rows, m.Styles.Decor.Render(strings.Repeat("─", width)))
	if len(m.effortOptions) > 0 {
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
	return !m.connecting() && !m.animating()
}

// glanceCounts counts each glance with rows that the sidebar leaves out: all
// of them without a sidebar, the ones after its first with one.
func (m ChatModel) glanceCounts() []string {
	var counts []string
	for _, g := range m.Glances {
		if len(g.Rows) > 0 {
			counts = append(counts, fmt.Sprintf("%s %d", g.Title, len(g.Rows)))
		}
	}
	if len(counts) > 0 && m.sidebarWidth() > 0 {
		counts = counts[1:]
	}
	if m.Status.KernelStale {
		counts = append([]string{"kernel older"}, counts...)
	}
	return counts
}

func (m ChatModel) renderGlances() string {
	for _, g := range m.Glances {
		if len(g.Rows) == 0 {
			continue
		}
		room := max(0, min(m.Viewport.Height(), 12)-1)
		shown := min(room, len(g.Rows))
		if len(g.Rows) > room {
			shown = max(0, room-1)
		}
		rows := []string{m.Styles.Faint.Render(fmt.Sprintf("%s · %d", g.Title, len(g.Rows)))}
		for _, item := range g.Rows[:shown] {
			mark, style := "○", m.Styles.Faint
			switch item.Tone {
			case ToneActive:
				mark, style = "●", m.Styles.Success
			case ToneWarning:
				mark, style = "!", m.Styles.Warning
			case ToneMuted:
				mark = "✓"
			}
			label := item.Text
			if item.ID != "" {
				label = "#" + item.ID + " " + item.Text
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
		right string
		left  []hint
	}{
		{left: []hint{commands, {"shift+↑↓", "your messages"}, {"ctrl+j", "diffs"}, {"ctrl+o", "agents"}}, right: right},
		{left: []hint{commands, {"ctrl+j", "diffs"}, {"ctrl+o", "agents"}}, right: right},
		{left: []hint{commands, {"ctrl+o", "agents"}}, right: compact},
		{left: []hint{commands, {"ctrl+j", "diffs"}}, right: compact},
		{left: []hint{commands}, right: compact},
		{left: []hint{{"/", ""}}, right: compact},
	}
	for _, c := range candidates {
		left := keyHints(c.left...)
		if gap := width - lipgloss.Width(left) - lipgloss.Width(c.right); gap > 0 {
			return left + strings.Repeat(" ", gap) + c.right
		}
	}
	return ansi.Truncate(keyHints(commands), width, "…")
}

// contextStat is how much of the prompt was read from cache, fading as the
// provider lets its cache go, and how full the context is: "392k/396k cached
// (38%)", with a shorter form for narrow footers. The share turns yellow near
// the window, where compaction starts.
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
	ratio := m.Styles.Muted.Render(count(cachedNow(usage, time.Now())) + "/" + count(usage.PromptTokens))
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

// cachedNow is what a request would read from cache at now: the measured
// count until the cache starts to fade, then each step it has reached.
func cachedNow(u *daemon.Usage, now time.Time) *int {
	cached := u.CachedPromptTokens
	for _, step := range u.CacheFade {
		if step.At > now.UnixMilli() {
			break
		}
		cached = step.Cached
	}
	return cached
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

func (m ChatModel) pendingSendCount() int {
	count := 0
	for _, pending := range m.pendingUsers {
		if !pending.Expired {
			count++
		}
	}
	return count
}

func (m ChatModel) operationRecoverable(id string) bool {
	for _, pending := range m.pendingUsers {
		if pending.OperationID == id {
			return !pending.Expired
		}
	}
	pending, exists := m.pendingContinuations[id]
	return exists && !pending.Expired
}
