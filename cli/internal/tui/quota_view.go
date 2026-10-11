package tui

import (
	"fmt"
	"math"
	"strings"
	"time"

	"albedo/cli/internal/daemon"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// A reading older than this was not polled on schedule: the daemon polls at
// least every ten minutes, and a failing account backs off to an hour.
const quotaStale = 30 * time.Minute

const (
	quotaBarSlots = 10
	// Warm from here, red from quotaHot. The daemon polls busier from the same 80.
	quotaWarm = 80.0
	quotaHot  = 95.0
	// The pane's trail shows at least a day, so a short window's resets show.
	quotaTrailMin = 24 * time.Hour
	quotaTrailMax = 7 * 24 * time.Hour
)

// quotaPoint is one reading of a limit's percent.
type quotaPoint struct {
	At      time.Time
	Percent float64
}

type quotaStanding int

const (
	quotaFresh   quotaStanding = iota
	quotaOld                   // polled long ago, or past its own reset
	quotaFailed                // the provider reported an error
	quotaUnknown               // answered without a percentage
)

func quotaKey(r daemon.QuotaObservation) string {
	return r.Provider + "/" + r.AccountID + "/" + r.LimitID
}

func quotaSection(r daemon.QuotaObservation) string {
	if r.AccountID == r.Provider {
		return r.Provider
	}
	return r.Provider + " · " + r.AccountID
}

// quotaName is what a row is called. A poll that failed with no limits has no
// label of its own: its section already names the account, so the row says
// what happened.
func quotaName(r daemon.QuotaObservation) string {
	switch {
	case r.Label != "":
		return r.Label
	case r.Error != nil:
		return "last poll failed"
	case r.LimitID != "":
		return r.LimitID
	}
	return "no limits reported"
}

// quotaWindow is a limit's window as a noun phrase: the provider's labels read
// "5h window" or "7 days", and the pane says "the <window> window".
func quotaWindow(r daemon.QuotaObservation) string {
	if r.WindowLabel == nil {
		return ""
	}
	return strings.TrimSpace(strings.TrimSuffix(*r.WindowLabel, " window"))
}

// quotaDesc is a limit's window, unless its label already says it.
func quotaDesc(r daemon.QuotaObservation) string {
	if r.WindowLabel == nil || *r.WindowLabel == r.Label {
		return ""
	}
	return *r.WindowLabel
}

func parseStamp(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339, s)
	return t, err == nil
}

func resetOf(r daemon.QuotaObservation) (time.Time, bool) {
	if r.ResetsAt == nil {
		return time.Time{}, false
	}
	return parseStamp(*r.ResetsAt)
}

func standingOf(r daemon.QuotaObservation, at time.Time) quotaStanding {
	seen, _ := parseStamp(r.ObservedAt)
	resets, hasReset := resetOf(r)
	switch {
	case r.Error != nil:
		return quotaFailed
	case r.UsedPercent == nil:
		return quotaUnknown
	case at.Sub(seen) > quotaStale || (hasReset && !resets.After(at)):
		return quotaOld
	}
	return quotaFresh
}

// span writes a duration as 40m, 2h14m or 3d4h: two units at most.
func quotaSpan(d time.Duration) string {
	d = max(d, 0)
	units := func(big, small time.Duration, bigName, smallName string) string {
		out := fmt.Sprintf("%d%s", d/big, bigName)
		if rest := (d % big) / small; rest > 0 {
			out += fmt.Sprintf("%d%s", rest, smallName)
		}
		return out
	}
	switch {
	case d < time.Minute:
		return "<1m"
	case d < time.Hour:
		return fmt.Sprintf("%dm", d/time.Minute)
	case d < 24*time.Hour:
		return units(time.Hour, time.Minute, "h", "m")
	}
	return units(24*time.Hour, time.Hour, "d", "h")
}

// quotaInk is the color a percent is drawn in: the brand ramp until it runs
// warm, then yellow, then red.
func quotaInk(percent, t float64) lipgloss.Style {
	switch {
	case percent >= quotaHot:
		return DefaultStyles.Error
	case percent >= quotaWarm:
		return DefaultStyles.Warning
	}
	return brandInk(t)
}

// quotaBar fills slots toward percent. A reading that is not current keeps
// its fill in the faintest ink, so it cannot pass for one.
func quotaBar(percent float64, current bool) string {
	filled := int(math.Round(percent / 100 * quotaBarSlots))
	if percent > 0 {
		filled = max(filled, 1)
	}
	var b strings.Builder
	for i := range quotaBarSlots {
		switch {
		case i >= filled:
			b.WriteString(DefaultStyles.Decor.Render("▱"))
		case !current:
			b.WriteString(DefaultStyles.Faint.Render("▰"))
		default:
			b.WriteString(quotaInk(percent, float64(i)/(quotaBarSlots-1)).Render("▰"))
		}
	}
	return b.String()
}

