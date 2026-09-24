package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"math"
	"net/url"
	"strings"
	"unicode/utf16"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
	"golang.org/x/text/language"
	"golang.org/x/text/message"
)

type ContextSection struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Kind      string `json:"kind"` // "instructions" | "extension_context" | "history" | "tools" | "other"
	Source    string `json:"source"`
	ItemCount int    `json:"item_count"`
	ByteCount int    `json:"byte_count"`
	Preview   string `json:"preview"`
	Pages     int    `json:"pages"`
}

type CompactionState struct {
	Strategy             string   `json:"strategy,omitempty"`
	Status               string   `json:"status"` // "not_configured" | "not_needed" | "compacted" | "unknown"
	Source               string   `json:"source,omitempty"`
	TriggerFreePercent   *float64 `json:"trigger_free_percent,omitempty"`
	InputLimitTokens     *int     `json:"input_limit_tokens,omitempty"`
	EstimatedInputTokens *int     `json:"estimated_input_tokens,omitempty"`
	EstimateMethod       string   `json:"estimate_method,omitempty"`
	BeforeItems          *int     `json:"before_items,omitempty"`
	AfterItems           *int     `json:"after_items,omitempty"`
}

type ContextSnapshot struct {
	State               string           `json:"state"` // "pending" | "ready"
	Reason              string           `json:"reason,omitempty"`
	CapturedAt          *int64           `json:"captured_at,omitempty"`
	Provider            string           `json:"provider,omitempty"`
	Model               string           `json:"model,omitempty"`
	Protocol            string           `json:"protocol,omitempty"`
	ContextWindowTokens *int             `json:"context_window_tokens,omitempty"`
	Sections            []ContextSection `json:"sections,omitempty"`
	Compaction          CompactionState  `json:"compaction,omitempty"`
}

type ContextPage struct {
	Section string `json:"section"`
	Page    int    `json:"page"`
	Pages   int    `json:"pages"`
	Content string `json:"content"`
	Omitted string `json:"omitted,omitempty"`
}

type ContextDetail struct {
	Section ContextSection
	Page    int
	Value   *ContextPage
	Error   string
	Scroll  int
}

type ContextDoneMsg struct{}

type contextSnapshotLoadedMsg struct {
	Snapshot *ContextSnapshot
	Err      error
	Gen      int
}

type contextPageLoadedMsg struct {
	SectionID string
	Page      int
	Data      *ContextPage
	Err       error
	Gen       int
}

type ContextInspectorModel struct {
	Conn       *daemon.Connection
	SessionID  string
	Snapshot   *ContextSnapshot
	Cursor     int
	Detail     *ContextDetail
	Loading    bool
	Error      string
	Generation int
	Width      int
	Height     int
	Styles     Styles
}

func NewContextInspectorModel(conn *daemon.Connection, sessionID string) ContextInspectorModel {
	return ContextInspectorModel{
		Conn:      conn,
		SessionID: sessionID,
		Loading:   true,
		Styles:    DefaultStyles,
	}
}

func (m *ContextInspectorModel) SetSize(width, height int) {
	m.Width = width
	m.Height = height
}

func (m ContextInspectorModel) Init() tea.Cmd {
	return m.loadSnapshotCmd(m.Generation)
}

func jsLength(s string) int { return len(utf16.Encode([]rune(s))) }

