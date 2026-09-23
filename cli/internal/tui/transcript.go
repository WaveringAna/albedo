package tui

import (
	"albedo/cli/internal/daemon"
	"encoding/json"
	"fmt"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type DisplayFlags struct {
	Thinking   bool
	Tools      bool
	Diffs      bool
	Compaction bool
}

type TranscriptRenderer struct {
	Styles       Styles
	HeadingWidth int
	BodyWidth    int
}

func NewTranscriptRenderer() TranscriptRenderer {
	return TranscriptRenderer{Styles: DefaultStyles}
}

func formatClock(timestamp int64) string {
	if timestamp <= 0 {
		return ""
	}
	t := time.UnixMilli(timestamp)
	return t.Format("15:04:05")
}

func (r TranscriptRenderer) RenderHeading(label string, width int, timestamp int64) string {
	clock := formatClock(timestamp)
	if width < len(clock)+3 {
		clock = ""
	}
	name := label
	if width < len([]rune(name))+len(clock)+1 && width > len(clock)+1 {
		runes := []rune(name)
		name = string(runes[:max(0, width-len(clock)-2)]) + "…"
	}
	heading := r.Styles.Bold.Render(name)
	if clock != "" {
		heading += strings.Repeat(" ", max(1, width-len([]rune(name))-len(clock))) + r.Styles.Faint.Render(clock)
	}
	return heading
}

var diffHunk = regexp.MustCompile(`^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@`)

func (r TranscriptRenderer) RenderDiff(diff string, width int) string {
	return r.renderDiffPath(diff, "", width)
}

func (r TranscriptRenderer) renderDiffPath(diff, path string, width int) string {
	if width < 8 {
		return "…"
	}
	var rows []string
	oldLine, newLine := 0, 0
	lang := "text"
	switch path[strings.LastIndex(path, ".")+1:] {
	case "ts", "tsx":
		lang = "typescript"
	case "js", "jsx":
		lang = "javascript"
	case "py":
		lang = "python"
	case "rs":
		lang = "rust"
	case "sh":
		lang = "bash"
	}
	clean := func(text string) string {
		return strings.Map(func(ch rune) rune {
			if ch == '\t' {
				return ' '
			}
			if ch < 32 || ch == 127 {
				return ' '
			}
			return ch
		}, text)
	}
	row := func(gutter, content, bg string, syntax bool) {
		body := "\x1b[90m" + content + "\x1b[39m"
		if syntax {
			body = HighlightCode(content, lang)
			body = strings.ReplaceAll(body, "\x1b[0m", "\x1b[39;22;23m")
		}
		for i, part := range strings.Split(ansi.Hardwrap(body, max(1, width-ansi.StringWidth(gutter)), true), "\n") {
			prefix := gutter
			if i > 0 {
				prefix = strings.Repeat(" ", ansi.StringWidth(gutter))
			}
			cell := prefix + part
			rows = append(rows, bg+cell+strings.Repeat(" ", max(0, width-ansi.StringWidth(cell)))+"\x1b[0m")
		}
	}
	panel, add, remove := "\x1b[48;2;37;40;50m", "\x1b[48;2;24;53;39m", "\x1b[48;2;59;35;40m"
	row(" ", clean(path), panel, false)
	for _, line := range strings.Split(diff, "\n") {
		if line == "" || strings.HasPrefix(line, "--- ") || strings.HasPrefix(line, "+++ ") {
			continue
		}
		if hunk := diffHunk.FindStringSubmatch(line); hunk != nil {
			oldLine, _ = strconv.Atoi(hunk[1])
			newLine, _ = strconv.Atoi(hunk[2])
			row(" ⋮ ", clean(line), panel, false)
			continue
		}
		switch line[0] {
		case '+':
			row(fmt.Sprintf("\x1b[32m%4d + \x1b[39m", newLine), clean(line[1:]), add, true)
			newLine++
		case '-':
			row(fmt.Sprintf("\x1b[31m%4d - \x1b[39m", oldLine), clean(line[1:]), remove, true)
			oldLine++
		case ' ':
			row(fmt.Sprintf("\x1b[90m%4d   \x1b[39m", newLine), clean(line[1:]), panel, true)
			newLine++
			oldLine++
		default:
			row(" ⋮ ", clean(line), panel, false)
		}
	}
	return strings.Join(rows, "\n")
}

func lineUnit(n int) string {
	if n == 1 {
		return "line"
	}
	return "lines"
}

func toolSummary(entry HistoryEntry) string {
	arg := func(key string) string {
		if entry.ToolArgs == nil {
			return ""
		}
		return fmt.Sprint(entry.ToolArgs[key])
	}
	switch entry.ToolName {
	case "python":
		lines := strings.Count(arg("code"), "\n") + 1
		return fmt.Sprintf("python · %d %s", lines, lineUnit(lines))
	case "shell":
		return "$ " + arg("command")
	case "read_file":
		return "read " + arg("path")
	case "write_file":
		return "write " + arg("path")
	case "edit_file":
		return "edit " + arg("path")
	default:
		return entry.ToolName
	}
}

func (r TranscriptRenderer) RenderToolTrace(trace *daemon.ToolTrace, flags DisplayFlags, width int) string {
	if trace == nil {
		return ""
	}
	var rows []string
	if !flags.Tools {
		edited := map[string]bool{}
		for _, change := range trace.Changes {
			edited[change.Path] = true
		}
		for _, activity := range trace.Activities {
			if activity.Kind == "read" && edited[activity.Target] {
				continue
			}
			label := activity.Kind
			if activity.Failed {
				label += " failed"
			}
			style := r.Styles.Prompt
			if activity.Failed {
				style = r.Styles.Error
			}
			rows = append(rows, style.Render(label+" "+activity.Target))
		}
		for _, change := range trace.Changes {
			label := "edited " + change.Path
			for _, activity := range trace.Activities {
				if activity.Kind == "read" && activity.Target == change.Path {
					label = "read + " + label
					break
				}
			}
			if change.Kind == "diff" {
				label += fmt.Sprintf("  +%d −%d", change.Added, change.Removed)
			}
			rows = append(rows, r.Styles.Prompt.Render(label))
			if flags.Diffs {
				if change.Kind == "diff" {
					rows = append(rows, r.renderDiffPath(change.Diff, change.Path, width))
				} else {
					rows = append(rows, r.Styles.Faint.Render(change.Reason))
				}
			}
		}
		if trace.Truncated {
			rows = append(rows, r.Styles.Faint.Render("activity capture limited · /v expand"))
		}
		return strings.Join(rows, "\n")
	}
	if len(trace.Activities) > 0 {
		verb := "explored"
		for _, act := range trace.Activities {
			if act.Kind == "run" {
				verb = "executed"
				break
			}
		}
		rows = append(rows, r.Styles.Bold.Render(verb))
		for _, act := range trace.Activities {
			style := r.Styles.Prompt
			label := act.Kind
			if act.Failed {
				style = r.Styles.Error
				label += " failed"
			}
			rows = append(rows, "  "+style.Render(label)+" "+act.Target)
		}
	}
	for _, change := range trace.Changes {
		line := r.Styles.Bold.Render("edited " + change.Path)
		if change.Kind == "diff" {
			line += fmt.Sprintf("  %s %s", lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Render(fmt.Sprintf("+%d", change.Added)), lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Render(fmt.Sprintf("−%d", change.Removed)))
		}
		rows = append(rows, line)
		if flags.Diffs {
			if change.Kind == "diff" {
				rows = append(rows, r.renderDiffPath(change.Diff, change.Path, width))
			} else {
				rows = append(rows, r.Styles.Faint.Render(change.Reason))
			}
		}
	}
	if trace.Truncated {
		rows = append(rows, r.Styles.Faint.Render("activity capture limited; some operations are not shown"))
	}
	return strings.Join(rows, "\n")
}

func toolFailed(entry HistoryEntry) bool {
	if entry.ToolName == "python" {
		var result struct {
			Status string `json:"status"`
			Error  string `json:"error"`
		}
		if json.Unmarshal([]byte(entry.ToolResult), &result) == nil {
			if result.Status != "" {
				return result.Status != "ok"
			}
			return result.Error != ""
		}
	}
	return toolErrorLine.MatchString(entry.ToolResult)
}

var toolErrorLine = regexp.MustCompile(`(?im)^(?:error:|cancelled:|traceback \(most recent call last\):)`)

func (r TranscriptRenderer) faintMarkdownRows(text string, width int) []string {
	var rows []string
	for _, line := range strings.Split(RenderMarkdownAnsi(text, width), "\n") {
		for _, wrapped := range wrapOrChunkLine(line, width) {
			rows = append(rows, r.Styles.Faint.Render(ansi.Strip(wrapped)))
		}
	}
	return rows
}

func (r TranscriptRenderer) RenderEntry(entry HistoryEntry, flags DisplayFlags, width int) string {
	if r.BodyWidth > 0 {
		width = r.BodyWidth
	}
	var rows []string
	switch entry.Kind {
	case EntryUser, EntryAssistant:
		speaker := entry.Speaker
		if speaker == "" {
			if entry.Kind == EntryUser {
				speaker = "You"
			} else {
				speaker = "albedo"
			}
		}
		headingWidth := width
		if r.HeadingWidth > 0 {
			headingWidth = r.HeadingWidth
		}
		heading := r.RenderHeading(speaker, headingWidth, entry.Timestamp)
		if entry.Kind == EntryUser {
			clock := formatClock(entry.Timestamp)
			if clock != "" && headingWidth >= len([]rune(speaker))+len(clock)+2 {
				heading = "\x1b[96m" + strings.ToLower(speaker) + "\x1b[0m" + strings.Repeat(" ", headingWidth-len([]rune(speaker))-len(clock)) + r.Styles.Faint.Render(clock)
			} else {
				heading = "\x1b[96m" + strings.ToLower(speaker) + "\x1b[0m"
			}
		}
		rows = []string{heading, RenderMarkdownAnsi(entry.Text, width)}
	case EntryThinking:
		if flags.Thinking {
			rows = append([]string{r.Styles.Faint.Render("thinking")}, r.faintMarkdownRows(entry.Text, width)...)
		} else {
			rows = []string{r.Styles.Faint.Render(ansi.Truncate("thinking · /t expand", max(1, width), "…"))}
		}
	case EntryTool:
		trace := entry.ToolTrace
		hasTrace := trace != nil && (len(trace.Activities) > 0 || len(trace.Changes) > 0)
		failed := toolFailed(entry)
		if !hasTrace || flags.Tools || failed {
			style := r.Styles.Faint
			if failed {
				style = r.Styles.Error
			}
			label := toolSummary(entry)
			if failed {
				label += " · failed"
			}
			if !flags.Tools && !hasTrace {
				if output := strings.TrimSpace(entry.ToolResult); output != "" {
					label += fmt.Sprintf(" · %d output %s", strings.Count(output, "\n")+1, lineUnit(strings.Count(output, "\n")+1))
				}
				label += " · /v expand"
				label = ansi.Truncate(strings.Join(strings.Fields(label), " "), max(1, width), "…")
			}
			rows = append(rows, style.Render(label))
		}
		if hasTrace {
			rows = append(rows, r.RenderToolTrace(trace, flags, width))
			if !flags.Tools && !failed {
				break
			}
		}
		if flags.Tools && entry.ToolName == "python" {
			if code, ok := entry.ToolArgs["code"].(string); ok {
				rows = append(rows, RenderMarkdownAnsi("```python\n"+code+"\n```", width))
			}
		}
		if flags.Tools {
			output := strings.TrimRight(entry.ToolResult, "\n")
			if output == "" {
				output = "(no output)"
			}
			rows = append(rows, strings.Split(output, "\n")...)
		}
	case EntryNote:
		rows = []string{r.Styles.Faint.Render(entry.Text)}
	case EntryError:
		rows = []string{r.Styles.Error.Render("error: " + entry.Text)}
	case EntryCompacted:
		action := "view"
		if flags.Compaction {
			action = "hide"
		}
		rows = []string{r.Styles.Faint.Render(fmt.Sprintf("compaction done · %d items summarized · ctrl+k %s summary", entry.Evicted, action))}
		if flags.Compaction {
			rows = append(rows, r.faintMarkdownRows(entry.Text, width)...)
		}
	}
	return strings.Join(rows, "\n")
}

func (r TranscriptRenderer) RenderHistory(history *BoundedHistory, flags DisplayFlags, width int) string {
	var rows []string
	if notice := history.TruncationNotice(); notice != "" {
		rows = append(rows, r.Styles.Warning.Render(notice), "")
	}
	for _, entry := range history.Entries() {
		if len(rows) > 0 {
			rows = append(rows, "")
		}
		rows = append(rows, r.RenderEntry(entry, flags, width))
	}
	return strings.Join(rows, "\n")
}
