package tui

import (
	"albedo/cli/internal/daemon"
	"charm.land/lipgloss/v2"
	"cmp"
	"encoding/json"
	"fmt"
	"github.com/charmbracelet/x/ansi"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
)

type DisplayFlags struct {
	Thinking   bool
	Tools      bool
	Diffs      bool
	Compaction bool
}

type TranscriptRenderer struct {
	Styles Styles
	// Workspace roots the paths trace rows name.
	Workspace string
	BodyWidth int
	// Open holds the keys of bursts drawn with every step listed.
	Open map[string]bool
}

func NewTranscriptRenderer() TranscriptRenderer {
	return TranscriptRenderer{Styles: DefaultStyles}
}

func formatClock(timestamp int64) string {
	if timestamp <= 0 {
		return ""
	}
	return time.UnixMilli(timestamp).Format("15:04:05")
}

// speaker names who wrote a chat entry, or "" for tool and status rows.
func speaker(entry HistoryEntry) string {
	switch entry.Kind {
	case EntryUser:
		return cmp.Or(entry.Speaker, "You")
	case EntryAssistant:
		return cmp.Or(entry.Speaker, "albedo")
	default:
		return ""
	}
}

// prior is what a new entry follows: the newest chat author, and when the
// conversation last moved, which a turn's end also marks.
type prior struct {
	speaker string
	at      int64
}

func priorOf(entries []HistoryEntry) prior {
	var p prior
	for i := len(entries) - 1; i >= 0 && p.speaker == ""; i-- {
		e := entries[i]
		if p.at == 0 && (e.Kind == EntryTurnEnd || speaker(e) != "") {
			p.at = e.Timestamp
		}
		p.speaker = speaker(e)
	}
	return p
}

// awayMs is the pause before your message that earns a "later" note.
const awayMs = 30 * 60_000

// nameplate labels a change of speaker, so a turn that resumes after tool
// rows keeps its author's name once. Verbose mode labels every message.
func (r TranscriptRenderer) nameplate(entry HistoryEntry, flags DisplayFlags, before prior) string {
	who := speaker(entry)
	if !flags.Tools && who == before.speaker {
		return ""
	}
	style := r.Styles.Agent
	if entry.Kind == EntryUser {
		style = r.Styles.You
	}
	var meta []string
	if clock := formatClock(entry.Timestamp); flags.Tools && clock != "" {
		meta = append(meta, clock)
	}
	if gap := entry.Timestamp - before.at; entry.Kind == EntryUser && before.at > 0 && gap >= awayMs {
		meta = append(meta, formatGap(gap))
	}
	if entry.Pending == queued {
		meta = append(meta, "queued")
	}
	if entry.Pending == unresolved {
		meta = append(meta, "unresolved")
	}
	plate := markChrome + style.Render(strings.ToLower(who))
	if len(meta) > 0 {
		plate += r.Styles.Faint.Render(" · " + strings.Join(meta, " · "))
	}
	return plate
}

// errorRow marks only the label red. Long red text tires the eye, and the
// message reads best in the prose color.
func (r TranscriptRenderer) errorRow(text string) string {
	return r.Styles.Error.Render("error:") + " " + text
}

// signoff closes a turn: a face for how it ended, then how long it took.
func (r TranscriptRenderer) signoff(entry HistoryEntry) string {
	style := r.Styles.Agent
	switch entry.Mood {
	case moodFailed:
		style = r.Styles.Error
	case moodStopped:
		style = r.Styles.Warning
	}
	var meta []string
	if entry.Mood == moodStopped {
		meta = append(meta, "stopped by you")
	}
	if entry.ElapsedMs > 0 {
		meta = append(meta, formatElapsed(entry.ElapsedMs))
	}
	if entry.Tools > 0 {
		unit := "tools"
		if entry.Tools == 1 {
			unit = "tool"
		}
		meta = append(meta, fmt.Sprintf("%d %s", entry.Tools, unit))
	}
	row := markChrome + rowAction{verbCopy, entryKey(entry)}.mark() + style.Render(entry.Mood.face(entry.Timestamp))
	if len(meta) > 0 {
		row += " " + r.Styles.Faint.Render(strings.Join(meta, " · "))
	}
	return row + r.Styles.Faint.Render(" · ") + r.Styles.Muted.Render("⧉")
}