func validContextSnapshot(s ContextSnapshot) error {
	if s.State == "pending" {
		if jsLength(s.Reason) <= 500 {
			return nil
		}
		return errors.New("daemon returned invalid context metadata")
	}
	if s.State != "ready" || jsLength(s.Model) > 512 || s.Sections == nil || len(s.Sections) > 1000 ||
		jsLength(s.Provider) > 512 || jsLength(s.Protocol) > 512 || s.CapturedAt != nil && *s.CapturedAt < 0 ||
		s.ContextWindowTokens != nil && *s.ContextWindowTokens < 0 {
		return errors.New("daemon returned invalid context metadata")
	}
	kinds := map[string]bool{"instructions": true, "extension_context": true, "history": true, "tools": true, "other": true}
	for _, sec := range s.Sections {
		if sec.ID == "" || jsLength(sec.ID) > 200 || sec.Label == "" || jsLength(sec.Label) > 200 || !kinds[sec.Kind] ||
			jsLength(sec.Source) > 500 || sec.ItemCount < 0 || sec.ByteCount < 0 || jsLength(sec.Preview) > 2000 || sec.Pages < 0 || sec.Pages > 10000 {
			return errors.New("daemon returned invalid context section metadata")
		}
	}
	c := s.Compaction
	statuses := map[string]bool{"not_configured": true, "not_needed": true, "compacted": true, "unknown": true}
	if !statuses[c.Status] || jsLength(c.Strategy) > 200 || jsLength(c.Source) > 500 || jsLength(c.EstimateMethod) > 500 ||
		c.TriggerFreePercent != nil && (math.IsNaN(*c.TriggerFreePercent) || math.IsInf(*c.TriggerFreePercent, 0) || *c.TriggerFreePercent < 0 || *c.TriggerFreePercent > 100) ||
		c.InputLimitTokens != nil && *c.InputLimitTokens < 0 || c.EstimatedInputTokens != nil && *c.EstimatedInputTokens < 0 ||
		c.BeforeItems != nil && *c.BeforeItems < 0 || c.AfterItems != nil && *c.AfterItems < 0 {
		return errors.New("daemon returned invalid compaction metadata")
	}
	return nil
}

func validContextPage(p ContextPage, sectionID string) error {
	if p.Section != sectionID || p.Page < 0 || p.Pages < 0 || p.Pages > 10000 || p.Page >= max(1, p.Pages) || jsLength(p.Content) > 65536 || jsLength(p.Omitted) > 1000 {
		return errors.New("daemon returned invalid context page")
	}
	return nil
}

func (m ContextInspectorModel) loadSnapshotCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return contextSnapshotLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}

		health, err := daemon.Request[struct {
			Capabilities []string `json:"capabilities"`
		}](context.Background(), m.Conn, "/health", nil)
		if err == nil {
			hasCap := false
			for _, c := range health.Capabilities {
				if c == "session_context" {
					hasCap = true
					break
				}
			}
			if !hasCap {
				return contextSnapshotLoadedMsg{
					Err: errors.New("daemon upgrade needed for /context; when ready, run albedo daemon --stop, then albedo (this clears python variables)"),
					Gen: gen,
				}
			}
		}

		path := fmt.Sprintf("/sessions/%s/context", url.PathEscape(m.SessionID))
		snapshot, err := daemon.Request[ContextSnapshot](context.Background(), m.Conn, path, nil)
		if err != nil {
			return contextSnapshotLoadedMsg{Err: err, Gen: gen}
		}
		if err := validContextSnapshot(snapshot); err != nil {
			return contextSnapshotLoadedMsg{Err: err, Gen: gen}
		}
		return contextSnapshotLoadedMsg{Snapshot: &snapshot, Gen: gen}
	}
}

func (m ContextInspectorModel) loadPageCmd(sectionID string, page int, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return contextPageLoadedMsg{SectionID: sectionID, Page: page, Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		path := fmt.Sprintf("/sessions/%s/context/%s/%d", url.PathEscape(m.SessionID), url.PathEscape(sectionID), page)
		data, err := daemon.Request[ContextPage](context.Background(), m.Conn, path, nil)
		if err != nil {
			return contextPageLoadedMsg{SectionID: sectionID, Page: page, Err: err, Gen: gen}
		}
		if err := validContextPage(data, sectionID); err != nil {
			return contextPageLoadedMsg{SectionID: sectionID, Page: page, Err: err, Gen: gen}
		}
		return contextPageLoadedMsg{SectionID: sectionID, Page: page, Data: &data, Gen: gen}
	}
}

