package tui

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// jobGrace is how long a job runs before the interface calls it background
// work. Most model jobs finish inside it, so a job a cell starts and awaits
// never lights the background-job chrome at all; one that survives is real
// work and shows up as such.
const jobGrace = 3 * time.Second

// agedJobs are the live jobs past their grace: the work the sidebar and the
// idle status line call background. A job with no start time is settled.
func (m ChatModel) agedJobs() []protocol.KernelJob {
	jobs := make([]protocol.KernelJob, 0, len(m.Status.RunningJobs))
	for _, job := range m.Status.RunningJobs {
		if job.StartedAt <= 0 || time.Since(time.UnixMilli(job.StartedAt)) >= jobGrace {
			jobs = append(jobs, job)
		}
	}
	return jobs
}

// backgroundJobCount is the background work the interface names: aged jobs,
// plus live remote jobs the observation could only count.
func (m ChatModel) backgroundJobCount() int64 {
	count := int64(len(m.agedJobs()))
	if m.Status.KernelJobs == nil {
		return count
	}
	if extra := *m.Status.KernelJobs - int64(len(m.Status.RunningJobs)); extra > 0 {
		count += extra
	}
	return count
}

// activeGlances lists the sidebar's sections in order, leaving out empty ones:
// the extensions' glances (active work), then background jobs past their grace.
func (m ChatModel) activeGlances() []PageGlance {
	var glances []PageGlance
	for _, g := range m.Glances {
		if len(g.Rows) > 0 {
			glances = append(glances, g)
		}
	}
	jobs := m.agedJobs()
	if len(jobs) == 0 {
		return glances
	}
	rows := make([]PageRow, 0, len(jobs))
	for _, job := range jobs {
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
	// a stale kernel is swapped before the next turn unless a job keeps it
	if m.Status.KernelStale && m.backgroundJobCount() > 0 {
		counts = append([]string{"kernel older until jobs end"}, counts...)
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
	rows := []string{DefaultStyles.Faint.Render(fmt.Sprintf("%s · %d", g.Title, len(g.Rows)))}
	for _, item := range g.Rows[:shown] {
		mark, style := "○", DefaultStyles.Faint
		switch item.Tone {
		case ToneActive:
			mark, style = "●", DefaultStyles.Success
		case ToneWarning:
			mark, style = "!", DefaultStyles.Warning
		case ToneMuted:
			mark = "✓"
		}
		label := oneLine(item.Text)
		if item.ID != "" {
			label = "#" + item.ID + " " + label
		}
		rows = append(rows, style.Render(mark)+" "+ansi.Truncate(label, max(1, m.sidebarWidth()-2), "…"))
	}
	if shown < len(g.Rows) {
		rows = append(rows, DefaultStyles.Faint.Render(fmt.Sprintf("+%d more", len(g.Rows)-shown)))
	}
	return rows
}

func (m ChatModel) renderFooter() string {
	width := m.chatWidth()
	right, compact := m.contextStat()
	commands := hint{"/", "commands"}
	sessions := hint{"←", "sessions"}
	candidates := []struct {
		right string
		left  []hint
	}{
		{left: []hint{sessions, commands, {"shift+↑↓", "your messages"}, {"ctrl+j", "diffs"}, {"ctrl+o", "agents"}}, right: right},
		{left: []hint{sessions, commands, {"ctrl+j", "diffs"}, {"ctrl+o", "agents"}}, right: right},
		{left: []hint{sessions, commands, {"ctrl+o", "agents"}}, right: compact},
		{left: []hint{sessions, commands}, right: compact},
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
		return DefaultStyles.Faint.Render("—/— cached"), DefaultStyles.Faint.Render("—/—")
	}
	count := func(n *int) string {
		if n == nil || *n < 0 {
			return "—"
		}
		return shortCount(*n)
	}
	ratio := DefaultStyles.Muted.Render(count(cachedNow(usage, time.Now())) + "/" + count(usage.PromptTokens))
	share := ""
	if total := contextTokens(usage); total != nil && m.window != nil && m.windowModel != nil && *m.windowModel == usage.Model {
		pct := int(math.Round(100 * float64(*total) / float64(*m.window)))
		style := DefaultStyles.Faint
		if pct >= 90 {
			style = DefaultStyles.Warning
		}
		share = " " + style.Render(fmt.Sprintf("(%d%%)", pct))
	}
	return ratio + DefaultStyles.Faint.Render(" cached") + share, ratio + share
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
