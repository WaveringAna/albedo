package tui

import (
	"encoding/json"
	"fmt"
	"maps"
	"slices"
	"strings"
	"unicode"

	"albedo/cli/internal/daemon"

	"github.com/charmbracelet/x/ansi"
)

// A tool card is one call in verbose mode, on a panel the width of the
// transcript: the call's name and how long it took, the code it ran, what it
// did, and what it printed. A long section shows its start (the newest calls,
// for what it did) and a fold row; a click on any fold row opens the card.
const (
	cardCodeRows   = 10
	cardCallRows   = 8
	cardOutputRows = 5
)

func (r TranscriptRenderer) toolCard(entry HistoryEntry, flags DisplayFlags, width int) []string {
	key := entryKey(entry)
	open := r.Open[key]
	failed := toolFailed(entry)
	inner := max(1, width-2)
	panel := func(row string) string {
		row = ansi.Truncate(row, inner, "…")
		return diffPanel() + " " + keepBackground(row) + strings.Repeat(" ", max(0, inner-ansi.StringWidth(row))) + " " + ansiReset
	}
	fold := func(hidden int, noun string) string {
		return markChrome + rowAction{verbMore, key}.mark() + panel(DefaultStyles.Faint.Render(fmt.Sprintf("%s%d more %s · click to expand", toggleClosed, hidden, noun)))
	}
	folded := false
	var rows []string
	// section adds a block of panel rows, after a blank one unless it
	// follows the name, keeping its first limit rows (its last, when newest)
	// while the card is closed.
	section := func(body []string, limit int, newest bool, noun string) {
		if len(body) == 0 {
			return
		}
		if len(rows) > 1 {
			rows = append(rows, markChrome+panel(""))
		}
		long := len(body) > limit+foldSlack
		folded = folded || long
		if open || !long {
			rows = append(rows, body...)
			return
		}
		hidden := len(body) - limit
		if newest {
			rows = append(append(rows, fold(hidden, noun)), body[hidden:]...)
			return
		}
		rows = append(append(rows, body[:limit]...), fold(hidden, noun))
	}

	name, glyph := cardName(entry), DefaultStyles.Busy
	if failed {
		name, glyph = "✗ "+name, DefaultStyles.Error
	}
	var facts []string
	if took := cellDuration(entry); took != "" {
		facts = append(facts, took)
	}
	if failed {
		facts = append(facts, "failed")
	}
	facts = append(facts, formatClock(entry.Timestamp))
	rows = append(rows, markChrome+panel(fit(glyph.Bold(true).Render(name), DefaultStyles.Faint.Render(" "+strings.Join(facts, " · ")), inner)))

	if code, lang := cardInput(entry); strings.TrimSpace(code) != "" {
		var body []string
		for _, line := range wrapped(HighlightLines(plainLines(strings.TrimRight(code, "\n")), lexerFor(lang), r.highlights), inner) {
			body = append(body, panel(line))
		}
		section(body, cardCodeRows, false, "lines")
	}
	section(r.cardCalls(entry.ToolTrace, flags, inner, panel), cardCallRows, true, "calls")
	var body []string
	for _, part := range cardOutput(entry) {
		ink := DefaultStyles.Faint
		if part.failed {
			ink = DefaultStyles.Error
		}
		for _, line := range wrapped(plainLines(part.text), inner) {
			body = append(body, panel(ink.Render(line)))
		}
	}
	section(body, cardOutputRows, false, "lines")
	if open && folded {
		rows = append(rows, markChrome+rowAction{verbMore, key}.mark()+panel(DefaultStyles.Faint.Render(toggleOpen+"show less")))
	}
	return rows
}

// wrapped is lines wrapped to width, the rows a line wraps onto marked as
// continuing it, so a copy joins them back.
func wrapped(lines []string, width int) []string {
	var rows []string
	for _, line := range lines {
		rows = append(rows, markChunks(line, wrapOrChunkLine(line, width))...)
	}
	return rows
}