var diffHunk = regexp.MustCompile(`^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@`)

// diffLanguages names the highlighter for a changed file's extension.
var diffLanguages = map[string]string{
	"ts": "typescript", "tsx": "typescript", "js": "javascript", "jsx": "javascript",
	"py": "python", "rs": "rust", "sh": "bash",
}

func (r TranscriptRenderer) RenderDiff(diff string, width int) string {
	return r.renderDiffPath(diff, "", width)
}

func (r TranscriptRenderer) renderDiffPath(diff, path string, width int) string {
	if width < 8 {
		return "…"
	}
	var rows []string
	oldLine, newLine := 0, 0
	lang := cmp.Or(diffLanguages[path[strings.LastIndex(path, ".")+1:]], "text")
	clean := func(text string) string {
		return strings.Map(func(ch rune) rune {
			if ch == '\t' || ch < 32 || ch == 127 {
				return ' '
			}
			return ch
		}, text)
	}
	row := func(gutter, content, bg string, syntax bool) {
		body := keepBackground(r.Styles.Faint.Render(content))
		if syntax {
			body = keepBackground(HighlightCode(content, lang))
		}
		for i, part := range strings.Split(ansi.Hardwrap(body, max(1, width-ansi.StringWidth(gutter)), true), "\n") {
			prefix := gutter
			if i > 0 {
				prefix = strings.Repeat(" ", ansi.StringWidth(gutter))
			}
			cell := prefix + part
			rows = append(rows, bg+cell+strings.Repeat(" ", max(0, width-ansi.StringWidth(cell)))+ansiReset)
		}
	}
	panel, add, remove := diffPanel(), diffAdded(), diffRemoved()
	gutter := func(style lipgloss.Style, n int, sign string) string {
		return keepBackground(style.Render(fmt.Sprintf("%4d %s ", n, sign)))
	}
	row(" ", clean(path), panel, false)
	for line := range strings.SplitSeq(diff, "\n") {
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
			row(gutter(r.Styles.Success, newLine, "+"), clean(line[1:]), add, true)
			newLine++
		case '-':
			row(gutter(r.Styles.Error, oldLine, "-"), clean(line[1:]), remove, true)
			oldLine++
		case ' ':
			row(gutter(r.Styles.Decor, newLine, " "), clean(line[1:]), panel, true)
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

func firstLine(text string) string {
	for line := range strings.SplitSeq(text, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			return line
		}
	}
	return ""
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
		return "python · " + firstLine(arg("code"))
	case "shell":
		return "$ " + firstLine(arg("command"))
	case "read_file", "write_file", "edit_file":
		return strings.TrimSuffix(entry.ToolName, "_file") + " " + arg("path")
	default:
		return entry.ToolName
	}
}

// toolOutput is what a tool printed. Python cells answer with a JSON
// envelope, and counting the envelope reports one line for every cell.
func toolOutput(entry HistoryEntry) string {
	if entry.ToolName == "python" {
		var cell struct{ Output, Value, Error string }
		if json.Unmarshal([]byte(entry.ToolResult), &cell) == nil {
			var parts []string
			for _, part := range []string{cell.Output, cell.Value, cell.Error} {
				if part = strings.TrimSpace(part); part != "" {
					parts = append(parts, part)
				}
			}
			return strings.Join(parts, "\n")
		}
	}
	return strings.TrimSpace(entry.ToolResult)
}

// oneLine folds text onto one row: control characters and runs of
// whitespace become single spaces.
func oneLine(text string) string {
	return strings.Join(strings.Fields(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, text)), " ")
}

// fit truncates head so the row fits width, keeping tail whole when there is
// room, so a long target never hides the counts after it.
func fit(head, tail string, width int) string {
	if room := width - ansi.StringWidth(tail); room >= 12 {
		return ansi.Truncate(head, room, "…") + tail
	}
	return ansi.Truncate(head+tail, max(1, width), "…")
}

var storeHash = regexp.MustCompile(`/nix/store/[0-9a-z]{32}-`)