func (m ContextInspectorModel) Update(msg tea.Msg) (ContextInspectorModel, tea.Cmd) {
	switch msg := msg.(type) {
	case contextSnapshotLoadedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Loading = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil
		}
		m.Snapshot = msg.Snapshot
		m.Error = ""
		if m.Snapshot != nil && m.Cursor >= len(m.Snapshot.Sections) {
			m.Cursor = max(0, len(m.Snapshot.Sections)-1)
		}
		return m, nil

	case contextPageLoadedMsg:
		if msg.Gen != m.Generation || m.Detail == nil || m.Detail.Section.ID != msg.SectionID || m.Detail.Page != msg.Page {
			return m, nil
		}
		if msg.Err != nil {
			m.Detail.Error = msg.Err.Error()
		} else {
			m.Detail.Value = msg.Data
			m.Detail.Error = ""
		}
		return m, nil

	case tea.KeyMsg:
		if msg.Type == tea.KeyEsc || msg.Type == tea.KeyCtrlC || msg.Type == tea.KeyCtrlD {
			if m.Detail != nil {
				m.Detail = nil
				m.Generation++
				return m, nil
			}
			return m, func() tea.Msg { return ContextDoneMsg{} }
		}

		if m.Detail != nil {
			lines := []string{}
			if m.Detail.Value != nil {
				lines = wrapContextContent(m.Detail.Value.Content, max(1, m.Width-4))
			}
			visibleRows := max(1, m.Height-7)
			maxScroll := max(0, len(lines)-visibleRows)

			switch msg.Type {
			case tea.KeyLeft:
				if m.Detail.Page > 0 {
					m.Detail.Page--
					m.Detail.Value = nil
					m.Detail.Scroll = 0
					m.Detail.Error = ""
					m.Generation++
					return m, m.loadPageCmd(m.Detail.Section.ID, m.Detail.Page, m.Generation)
				}
			case tea.KeyRight:
				if m.Detail.Page+1 < m.Detail.Section.Pages {
					m.Detail.Page++
					m.Detail.Value = nil
					m.Detail.Scroll = 0
					m.Detail.Error = ""
					m.Generation++
					return m, m.loadPageCmd(m.Detail.Section.ID, m.Detail.Page, m.Generation)
				}
			case tea.KeyUp:
				if m.Detail.Scroll > 0 {
					m.Detail.Scroll--
				}
			case tea.KeyDown:
				if m.Detail.Scroll < maxScroll {
					m.Detail.Scroll++
				}
			case tea.KeyPgUp:
				m.Detail.Scroll = max(0, m.Detail.Scroll-visibleRows)
			case tea.KeyPgDown:
				m.Detail.Scroll = min(maxScroll, m.Detail.Scroll+visibleRows)
			}
			return m, nil
		}

		if strings.ToLower(msg.String()) == "r" {
			m.Loading = true
			m.Snapshot = nil
			m.Detail = nil
			m.Error = ""
			m.Generation++
			return m, m.loadSnapshotCmd(m.Generation)
		}

		switch msg.Type {
		case tea.KeyUp, tea.KeyCtrlP:
			if m.Cursor > 0 {
				m.Cursor--
			}
		case tea.KeyDown, tea.KeyCtrlN:
			if m.Snapshot != nil && m.Cursor < len(m.Snapshot.Sections)-1 {
				m.Cursor++
			}
		case tea.KeyEnter:
			if m.Snapshot != nil && len(m.Snapshot.Sections) > m.Cursor {
				sec := m.Snapshot.Sections[m.Cursor]
				if sec.Pages > 0 {
					m.Detail = &ContextDetail{
						Section: sec,
						Page:    0,
						Scroll:  0,
					}
					m.Generation++
					return m, m.loadPageCmd(sec.ID, 0, m.Generation)
				}
			}
		}
	}

	return m, nil
}

func wrapContextContent(content string, width int) []string {
	if width <= 1 {
		width = 76
	}
	return strings.Split(ansi.Wrap(content, width, " "), "\n")
}

func contextCount(n int, unit string) string {
	value := message.NewPrinter(language.English).Sprintf("%d", n)
	if n != 1 {
		unit += "s"
	}
	return value + " " + unit
}