// cardCalls is what a call did, a row each: the commands, reads, searches and
// displays its trace recorded, then the files it changed, with their diffs
// when ctrl+j shows them.
func (r TranscriptRenderer) cardCalls(trace *daemon.ToolTrace, flags DisplayFlags, width int, panel func(string) string) []string {
	if trace == nil {
		return nil
	}
	var rows []string
	for _, act := range trace.Activities {
		head := callGlyph(act) + " " + DefaultStyles.Busy.Render(act.Kind) + " "
		took := ""
		if act.MS != nil {
			took = " " + DefaultStyles.Decor.Render(formatMillis(*act.MS))
		}
		target := r.shortTarget(act.Target, isPath(act), width-ansi.StringWidth(head)-ansi.StringWidth(took))
		rows = append(rows, markChrome+panel(head+DefaultStyles.Faint.Render(target)+took))
		if act.Kind == "display" && act.Detail != "" {
			for _, row := range r.renderDisplayRows(act.Target, act.Detail, width) {
				rows = append(rows, panel(row))
			}
		}
	}
	for _, change := range trace.Changes {
		counts := ""
		if change.Kind == "diff" {
			counts = "  " + r.diffCounts(change)
		}
		line := r.traceLine(DefaultStyles.Success.Render("✓")+" "+DefaultStyles.Busy.Render("edited"), change.Path, true, width-ansi.StringWidth(counts))
		rows = append(rows, markChrome+panel(fit(line, counts, width)))
		if !flags.Diffs {
			continue
		}
		if change.Kind != "diff" {
			rows = append(rows, markChrome+panel(DefaultStyles.Faint.Render(change.Reason)))
			continue
		}
		// the edited row above already names the file
		diff := strings.Split(r.renderDiffPath(change.Diff, change.Path, width), "\n")
		for _, row := range diff[1:] {
			rows = append(rows, panel(row))
		}
	}
	if trace.Truncated {
		rows = append(rows, markChrome+panel(DefaultStyles.Faint.Render("some activity was not captured; this list is incomplete")))
	}
	return rows
}

type outputPart struct {
	text   string
	failed bool
}

// cardOutput is what a call printed, then its error: a cell's traceback is
// red, what it printed before failing is not.
func cardOutput(entry HistoryEntry) []outputPart {
	var cell struct{ Output, Value, Error string }
	if entry.ToolName != "python" || json.Unmarshal([]byte(entry.ToolResult), &cell) != nil {
		if output := toolOutput(entry); output != "" {
			return []outputPart{{output, toolFailed(entry)}}
		}
		return nil
	}
	var parts []outputPart
	for _, part := range []outputPart{{cell.Output, false}, {cell.Value, false}, {cell.Error, true}} {
		if part.text = strings.TrimSpace(part.text); part.text != "" {
			parts = append(parts, part)
		}
	}
	return parts
}

// cardInput is what a call was given, and a file name whose language tints
// it: a cell's code, a command, or the arguments of any other call.
func cardInput(entry HistoryEntry) (text, file string) {
	arg := func(key string) string { s, _ := entry.ToolArgs[key].(string); return s }
	switch entry.ToolName {
	case "python":
		return arg("code"), "cell.py"
	case "shell", "bash":
		return arg("command"), "command.sh"
	}
	keys := slices.Sorted(maps.Keys(entry.ToolArgs))
	lines := make([]string, len(keys))
	for i, key := range keys {
		value, ok := entry.ToolArgs[key].(string)
		if !ok {
			encoded, _ := json.Marshal(entry.ToolArgs[key])
			value = string(encoded)
		}
		lines[i] = key + ": " + value
	}
	return strings.Join(lines, "\n"), ""
}

func cardName(entry HistoryEntry) string {
	if entry.ToolName == "shell" || entry.ToolName == "bash" {
		return "shell"
	}
	return entry.ToolName
}

// cellDuration is how long a python cell ran, from its result.
func cellDuration(entry HistoryEntry) string {
	var cell struct {
		Duration float64 `json:"duration"`
	}
	if entry.ToolName != "python" || json.Unmarshal([]byte(entry.ToolResult), &cell) != nil || cell.Duration <= 0 {
		return ""
	}
	return formatMillis(int64(cell.Duration * 1000))
}

// formatMillis is a call's duration as pi shows it: 40ms, 1.5s, or past a
// minute 2m 3s.
func formatMillis(ms int64) string {
	switch {
	case ms < 1000:
		return fmt.Sprintf("%dms", ms)
	case ms < 60_000:
		return fmt.Sprintf("%.1fs", float64(ms)/1000)
	default:
		return formatElapsed(ms)
	}
}

// callGlyph is how a call inside a cell ended: ✓ or ✗, or · for a call
// still running when its cell finished, or one that records no outcome.
func callGlyph(act daemon.ToolActivity) string {
	switch {
	case act.OK == nil:
		return DefaultStyles.Faint.Render("·")
	case *act.OK:
		return DefaultStyles.Success.Render("✓")
	default:
		return DefaultStyles.Error.Render("✗")
	}
}

// plainLines is text as rows of printable cells: tool output may carry
// colors, tabs, and carriage returns that would wreck the panel around it.
func plainLines(text string) []string {
	text = strings.NewReplacer("\r\n", "\n", "\r", "\n", "\t", "    ").Replace(ansi.Strip(text))
	return strings.Split(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' {
			return ' '
		}
		return r
	}, text), "\n")
}