// shortTarget fits what a trace row names into room cells. Paths in the
// workspace are named from it, the rest of home from ~, and store hashes are
// elided, in commands too; a path that still overflows loses its middle, so
// the file name stays visible.
func (r TranscriptRenderer) shortTarget(target string, path bool, room int) string {
	target = r.named(target)
	width := ansi.StringWidth(target)
	if !path || width <= room || room < 12 {
		return ansi.Truncate(target, max(1, room), "…")
	}
	head := room / 3
	return ansi.Truncate(target, head, "") + "…" + ansi.TruncateLeft(target, width-(room-head-1), "")
}

// namer names targets the way a person reads them: from the workspace, from ~,
// and without store hashes. One replacer serves a whole row.
type namer struct {
	replacer *strings.Replacer
}

func (r TranscriptRenderer) namer() namer {
	home, _ := os.UserHomeDir()
	var roots []string
	if workspace := expandHome(r.Workspace, home); workspace != "/" && workspace != "." {
		roots = append(roots, workspace+"/", "")
	}
	if home != "" {
		roots = append(roots, home+"/", "~/")
	}
	// the workspace comes first, so it wins where it sits inside home
	return namer{replacer: strings.NewReplacer(roots...)}
}

// prepareTarget strips what naming always strips, workspace-independently:
// control runs, store hashes. Facts store prepared targets so a render only
// applies the workspace replacer.
func prepareTarget(target string) string {
	return storeHash.ReplaceAllString(oneLine(target), "/nix/store/…-")
}

func (n namer) name(target string) string {
	return n.replacer.Replace(target)
}

func (n namer) all(targets []string) []string {
	named := make([]string, len(targets))
	for i, target := range targets {
		named[i] = n.name(target)
	}
	return named
}

// named is target as a person reads it; see namer.
func (r TranscriptRenderer) named(target string) string {
	return r.namer().name(prepareTarget(target))
}

func expandHome(path, home string) string {
	if rest, ok := strings.CutPrefix(path, "~/"); ok && home != "" {
		path = filepath.Join(home, rest)
	}
	return filepath.Clean(path)
}

// traceLine is a verb then its target, the target shortened to fit width.
func (r TranscriptRenderer) traceLine(verb, target string, path bool, width int) string {
	return fit(verb+" "+r.shortTarget(target, path, width-ansi.StringWidth(verb)-1), "", width)
}

func isPath(activity daemon.ToolActivity) bool {
	return activity.Kind == "read" || activity.Kind == "list"
}

func countLines(text string) string {
	n := strings.Count(text, "\n") + 1
	return fmt.Sprintf("%d %s", n, lineUnit(n))
}

// toolRow is the collapsed tool line: what ran, then how much.
func toolRow(entry HistoryEntry, failed bool, clock string, width int) string {
	head, tail := toolRowParts(entry, failed, clock)
	return fit(head, tail, width)
}

// toolRowParts is toolRow unfitted: what ran, and the " · " tail of how much.
func toolRowParts(entry HistoryEntry, failed bool, clock string) (string, string) {
	var tail []string
	if code, ok := entry.ToolArgs["code"].(string); ok && entry.ToolName == "python" {
		if n := strings.Count(strings.TrimSpace(code), "\n") + 1; n > 1 {
			tail = append(tail, countLines(strings.TrimSpace(code)))
		}
	}
	if output := toolOutput(entry); output != "" {
		tail = append(tail, countLines(output)+" out")
	}
	if failed {
		tail = append(tail, "failed")
	}
	if clock != "" {
		tail = append(tail, clock)
	}
	suffix := ""
	if len(tail) > 0 {
		suffix = " · " + strings.Join(tail, " · ")
	}
	return oneLine(toolSummary(entry)), suffix
}

func (r TranscriptRenderer) diffCounts(change daemon.FileChange) string {
	return r.Styles.Success.Render(fmt.Sprintf("+%d", change.Added)) + " " + r.Styles.Error.Render(fmt.Sprintf("−%d", change.Removed))
}