func (m ContextInspectorModel) View() string {
	var b strings.Builder
	line := func(text string) { b.WriteString(text); b.WriteByte('\n') }
	faint := func(text string) { line(m.Styles.Faint.Render(text)) }
	if m.Detail != nil {
		sec, d := m.Detail.Section, m.Detail
		line(titleRule(m.Width, brand("albedo")+" "+m.Styles.Muted.Render("/context"), m.Styles.Faint.Render(sec.Label)))
		faint(fmt.Sprintf("%s · page %d/%d · %s", sec.Source, d.Page+1, sec.Pages, contextCount(sec.ByteCount, "byte")))
		if d.Error != "" {
			line(DefaultStyles.Error.Render(d.Error))
		} else if d.Value == nil {
			faint("loading inspectable prepared content…")
		} else {
			if d.Value.Omitted != "" {
				line(DefaultStyles.Warning.Render("omitted: " + d.Value.Omitted))
			}
			line("")
			rows := wrapContextContent(d.Value.Content, m.Width-4)
			visible := max(1, m.Height-7)
			if m.Height <= 0 {
				visible = 17
			}
			for _, row := range rows[min(d.Scroll, len(rows)):min(len(rows), d.Scroll+visible)] {
				line(row)
			}
		}
		line(keyHints(hint{"↑↓", "scroll"}, hint{"pgup/pgdn", "jump"}, hint{"←→", "page"}, hint{"esc", "sections"}))
		return strings.TrimSuffix(b.String(), "\n")
	}
	line(titleRule(m.Width, brand("albedo")+" "+m.Styles.Muted.Render("/context"), m.Styles.Faint.Render("prepared request")))
	faint(inkWrap("read-only · durable transcript and request-only context are separate", m.Width))
	if m.Error != "" {
		line(DefaultStyles.Error.Render(m.Error))
	}
	if m.Loading && m.Snapshot == nil && m.Error == "" {
		faint("loading prepared request snapshot…")
	} else if m.Snapshot == nil {
		line(keyHints(hint{"r", "retry"}, hint{"esc", "return to chat"}))
	} else if m.Snapshot.State == "pending" {
		line(DefaultStyles.Warning.Render("pending · no request has been prepared for this runtime session"))
		faint(m.Snapshot.Reason)
		line(keyHints(hint{"r", "refresh"}, hint{"esc", "return to chat"}))
	} else {
		snap := m.Snapshot
		label := snap.Model
		if snap.Provider != "" {
			label = snap.Provider + " · " + label
		}
		if snap.Protocol != "" {
			label += " · " + snap.Protocol
		}
		line(label)
		window := "not reported"
		if snap.ContextWindowTokens != nil {
			window = contextCount(*snap.ContextWindowTokens, "token") + " (configured)"
		}
		faint(inkWrap("context window: "+window, m.Width))
		status := map[string]string{"not_configured": "not configured", "not_needed": "not needed", "compacted": "applied", "unknown": "state unavailable"}[snap.Compaction.Status]
		strategy := snap.Compaction.Strategy
		if strategy == "" {
			strategy = "none"
		}
		faint("compaction: " + strategy + " · " + status)
		if snap.Compaction.TriggerFreePercent != nil {
			faint(fmt.Sprintf("trigger: keep %g%% free", *snap.Compaction.TriggerFreePercent))
		}
		if snap.Compaction.EstimatedInputTokens != nil {
			method := snap.Compaction.EstimateMethod
			if method == "" {
				method = "method not reported"
			}
			faint("estimated input: " + contextCount(*snap.Compaction.EstimatedInputTokens, "token") + " · " + method)
		}
		line("")
		capacity := max(1, (m.Height-9)/3)
		if m.Height <= 0 {
			capacity = 5
		}
		first := min(max(0, m.Cursor-capacity/2), max(0, len(snap.Sections)-capacity))
		for i := first; i < min(len(snap.Sections), first+capacity); i++ {
			sec := snap.Sections[i]
			marker := " "
			if i == m.Cursor {
				marker = selectBar()
			}
			label := fmt.Sprintf("%s %d. %s ", marker, i+1, sec.Label) + DefaultStyles.Faint.Render("· "+sec.Source)
			if i == m.Cursor {
				label = selectedLine(label, m.Width)
			}
			line(label)
			available := "content unavailable"
			if sec.Pages > 0 {
				available = contextCount(sec.Pages, "page")
			}
			faint("  " + contextCount(sec.ItemCount, "item") + " · " + contextCount(sec.ByteCount, "measured byte") + " · " + available)
			if i == m.Cursor && sec.Preview != "" {
				line("  " + sec.Preview)
			}
		}
		if len(snap.Sections) == 0 {
			faint("the prepared request contains no inspectable sections")
		}
		if len(snap.Sections) > capacity {
			faint(fmt.Sprintf("showing %d–%d of %d sections", first+1, min(len(snap.Sections), first+capacity), len(snap.Sections)))
		}
		line(inkWrap(keyHints(hint{"↑↓", "select"}, hint{"enter", "inspect content"}, hint{"r", "refresh"}, hint{"esc", "return to chat"}), m.Width))
	}
	return strings.TrimSuffix(b.String(), "\n")
}