// quotaTag is the right edge of a row: the bar, the percent and when it
// resets, or why there is no bar.
func quotaTag(r daemon.QuotaObservation, at time.Time) string {
	switch standing := standingOf(r, at); standing {
	case quotaFailed:
		return DefaultStyles.Error.Render("no reading")
	case quotaUnknown:
		return DefaultStyles.Faint.Render("no percentage")
	default:
		percent := *r.UsedPercent
		seen, _ := parseStamp(r.ObservedAt)
		note := ""
		switch resets, ok := resetOf(r); {
		case standing == quotaOld:
			note = "seen " + quotaSpan(at.Sub(seen))
		case ok:
			note = "in " + quotaSpan(resets.Sub(at))
		}
		percentText := fmt.Sprintf("%3.0f%%", percent)
		if standing == quotaOld {
			percentText = DefaultStyles.Faint.Render(percentText)
		}
		return quotaBar(percent, standing == quotaFresh) + " " + percentText + "  " + DefaultStyles.Faint.Render(svCell(note, 9, false))
	}
}

// summary is the highlighted limit on one line, for a terminal with no room
// for the pane.
func (m QuotaModel) summary(r daemon.QuotaObservation) string {
	var parts []string
	switch standingOf(r, m.at) {
	case quotaFailed:
		parts = append(parts, "last poll failed")
	case quotaUnknown:
		parts = append(parts, "no percentage reported")
	default:
		parts = append(parts, fmt.Sprintf("%.0f%% used", *r.UsedPercent))
		if resets, ok := resetOf(r); ok && resets.After(m.at) {
			parts = append(parts, "resets in "+quotaSpan(resets.Sub(m.at)))
		}
	}
	return DefaultStyles.Faint.Render(strings.Join(parts, " · "))
}

// details is the pane: what the reading says, then the limit's recent past.
func (m QuotaModel) details(r daemon.QuotaObservation, width int) []string {
	subtitle := r.Provider + " · " + r.AccountID
	if r.Plan != nil {
		subtitle += " · " + *r.Plan
	}
	lines := paneTitle(quotaName(r), subtitle, width)
	seen, _ := parseStamp(r.ObservedAt)
	standing := standingOf(r, m.at)

	if r.UsedPercent != nil {
		used := fmt.Sprintf("%.0f%%", *r.UsedPercent)
		if window := quotaWindow(r); window != "" {
			used += " of the " + window + " window"
		}
		lines = append(lines, factRows("used", used, width)...)
	}
	if resets, ok := resetOf(r); ok {
		when := resets.In(m.at.Location()).Format("15:04")
		if resets.Sub(m.at) >= 24*time.Hour {
			when = resets.In(m.at.Location()).Format("Mon 15:04")
		}
		text := "already reset"
		if resets.After(m.at) {
			text = "in " + quotaSpan(resets.Sub(m.at)) + " · " + when
		}
		lines = append(lines, factRows("resets", text, width)...)
	}
	lines = append(lines, factRows("seen", quotaSpan(m.at.Sub(seen))+" ago", width)...)
	if r.Scope != nil {
		lines = append(lines, factRows("scope", *r.Scope, width)...)
	}
	if r.Error != nil {
		lines = append(lines, factRows("error", r.Error.Detail, width)...)
	}
	if standing == quotaFailed || standing == quotaUnknown {
		return lines
	}

	trail, asked := m.trails[quotaKey(r)]
	switch {
	case !asked || trail.pending:
		return append(lines, "", DefaultStyles.Faint.Render("reading history…"))
	case trail.failed:
		return append(lines, "", DefaultStyles.Faint.Render("history unavailable"))
	case len(trail.points) < 2:
		return append(lines, "", DefaultStyles.Faint.Render("not enough readings yet"))
	}
	from := quotaTrailFrom(trail.points, m.trailSince(r))
	span := m.at.Sub(from)
	reach := quotaReach(span)
	lines = append(lines, "", DefaultStyles.Muted.Render("last "+reach))
	lines = append(lines, quotaSpark(trail.points, from, m.at, width)...)
	lines = append(lines, quotaAxis(reach+" ago", "now", width))
	if pace := quotaPace(trail.points, r, m.at); pace != "" {
		lines = append(lines, "")
		lines = append(lines, factRows("pace", pace, width)...)
	}
	return lines
}

// quotaTrailSpan is how far back a limit's trail reaches: its window, but
// never so little that a short window shows no reset.
func quotaTrailSpan(r daemon.QuotaObservation) time.Duration {
	span := quotaTrailMin
	if r.WindowSeconds != nil {
		span = time.Duration(*r.WindowSeconds) * time.Second
	}
	return min(max(span, quotaTrailMin), quotaTrailMax)
}

// quotaTrailFrom is where a trail's picture starts: the bound it was asked for,
// or the first reading when the daemon had fewer than that to give (a busy
// limit fills the client's row cap before it reaches back as far). A first
// reading within a poll of the bound still counts as reaching it, so an
// ordinary trail keeps its round label.
func quotaTrailFrom(points []quotaPoint, since time.Time) time.Time {
	if len(points) > 0 && points[0].At.Sub(since) > quotaStale {
		return points[0].At
	}
	return since
}

