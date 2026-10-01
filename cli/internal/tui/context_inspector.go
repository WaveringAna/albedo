package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"slices"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"golang.org/x/text/language"
	"golang.org/x/text/message"
)

type ContextSection struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Kind      string `json:"kind"` // "instructions" | "extension_context" | "history" | "tools" | "other"
	Source    string `json:"source"`
	Preview   string `json:"preview"`
	ItemCount int    `json:"item_count"`
	ByteCount int    `json:"byte_count"`
	Pages     int    `json:"pages"`
}

type CompactionState struct {
	TriggerFreePercent        *float64 `json:"trigger_free_percent,omitempty"`
	InputLimitTokens          *int     `json:"input_limit_tokens,omitempty"`
	EstimatedInputTokens      *int     `json:"estimated_input_tokens,omitempty"`
	ProviderInputTokens       *int     `json:"provider_input_tokens,omitempty"`
	ProviderCachedInputTokens *int     `json:"provider_cached_input_tokens,omitempty"`
	BeforeItems               *int     `json:"before_items,omitempty"`
	AfterItems                *int     `json:"after_items,omitempty"`
	Strategy                  string   `json:"strategy,omitempty"`
	Status                    string   `json:"status"` // "not_configured" | "not_needed" | "compacted" | "unknown"
	Source                    string   `json:"source,omitempty"`
	EstimateMethod            string   `json:"estimate_method,omitempty"`
}

type ContextSnapshot struct {
	Compaction          CompactionState  `json:"compaction"`
	CapturedAt          *int64           `json:"captured_at,omitempty"`
	ContextWindowTokens *int             `json:"context_window_tokens,omitempty"`
	State               string           `json:"state"` // "pending" | "ready"
	Reason              string           `json:"reason,omitempty"`
	Provider            string           `json:"provider,omitempty"`
	Model               string           `json:"model,omitempty"`
	Protocol            string           `json:"protocol,omitempty"`
	Sections            []ContextSection `json:"sections,omitempty"`
}

type ContextPage struct {
	Section string `json:"section"`
	Content string `json:"content"`
	Omitted string `json:"omitted,omitempty"`
	Page    int    `json:"page"`
	Pages   int    `json:"pages"`
}

type ContextDetail struct {
	Value   *ContextPage
	Error   string
	Section ContextSection
	Page    int
	Scroll  int
}

type ContextDoneMsg struct{}

type contextSnapshotLoadedMsg struct {
	Snapshot *ContextSnapshot
	Err      error
	Gen      int
}

type contextPageLoadedMsg struct {
	Err       error
	Data      *ContextPage
	SectionID string
	Page      int
	Gen       int
}

type ContextInspectorModel struct {
	Conn      *daemon.Connection
	SessionID string
	Snapshot  *ContextSnapshot
	Detail    *ContextDetail
	Styles    Styles
	page
}

func NewContextInspectorModel(conn *daemon.Connection, sessionID string) ContextInspectorModel {
	return ContextInspectorModel{
		Conn:      conn,
		SessionID: sessionID,
		page:      page{Loading: true},
		Styles:    DefaultStyles,
	}
}

func (m ContextInspectorModel) Init() tea.Cmd {
	return m.loadSnapshotCmd(m.Generation)
}

func utf16Length(s string) int {
	length := 0
	for _, char := range s {
		length++
		if char > 0xffff {
			length++
		}
	}
	return length
}

func isNeg(p *int) bool { return p != nil && *p < 0 }

var (
	validKinds         = []string{"instructions", "extension_context", "history", "tools", "other"}
	compactionStatuses = map[string]string{
		"not_configured": "not configured",
		"not_needed":     "not needed",
		"compacted":      "applied",
		"unknown":        "state unavailable",
	}
)

func validContextSnapshot(s ContextSnapshot) error {
	if s.State == "pending" {
		if utf16Length(s.Reason) <= 500 {
			return nil
		}
		return errors.New("daemon returned invalid context metadata")
	}
	if s.State != "ready" || utf16Length(s.Model) > 512 || s.Sections == nil || len(s.Sections) > 1000 ||
		utf16Length(s.Provider) > 512 || utf16Length(s.Protocol) > 512 || (s.CapturedAt != nil && *s.CapturedAt < 0) ||
		isNeg(s.ContextWindowTokens) {
		return errors.New("daemon returned invalid context metadata")
	}
	for _, sec := range s.Sections {
		if sec.ID == "" || utf16Length(sec.ID) > 200 || sec.Label == "" || utf16Length(sec.Label) > 200 || !slices.Contains(validKinds, sec.Kind) ||
			utf16Length(sec.Source) > 500 || sec.ItemCount < 0 || sec.ByteCount < 0 || utf16Length(sec.Preview) > 2000 || sec.Pages < 0 || sec.Pages > 10000 {
			return errors.New("daemon returned invalid context section metadata")
		}
	}
	c := s.Compaction
	badPct := c.TriggerFreePercent != nil && (math.IsNaN(*c.TriggerFreePercent) || math.IsInf(*c.TriggerFreePercent, 0) || *c.TriggerFreePercent < 0 || *c.TriggerFreePercent > 100)
	if compactionStatuses[c.Status] == "" || utf16Length(c.Strategy) > 200 || utf16Length(c.Source) > 500 || utf16Length(c.EstimateMethod) > 500 ||
		badPct || isNeg(c.InputLimitTokens) || isNeg(c.EstimatedInputTokens) ||
		isNeg(c.ProviderInputTokens) || isNeg(c.ProviderCachedInputTokens) ||
		isNeg(c.BeforeItems) || isNeg(c.AfterItems) {
		return errors.New("daemon returned invalid compaction metadata")
	}
	return nil
}