func (r TranscriptRenderer) RenderToolTrace(trace *daemon.ToolTrace, flags DisplayFlags, width int) string {
	if trace == nil {
		return ""
	}
	// Normal mode folds the read of an edited file into its edit row.
	reads := func(path string) bool {
		return slices.ContainsFunc(trace.Activities, func(a daemon.ToolActivity) bool { return a.Kind == "read" && a.Target == path })
	}
	edits := func(path string) bool {
		return slices.ContainsFunc(trace.Changes, func(c daemon.FileChange) bool { return c.Path == path })
	}
	var rows []string
	if flags.Tools && len(trace.Activities) > 0 {
		verb := "explored"
		if slices.ContainsFunc(trace.Activities, func(a daemon.ToolActivity) bool { return a.Kind == "run" }) {
			verb = "executed"
		}
		rows = append(rows, r.Styles.Bold.Render(verb))
	}
	for _, act := range trace.Activities {
		if !flags.Tools && act.Kind == "read" && edits(act.Target) {
			continue
		}
		label, style := act.Kind, r.Styles.Faint
		if act.Failed {
			label += " failed"
			style = r.Styles.Error
		}
		if flags.Tools {
			rows = append(rows, "  "+r.traceLine(style.Render(label), act.Target, isPath(act), width-2))
		} else {
			rows = append(rows, style.Render(r.traceLine(label, act.Target, isPath(act), width)))
		}
	}
	changeStyle := r.Styles.Faint
	if flags.Tools {
		changeStyle = r.Styles.Bold
	}
	for _, change := range trace.Changes {
		label := "edited"
		if !flags.Tools && reads(change.Path) {
			label = "read + edited"
		}
		counts := ""
		if change.Kind == "diff" {
			counts = "  " + r.diffCounts(change)
		}
		line := r.traceLine(label, change.Path, true, width-ansi.StringWidth(counts))
		rows = append(rows, fit(changeStyle.Render(line), counts, width))
		if flags.Diffs {
			if change.Kind == "diff" {
				rows = append(rows, r.renderDiffPath(change.Diff, change.Path, width))
			} else {
				rows = append(rows, r.Styles.Faint.Render(change.Reason))
			}
		}
	}
	if trace.Truncated {
		notice := "Some activity was not captured · /v shows what is available"
		if flags.Tools {
			notice = "Some activity was not captured; this list is incomplete"
		}
		rows = append(rows, r.Styles.Faint.Render(notice))
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
	for line := range strings.SplitSeq(RenderMarkdownAnsi(text, width), "\n") {
		for _, wrapped := range wrapOrChunkLine(line, width) {
			rows = append(rows, r.Styles.Faint.Render(ansi.Strip(wrapped)))
		}
	}
	return rows
}

// RenderEntry renders an entry on its own, so a chat entry always names its author.
func (r TranscriptRenderer) RenderEntry(entry HistoryEntry, flags DisplayFlags, width int) string {
	return r.RenderAfter(prior{}, entry, flags, width)
}

// RenderAfter renders an entry in the context of what came before it.
func (r TranscriptRenderer) RenderAfter(before prior, entry HistoryEntry, flags DisplayFlags, width int) string {
	var rows []string
	switch entry.Kind {
	case EntryUser, EntryAssistant:
		if plate := r.nameplate(entry, flags, before); plate != "" {
			rows = append(rows, plate)
		}
		if entry.Pending != settled {
			// greyed out until the daemon echoes it back
			rows = append(rows, r.faintMarkdownRows(entry.Text, width)...)
			break
		}
		render := renderCopyable
		if entry.Live {
			render = RenderMarkdownAnsi
		}
		body := render(entry.Text, width)
		if entry.Kind == EntryUser {
			body = r.foldUser(entry, body)
		}
		rows = append(rows, body)
	case EntryThinking:
		rows = []string{markChrome + r.Styles.Faint.Render("thinking")}
		if flags.Thinking {
			rows = append(rows, r.faintMarkdownRows(entry.Text, width)...)
		}
	case EntryTool:
		trace := entry.ToolTrace
		hasTrace := trace != nil && (len(trace.Activities) > 0 || len(trace.Changes) > 0)
		failed := toolFailed(entry)
		if !hasTrace || flags.Tools || failed {
			// a glance in normal mode, read in full in verbose mode
			style := r.Styles.Faint
			clock := ""
			if flags.Tools {
				style = lipgloss.NewStyle()
				clock = formatClock(entry.Timestamp)
			}
			if failed {
				style = r.Styles.Error
			}
			rows = append(rows, markChrome+style.Render(toolRow(entry, failed, clock, width)))
		}
		if hasTrace {
			rows = append(rows, chrome(r.RenderToolTrace(trace, flags, width)))
			if !flags.Tools && !failed {
				break
			}
		}
		if flags.Tools {
			if entry.ToolName == "python" {
				if code, ok := entry.ToolArgs["code"].(string); ok {
					rows = append(rows, renderCopyable("```python\n"+code+"\n```", width))
				}
			}
			rows = append(rows, strings.Split(cmp.Or(toolOutput(entry), "(no output)"), "\n")...)
		}
	case EntryTurnEnd:
		rows = []string{r.signoff(entry)}
	case EntryNote:
		rows = []string{r.Styles.Faint.Render(entry.Text)}
	case EntryError:
		rows = []string{r.errorRow(entry.Text)}
	case EntryCompacted:
		action := "view"
		if flags.Compaction {
			action = "hide"
		}
		verb, noun := compactionWords(entry.Strategy)
		rows = []string{markChrome + r.Styles.Faint.Render(fmt.Sprintf("compaction done · %d items %s · ctrl+k %s %s", entry.Evicted, verb, action, noun))}
		if flags.Compaction {
			rows = append(rows, r.faintMarkdownRows(entry.Text, width)...)
		}
	}
	return strings.Join(rows, "\n")
}

// A message of yours taller than userFoldRows plus userFoldSlack shows its
// first userFoldRows rows and a click target for the rest; the slack keeps
// a fold from hiding only a line or two.
const (
	userFoldRows  = 10
	userFoldSlack = 2
)

// foldUser is body, a settled message's rendered rows, cut to its first rows
// until the message's key is in Open.
func (r TranscriptRenderer) foldUser(entry HistoryEntry, body string) string {
	rows := strings.Split(body, "\n")
	if len(rows) <= userFoldRows+userFoldSlack {
		return body
	}
	key := entryKey(entry)
	if r.Open[key] {
		return body + "\n" + r.foldRow(key, toggleOpen+"show less")
	}
	label := fmt.Sprintf("%s%d more lines · click to expand", toggleClosed, len(rows)-userFoldRows)
	return strings.Join(rows[:userFoldRows], "\n") + "\n" + r.foldRow(key, label)
}

func (r TranscriptRenderer) foldRow(key, label string) string {
	return markChrome + rowAction{verbMore, key}.mark() + r.Styles.Faint.Render(label)
}

// compactionWords names what a strategy did with the evicted items and what
// ctrl+k shows: snapcompact archives them as rendered frames, lcm folds them
// into summary nodes, and rolling (or an unnamed strategy) summarizes them.
func compactionWords(strategy string) (verb, noun string) {
	switch strategy {
	case "snapcompact":
		return "archived as frames", "archive"
	case "lcm":
		return "folded", "folds"
	default:
		return "summarized", "summary"
	}
}

// Compact entries are one-line summaries. A run of them stacks without blank
// rows so a burst of tool calls reads as one block.
func Compact(entry HistoryEntry, flags DisplayFlags) bool {
	switch entry.Kind {
	case EntryTool:
		return !flags.Tools
	case EntryThinking:
		return !flags.Thinking
	}
	return false
}

// Separated reports whether a blank row belongs between two adjacent entries.
// A turn's signoff hangs directly under the turn it closes.
func Separated(prev *HistoryEntry, next HistoryEntry, flags DisplayFlags) bool {
	return prev != nil && next.Kind != EntryTurnEnd && (!Compact(*prev, flags) || !Compact(next, flags))
}

// railWidth is the rail and the space after it, at the start of every row.
const railWidth = 2

// lane is the rail an entry hangs on. A turn is one unbroken rail: yours in
// your color, albedo's in its color, dimmer while it works in tools.
type lane int

const (
	laneNone lane = iota
	laneYou
	laneAgent
	laneBusy
)

func laneOf(entry HistoryEntry) lane {
	switch entry.Kind {
	case EntryUser:
		return laneYou
	case EntryAssistant, EntryTurnEnd, EntryError:
		return laneAgent
	case EntryTool, EntryThinking:
		return laneBusy
	}
	return laneNone
}

// joint is the lane of the blank row between two entries, so the rail
// carries through a turn and breaks between turns.
func joint(above, below lane) lane {
	switch {
	case above == laneNone || below == laneNone || (above == laneYou) != (below == laneYou):
		return laneNone
	case above == laneBusy || below == laneBusy:
		return laneBusy
	}
	return above
}

func (r TranscriptRenderer) rail(l lane) string {
	switch l {
	case laneYou:
		return r.Styles.You.Render("│") + " "
	case laneAgent:
		return r.Styles.Agent.Render("│") + " "
	case laneBusy:
		return r.Styles.Busy.Render("│") + " "
	}
	return strings.Repeat(" ", railWidth)
}

// Block is an entry as finished transcript rows: the blank row that
// separates it from the entry before, when one belongs, then its rows
// wrapped beside its rail. head indexes the entry's first row.
func (r TranscriptRenderer) Block(before []HistoryEntry, entry HistoryEntry, flags DisplayFlags) (rows []string, head int) {
	return r.frame(before, entry, flags, func(width int) string {
		return r.RenderAfter(priorOf(before), entry, flags, width)
	})
}

// BurstBlock is a burst as finished transcript rows, framed like a Block.
func (r TranscriptRenderer) BurstBlock(before, burst []HistoryEntry, flags DisplayFlags) []string {
	rows, _ := r.frame(before, burst[0], flags, func(width int) string {
		return r.RenderBurst(burst, flags, width)
	})
	return rows
}

// frame hangs body beside first's rail, after the blank row that separates
// it from before when one belongs. head indexes body's first row.
func (r TranscriptRenderer) frame(before []HistoryEntry, first HistoryEntry, flags DisplayFlags, body func(width int) string) (rows []string, head int) {
	own := laneOf(first)
	if n := len(before); n > 0 && Separated(&before[n-1], first, flags) {
		rows = append(rows, strings.TrimRight(r.rail(joint(laneOf(before[n-1]), own)), " "))
	}
	head = len(rows)
	width := max(1, r.BodyWidth-railWidth)
	gutter := r.rail(own)
	for line := range strings.SplitSeq(body(width), "\n") {
		for _, chunk := range markChunks(line, wrapOrChunkLine(line, width)) {
			rows = append(rows, gutter+chunk)
		}
	}
	return rows, head
}

// Settle is the rows entry settles after before: none for a compact entry,
// whose burst waits for what ends it, else the burst it ends, then itself.
// head indexes the entry's first row.
func (r TranscriptRenderer) Settle(before []HistoryEntry, entry HistoryEntry, flags DisplayFlags) (rows []string, head int) {
	if Compact(entry, flags) {
		return nil, 0
	}
	if burst := trailingBurst(before, flags); len(burst) > 0 {
		rows = r.BurstBlock(before[:len(before)-len(burst)], burst, flags)
	}
	block, at := r.Block(before, entry, flags)
	return append(rows, block...), len(rows) + at
}

// OpenBurst is the burst that ends entries, drawn live until it settles.
func (r TranscriptRenderer) OpenBurst(entries []HistoryEntry, flags DisplayFlags) []string {
	burst := trailingBurst(entries, flags)
	if len(burst) == 0 {
		return nil
	}
	return r.BurstBlock(entries[:len(entries)-len(burst)], burst, flags)
}

func (r TranscriptRenderer) RenderHistory(history *BoundedHistory, flags DisplayFlags) string {
	var rows []string
	if notice := history.TruncationNotice(); notice != "" {
		rows = append(rows, r.rail(laneNone)+r.Styles.Warning.Render(notice), "")
	}
	entries := history.Entries()
	for i, entry := range entries {
		block, _ := r.Settle(entries[:i], entry, flags)
		rows = append(rows, block...)
	}
	rows = append(rows, r.OpenBurst(entries, flags)...)
	return strings.Join(rows, "\n")
}
