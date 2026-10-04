package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

func (m ChatModel) backgroundJobCount() int64 {
	if m.Status.KernelJobs == nil {
		return 0
	}
	return *m.Status.KernelJobs
}

// activeGlances lists the sidebar's sections in order, leaving out empty ones:
// the extensions' glances (active work), then background jobs.
func (m ChatModel) activeGlances() []PageGlance {
	var glances []PageGlance
	for _, g := range m.Glances {
		if len(g.Rows) > 0 {
			glances = append(glances, g)
		}
	}
	if len(m.Status.RunningJobs) == 0 {
		return glances
	}
	rows := make([]PageRow, 0, len(m.Status.RunningJobs))
	for _, job := range m.Status.RunningJobs {
		command := oneLine(job.Command)
		if command == "" {
			command = "job " + job.ID
		}
		rows = append(rows, PageRow{Text: command, Tone: ToneActive})
	}
	return append(glances, PageGlance{Title: "background jobs", Rows: rows})
}

// glanceCounts counts each glance the sidebar leaves out: all of them without
// a sidebar, the ones that did not fit its height with one.
func (m ChatModel) glanceCounts() []string {
	omitted := m.activeGlances()
	if m.sidebarWidth() > 0 {
		_, omitted = m.sidebarRows()
	}
	var counts []string
	for _, g := range omitted {
		counts = append(counts, fmt.Sprintf("%s %d", g.Title, len(g.Rows)))
	}
	if m.Status.KernelStale {
		counts = append([]string{"kernel older"}, counts...)
	}
	return counts
}

func (m ChatModel) renderGlances() string {
	rows, _ := m.sidebarRows()
	return lipgloss.NewStyle().Width(m.sidebarWidth()).Render(strings.Join(rows, "\n"))
}

// sidebarRows stacks the glances, a blank row apart and at most 12 rows each,
// within the viewport's height. A glance with no room for its title and one
// row is returned as omitted.
func (m ChatModel) sidebarRows() ([]string, []PageGlance) {
	var rows []string
	var omitted []PageGlance
	room := m.Viewport.Height()
	for _, g := range m.activeGlances() {
		gap := min(1, len(rows))
		limit := min(room-gap, 12)
		if limit < 2 {
			omitted = append(omitted, g)
			continue
		}
		section := m.glanceRows(g, limit)
		rows = append(rows, make([]string, gap)...)
		rows = append(rows, section...)
		room -= gap + len(section)
	}
	return rows, omitted
}

// glanceRows renders a glance's title and rows in at most limit rows, one
// line per row.
func (m ChatModel) glanceRows(g PageGlance, limit int) []string {
	shown := min(limit-1, len(g.Rows))
	if len(g.Rows) > shown {
		shown = limit - 2
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
		rows = append(rows, style.Render(mark)+" "+ansi.Truncate(label, max(1, m.sidebarWidth()-2), "…"))
	}
	if shown < len(g.Rows) {
		rows = append(rows, m.Styles.Faint.Render(fmt.Sprintf("+%d more", len(g.Rows)-shown)))
	}
	return rows
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
