package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"fmt"
	"regexp"
	"strings"
	"time"

	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

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

type PendingUserTurn struct {
	Expired        bool
	Handle         *daemon.OperationHandle
	OperationID    string
	BlockingReason string
	Images         []daemon.ImageAttachment
	Pastes         []string
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

// liveRowsKey is what the cached rows of the reply streaming in were
// rendered for: the same transcript end as a burst, and the reply itself.
type liveRowsKey struct {
	burstRowsKey
	text string
	kind EntryKind
}

// liveFrame is the shortest wait between two renderings of a growing reply.
const liveFrame = 33 * time.Millisecond

type ChatModel struct {
	Styles Styles

	streamCtx        context.Context
	Usage            *daemon.Usage
	progressByCallID map[string]*daemon.ToolProgress
	progressOrder    []string
	eventChan        chan streamDelivery
	streamStopped    bool
	// Images and Pastes are what was pasted into the composer as markers.
	Images promptImages
	Pastes promptPastes
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
	settledToolLabel    string
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
	burstRows []string
	// liveRows is the reply streaming in, rendered whole. While only its
	// text grows it is rendered again at most once per liveInterval, a few
	// times what the last rendering took, so a long reply cannot spend the
	// whole stream re-rendering itself; liveDue is a later redraw on its way.
	liveRows     []string
	liveRowsKey  liveRowsKey
	liveDrawn    time.Time
	liveInterval time.Duration
	liveDue      bool
	Notices      Notices
	settledLines []string

	pendingUsers         []PendingUserTurn
	pendingContinuations map[string]pendingOperation
	Glances              []PageGlance
	// layoutSidebar is the sidebar width the last layout reserved.
	layoutSidebar int
	frameLines    []string
	CommandMenu   CommandMenuModel
	Viewport      viewport.Model

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
	statusPoll          uint64
	// statusPollResting is set while the next status poll is the slow one.
	statusPollResting bool
	scrollOffset      int

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
		Glances:      session.Glances,
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

func (m ChatModel) update(msg tea.Msg) (ChatModel, tea.Cmd) {
	if cmd, handled := m.handleOperationResults(msg); handled {
		return m, cmd
	}
	if cmd, handled := m.handleInput(msg); handled {
		return m, cmd
	}
	var cmds []tea.Cmd

	switch msg := msg.(type) {

	case ChatStatusPollMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation || msg.Poll != m.statusPoll || m.streamStopped {
			return m, nil
		}
		return m, m.statusCmd()

	case ChatStatusMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation || m.streamStopped {
			return m, nil
		}
		if msg.Err == nil && msg.Status != nil && msg.Revision == m.statusRevision {
			previousChrome := m.chromeRows()
			m.Status = *msg.Status
			m.Glances = msg.Glances
			if m.sidebarWidth() != m.layoutSidebar {
				m.SetSize(m.Width, m.Height)
			} else if m.chromeRows() != previousChrome {
				m.syncViewportHeight()
			}
			defer m.reseedMood()
			// most polls find the session idle with nothing live to settle
			live := m.latestProgress() != nil || m.settledToolLabel != "" || m.ThoughtProgressText != "" || m.transcript.activeKind != StreamKindNone || m.transcript.turn != nil && m.transcript.turn.begun()
			if live && (!m.Status.Running || m.Status.Idle) {
				m.settleActiveStream()
				m.clearAction()
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
		var wake tea.Cmd
		// only a live event outdates a status reply in flight
		if !msg.Event.Replayed {
			m.statusRevision++
			// a resting poll would learn of the new activity seconds late
			if m.statusPollResting {
				m.statusPollResting = false
				wake = m.statusCmd()
			}
		}
		if msg.Event.Type == daemon.EventInvalidate {
			return m, tea.Batch(m.waitForNextEvent(), wake)
		}
		before, entries := m.transcript, m.History.Len()
		m.handleStreamEvent(msg.Event)
		var draw tea.Cmd
		if m.onlyGrew(before, entries) && time.Since(m.liveDrawn) < m.liveInterval {
			draw = m.drawLiveLater()
		} else {
			m.refreshViewportContent()
		}

		var fade, window tea.Cmd
		if msg.Event.Type == daemon.EventUsage {
			fade, window = m.cacheFadeCmd(), m.windowCmd()
		}
		var reconcile []tea.Cmd
		if msg.Event.Type == daemon.EventReset {
			for _, pending := range m.pendingUsers {
				if pending.Handle != nil && !pending.Expired {
					reconcile = append(reconcile, m.queryOperationCmd(pending.Handle))
				}
			}
			for _, pending := range m.pendingContinuations {
				if pending.Handle != nil && !pending.Expired {
					reconcile = append(reconcile, m.queryOperationCmd(pending.Handle))
				}
			}
		}
		reconcile = append(reconcile, m.waitForNextEvent(), m.startAnimation(), window, fade, wake, draw)
		return m, tea.Batch(reconcile...)

	case ChatLiveDrawMsg:
		if msg.SessionID == m.SessionID && msg.Generation == m.Generation {
			m.liveDue = false
			m.refreshViewportContent()
		}
		return m, nil

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
		if msg.SessionID == m.SessionID && msg.Generation == m.Generation {
			m.clearAction()
			m.refreshViewportContent()
		}
		return m, nil

	case chatHostAuthMsg:
		m.offerSignIn(msg)
		return m, nil

	case chatSignedInMsg:
		m.signedIn(msg)
		return m, nil

	}

	return m, m.updateComposer(msg, cmds)
}