func validContextPage(p ContextPage, sectionID string) error {
	if p.Section != sectionID || p.Page < 0 || p.Pages < 0 || p.Pages > 10000 || p.Page >= max(1, p.Pages) || utf16Length(p.Content) > 65536 || utf16Length(p.Omitted) > 1000 {
		return errors.New("daemon returned invalid context page")
	}
	return nil
}

func (m ContextInspectorModel) loadSnapshotCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return contextSnapshotLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}

		if err := daemon.CheckCapability(context.Background(), m.Conn, "session_context", "for /context"); err != nil {
			return contextSnapshotLoadedMsg{Err: err, Gen: gen}
		}

		path := fmt.Sprintf("/sessions/%s/context", url.PathEscape(m.SessionID))
		snapshot, err := daemon.RequestOperation[ContextSnapshot](context.Background(), m.Conn, daemon.Operation{Name: "load snapshot", Method: http.MethodGet, Path: path, Body: nil, Policy: daemon.ReadRecovery})
		if err == nil {
			err = validContextSnapshot(snapshot)
		}
		if err != nil {
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
		data, err := daemon.RequestOperation[ContextPage](context.Background(), m.Conn, daemon.Operation{Name: "load page", Method: http.MethodGet, Path: path, Body: nil, Policy: daemon.ReadRecovery})
		if err == nil {
			err = validContextPage(data, sectionID)
		}
		if err != nil {
			return contextPageLoadedMsg{SectionID: sectionID, Page: page, Err: err, Gen: gen}
		}
		return contextPageLoadedMsg{SectionID: sectionID, Page: page, Data: &data, Gen: gen}
	}
}

func (m ContextInspectorModel) Update(msg tea.Msg) (ContextInspectorModel, tea.Cmd) {
	switch msg := msg.(type) {
	case contextSnapshotLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.Snapshot, m.Error = msg.Snapshot, ""
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
			m.Detail.Value, m.Detail.Error = msg.Data, ""
		}
		return m, nil

	case tea.KeyPressMsg:
		switch msg.String() {
		case "esc", "ctrl+c", "ctrl+d":
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

			switch msg.String() {
			case "left", "right":
				page := m.Detail.Page - 1
				if msg.String() == "right" {
					page = m.Detail.Page + 1
				}
				if page >= 0 && page < m.Detail.Section.Pages {
					m.Detail.Page, m.Detail.Value, m.Detail.Scroll, m.Detail.Error = page, nil, 0, ""
					m.Generation++
					return m, m.loadPageCmd(m.Detail.Section.ID, m.Detail.Page, m.Generation)
				}
			case "up":
				if m.Detail.Scroll > 0 {
					m.Detail.Scroll--
				}
			case "down":
				if m.Detail.Scroll < maxScroll {
					m.Detail.Scroll++
				}
			case "pgup":
				m.Detail.Scroll = max(0, m.Detail.Scroll-visibleRows)
			case "pgdown":
				m.Detail.Scroll = min(maxScroll, m.Detail.Scroll+visibleRows)
			}
			return m, nil
		}

		if strings.EqualFold(msg.String(), "r") {
			m.Loading, m.Snapshot, m.Detail, m.Error = true, nil, nil, ""
			m.Generation++
			return m, m.loadSnapshotCmd(m.Generation)
		}

		switch msg.String() {
		case "up", "ctrl+p":
			if m.Cursor > 0 {
				m.Cursor--
			}
		case "down", "ctrl+n":
			if m.Snapshot != nil && m.Cursor < len(m.Snapshot.Sections)-1 {
				m.Cursor++
			}
		case "enter":
			if m.Snapshot != nil && len(m.Snapshot.Sections) > m.Cursor {
				sec := m.Snapshot.Sections[m.Cursor]
				if sec.Pages > 0 {
					m.Detail = &ContextDetail{Section: sec}
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

var englishPrinter = message.NewPrinter(language.English)

func contextCount(n int, unit string) string {
	if n != 1 {
		unit += "s"
	}
	return englishPrinter.Sprintf("%d", n) + " " + unit
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
			visible := 17
			if m.Height > 0 {
				visible = max(1, m.Height-7)
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
		line(DefaultStyles.Warning.Render("No request has been prepared for this running session yet."))
		faint(m.Snapshot.Reason)
		line(keyHints(hint{"r", "refresh"}, hint{"esc", "return to chat"}))
	} else {
		snap := m.Snapshot
		label := snap.Model
		if snap.Provider != "" {
			label = snap.Provider + " · " + snap.Model
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
		status := compactionStatuses[snap.Compaction.Status]
		strategy := cmp.Or(snap.Compaction.Strategy, "none")
		faint("compaction: " + strategy + " · " + status)
		if snap.Compaction.TriggerFreePercent != nil {
			faint(fmt.Sprintf("trigger: keep %g%% free", *snap.Compaction.TriggerFreePercent))
		}
		if snap.Compaction.ProviderInputTokens != nil {
			measured := "provider input: " + contextCount(*snap.Compaction.ProviderInputTokens, "token")
			if snap.Compaction.ProviderCachedInputTokens != nil {
				measured += " · " + contextCount(*snap.Compaction.ProviderCachedInputTokens, "cached token")
			}
			faint(measured)
		} else if snap.Compaction.EstimatedInputTokens != nil {
			method := cmp.Or(snap.Compaction.EstimateMethod, "method not reported")
			faint("estimated input: " + contextCount(*snap.Compaction.EstimatedInputTokens, "token") + " · " + method)
		}
		line("")
		capacity := 5
		if m.Height > 0 {
			capacity = max(1, (m.Height-9)/3)
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
