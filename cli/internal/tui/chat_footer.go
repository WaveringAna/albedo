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