// quotaReach names a trail's span in whole hours up to two days, where a
// day count would read as a different scale.
func quotaReach(span time.Duration) string {
	if span <= 48*time.Hour {
		return fmt.Sprintf("%dh", span/time.Hour)
	}
	return quotaSpan(span)
}

func quotaAxis(left, right string, width int) string {
	gap := max(1, width-ansi.StringWidth(left)-ansi.StringWidth(right))
	return DefaultStyles.Faint.Render(left + strings.Repeat(" ", gap) + right)
}

// quotaSpark draws the points between from and to as two rows of bars, so a
// column has sixteen levels. A column holds the last reading at or before its
// end, blank before the first reading and once the last one is stale: a
// limit that stopped being polled shows the gap.
func quotaSpark(points []quotaPoint, from, to time.Time, width int) []string {
	bars := []rune("▁▂▃▄▅▆▇█")
	step := to.Sub(from) / time.Duration(width)
	top, bottom := make([]string, width), make([]string, width)
	next, last, lastAt, seen := 0, 0.0, time.Time{}, false
	for col := range width {
		end := from.Add(step * time.Duration(col+1))
		for next < len(points) && !points[next].At.After(end) {
			last, lastAt, seen = points[next].Percent, points[next].At, true
			next++
		}
		top[col], bottom[col] = " ", " "
		if !seen || end.Sub(lastAt) > quotaStale {
			continue
		}
		level := int(math.Round(last / 100 * 16))
		if last > 0 {
			level = max(level, 1)
		}
		ink := quotaInk(last, last/100)
		switch {
		case level == 0:
			bottom[col] = DefaultStyles.Decor.Render("▁")
		case level > 8:
			bottom[col], top[col] = ink.Render("█"), ink.Render(string(bars[level-9]))
		default:
			bottom[col] = ink.Render(string(bars[level-1]))
		}
	}
	return []string{strings.Join(top, ""), strings.Join(bottom, "")}
}

// quotaPace says where the limit is heading, from how fast the current
// window filled over the last hour and a half. It says nothing when there is
// too little since the window began to tell.
func quotaPace(points []quotaPoint, r daemon.QuotaObservation, at time.Time) string {
	const lookback, enough, still = 90 * time.Minute, 20 * time.Minute, 0.5 // percent an hour
	var recent []quotaPoint
	for _, p := range points {
		switch {
		case at.Sub(p.At) > lookback:
		case len(recent) > 0 && p.Percent < recent[len(recent)-1].Percent:
			recent = recent[:0] // the window reset; only what follows counts
			recent = append(recent, p)
		default:
			recent = append(recent, p)
		}
	}
	if len(recent) < 2 || recent[len(recent)-1].At.Sub(recent[0].At) < enough {
		return ""
	}
	first, last := recent[0], recent[len(recent)-1]
	rate := (last.Percent - first.Percent) / last.At.Sub(first.At).Hours()
	if rate < still {
		return "holding steady"
	}
	resets, ok := resetOf(r)
	if !ok {
		return fmt.Sprintf("~%.0f%% an hour", rate)
	}
	left := resets.Sub(at)
	untilFull := time.Duration((100 - last.Percent) / rate * float64(time.Hour))
	if untilFull < left {
		return "full in ~" + quotaSpan(untilFull)
	}
	return fmt.Sprintf("ends near %.0f%%", last.Percent+rate*left.Hours())
}

func (m QuotaModel) footer(width int) string {
	hints := []hint{{"↑↓", "move"}, {"ctrl+r", "refresh"}, {"esc", "back"}}
	if m.Error != "" {
		hints = []hint{{"ctrl+r", "retry"}, {"esc", "back"}}
	}
	var status string
	urgent := true
	switch {
	case m.Loading:
		status, urgent = DefaultStyles.Faint.Render("loading…"), false
	case m.Error != "":
		status = DefaultStyles.Error.Render(m.Error)
	case len(m.readings) > 0:
		status, urgent = DefaultStyles.Faint.Render(m.counts()), false
	}
	return footerLine(width, hints, status, urgent)
}

func (m QuotaModel) counts() string {
	accounts := map[string]bool{}
	for _, r := range m.readings {
		accounts[quotaSection(r)] = true
	}
	return counted(len(accounts), "account") + DefaultStyles.Decor.Render(" · ") + counted(len(m.readings), "limit")
}

func (m QuotaModel) View() string {
	lv := m.listView
	switch {
	case m.Loading:
		lv.Empty = "loading quota…"
	case m.Error != "":
		lv.Empty = "Could not read quota from the daemon."
	default:
		lv.Empty = "No quota readings yet. The daemon polls each account every few minutes."
	}
	title := brand("albedo") + " " + DefaultStyles.Muted.Render("/quota")
	f := lv.frame(title, DefaultStyles.Faint.Render("provider limits"), m.footer(max(1, m.Width)))
	if r, ok := m.current(); ok {
		f.summary = m.summary(r)
	}
	return f.view(m.Width, m.Height)
}
