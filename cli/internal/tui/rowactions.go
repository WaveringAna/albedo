package tui

import (
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

// A row action is a click target. Like the copy marks in selection.go, its
// mark is an APC string that draws nothing, so the row itself says what a
// click on it does and survives wrapping, trimming, and rebuilds.
const (
	// verbCopy copies a turn's replies as the markdown they were written in.
	verbCopy = "copy"
	// verbOpen lists or hides the steps of a burst.
	verbOpen = "open"
	// verbMore shows or folds the rest of a long message of yours, or of a
	// web search's answer.
	verbMore = "more"
)

var actionMark = regexp.MustCompile(`\x1b_albedo:(copy|open|more):([0-9a-f]+-[0-9a-f]+)\x1b\\`)

type rowAction struct{ verb, key string }

func (a rowAction) mark() string { return "\x1b_albedo:" + a.verb + ":" + a.key + "\x1b\\" }

func actionOf(row string) (rowAction, bool) {
	hit := actionMark.FindStringSubmatch(row)
	if hit == nil {
		return rowAction{}, false
	}
	return rowAction{verb: hit[1], key: hit[2]}, true
}

// entryKey names an entry by what it says, so the mark on its rows still
// finds it after the transcript is rebuilt.
func entryKey(entry HistoryEntry) string {
	h := fnv1a(fnvOffset64, string(entry.Kind)+"\x00"+entry.ToolName+"\x00"+entry.Text+"\x00"+entry.ToolResult+"\x00"+fmt.Sprint(entry.ToolArgs))
	return fmt.Sprintf("%x-%x", entry.Timestamp, h)
}

// actAt runs the action of the transcript row at absolute index row.
func (m *ChatModel) actAt(row int) tea.Cmd {
	if row < 0 || row >= len(m.frameLines) {
		return nil
	}
	act, ok := actionOf(m.frameLines[row])
	if !ok {
		return nil
	}
	switch act.verb {
	case verbCopy:
		return m.copyReply(act.key)
	case verbOpen:
		m.toggleBurst(act.key, row)
	case verbMore:
		if !m.toggleFold(act.key, row) {
			m.toggleLookup(act.key, row)
		}
	}
	return nil
}

// toggleFold shows or folds the rest of the message whose fold row is at row,
// the last row of its block. Only that block renders again and is spliced into
// the settled rows. The clicked row keeps its place on screen: expanding opens
// the text below it, and folding brings the new fold row to where it was.
// It reports false when key names no message of yours.
func (m *ChatModel) toggleFold(key string, row int) bool {
	entries := m.History.Entries()
	at := slices.IndexFunc(entries, func(e HistoryEntry) bool { return e.Kind == EntryUser && entryKey(e) == key })
	if at < 0 {
		return false
	}
	was := m.Renderer
	was.Open = map[string]bool{key: m.Renderer.Open[key]}
	old, _ := was.Block(entries[:at], entries[at], m.Flags)
	if m.Renderer.Open == nil {
		m.Renderer.Open = map[string]bool{}
	}
	m.Renderer.Open[key] = !m.Renderer.Open[key]
	fresh, _ := m.Renderer.Block(entries[:at], entries[at], m.Flags)
	from := row - m.settledOffset - (len(old) - 1)
	if from < 0 || from+len(old) > len(m.settledLines) || m.settledLines[from+len(old)-1] != old[len(old)-1] {
		m.rebuildSettledLines()
		m.refreshViewportContent()
		return true
	}
	screen := row - m.scrollOffset
	if !m.Renderer.Open[key] {
		row += len(fresh) - len(old)
	}
	row -= m.replaceSettled(from, len(old), fresh)
	m.Follow, m.scrollOffset = false, max(0, row-screen)
	m.Follow = m.scrollOffset >= m.refreshViewportContent()
	return true
}

// toggleLookup shows or folds the rest of the web search answer whose fold
// row is at row. Its burst renders again; the clicked row keeps its place on
// screen, as toggleFold keeps a message's.
func (m *ChatModel) toggleLookup(key string, row int) {
	entries := m.History.Entries()
	at := slices.IndexFunc(entries, func(e HistoryEntry) bool {
		return slices.ContainsFunc(factsOf(e).looked, func(look lookup) bool { return look.key == key })
	})
	if at < 0 {
		return
	}
	start := at
	for start > 0 && Compact(entries[start-1], m.Flags) {
		start--
	}
	end := at + 1
	for end < len(entries) && Compact(entries[end], m.Flags) {
		end++
	}
	before, burst := entries[:start], entries[start:end]
	fold := func(lines []string) int {
		return slices.IndexFunc(lines, func(line string) bool {
			act, ok := actionOf(line)
			return ok && act == rowAction{verbMore, key}
		})
	}
	was := m.Renderer
	was.Open = maps.Clone(m.Renderer.Open)
	old := was.BurstBlock(before, burst, m.Flags)
	if m.Renderer.Open == nil {
		m.Renderer.Open = map[string]bool{}
	}
	m.Renderer.Open[key] = !m.Renderer.Open[key]
	fresh := m.Renderer.BurstBlock(before, burst, m.Flags)
	clicked, screen := fold(old), row-m.scrollOffset
	if end < len(entries) {
		from := row - m.settledOffset - clicked
		if clicked < 0 || from < 0 || from+len(old) > len(m.settledLines) || m.settledLines[row-m.settledOffset] != old[clicked] {
			m.rebuildSettledLines()
			m.refreshViewportContent()
			return
		}
		row -= m.replaceSettled(from, len(old), fresh)
	}
	m.burstEpoch++
	if !m.Renderer.Open[key] {
		row += fold(fresh) - clicked
	}
	m.Follow, m.scrollOffset = false, max(0, row-screen)
	m.Follow = m.scrollOffset >= m.refreshViewportContent()
}

// toggleBurst opens or closes the burst whose summary is at row, keeping that
// row where it was on screen; an opened list that would end below the screen
// scrolls up into view. Only the burst renders again: a settled one is
// spliced into the settled rows, and the live one redraws on its own.
func (m *ChatModel) toggleBurst(key string, row int) {
	entries := m.History.Entries()
	start, end, ok := burstNamed(entries, key, m.Flags)
	if !ok {
		return
	}
	before, burst := entries[:start], entries[start:end]
	was := m.Renderer
	was.Open = map[string]bool{key: m.Renderer.Open[key]}
	old := was.BurstBlock(before, burst, m.Flags)
	if m.Renderer.Open == nil {
		m.Renderer.Open = map[string]bool{}
	}
	m.Renderer.Open[key] = !m.Renderer.Open[key]
	fresh := m.Renderer.BurstBlock(before, burst, m.Flags)
	// the summary sits after the same separator in both
	head := slices.IndexFunc(fresh, func(line string) bool {
		_, ok := actionOf(line)
		return ok
	})
	screen := row - m.scrollOffset
	if end < len(entries) {
		from := row - m.settledOffset - head
		if from < 0 || from+len(old) > len(m.settledLines) || m.settledLines[from+head] != old[head] {
			m.rebuildSettledLines()
			m.refreshViewportContent()
			return
		}
		row -= m.replaceSettled(from, len(old), fresh)
	}
	m.burstEpoch++
	offset, last := row-screen, row-head+len(fresh)
	if last-offset > m.Viewport.Height() {
		offset = min(row, last-m.Viewport.Height())
	}
	m.Follow, m.scrollOffset = false, max(0, offset)
	m.Follow = m.scrollOffset >= m.refreshViewportContent()
}

// copyReply copies a reply's markdown.
func (m *ChatModel) copyReply(key string) tea.Cmd {
	if text, ok := m.replyMarkdown(key); ok {
		return m.copied(text)
	}
	return nil
}

// replyMarkdown is a finished turn's prose as written: every reply since
// your message, which the turn's signoff names.
func (m *ChatModel) replyMarkdown(key string) (string, bool) {
	entries := m.History.Entries()
	end := slices.IndexFunc(entries, func(e HistoryEntry) bool { return e.Kind == EntryTurnEnd && entryKey(e) == key })
	if end < 0 {
		return "", false
	}
	start := end
	for start > 0 && entries[start-1].Kind != EntryUser {
		start--
	}
	var parts []string
	for _, e := range entries[start:end] {
		if e.Kind == EntryAssistant {
			parts = append(parts, e.Text)
		}
	}
	return strings.Join(parts, "\n\n"), len(parts) > 0
}

func (m *ChatModel) copied(text string) tea.Cmd {
	m.CopyStatus = "copied"
	m.copyStatusRevision++
	return tea.Batch(CopyText(text), m.clearCopyStatusCmd())
}

// Dragging a selection past the top or bottom edge of the transcript
// scrolls it: after a short delay, then a row at a time while the pointer
// stays there. The selection is in transcript rows, so it keeps growing.
const (
	dragScrollDelay = 150 * time.Millisecond
	dragScrollEvery = 50 * time.Millisecond
)

type dragScrollMsg struct{ gen int }

func dragScrollTick(gen int, after time.Duration) tea.Cmd {
	return tea.Tick(after, func(time.Time) tea.Msg { return dragScrollMsg{gen} })
}

// steerDragScroll starts or stops the edge scroll for a pointer on screen
// row of the transcript.
func (m *ChatModel) steerDragScroll(row int) tea.Cmd {
	dir := 0
	switch {
	case row <= 0 && m.scrollOffset > 0:
		dir = -1
	case row >= m.Viewport.Height()-1 && !m.Follow:
		dir = 1
	}
	if dir == m.dragDir {
		return nil
	}
	m.dragDir = dir
	m.dragGen++
	if dir == 0 {
		return nil
	}
	return dragScrollTick(m.dragGen, dragScrollDelay)
}

// dragScrolled moves one row toward the edge and pulls the selection's head
// along, or stops when the transcript has no more to show that way.
func (m *ChatModel) dragScrolled(msg dragScrollMsg) tea.Cmd {
	if m.dragAnchor == nil || msg.gen != m.dragGen || m.dragDir == 0 {
		return nil
	}
	before := m.scrollOffset
	m.scrollBy(m.dragDir)
	if m.scrollOffset == before {
		m.dragDir = 0
		return nil
	}
	m.dragHead.Row = m.scrollOffset
	if m.dragDir >= 0 {
		m.dragHead.Row += m.Viewport.Height() - 1
	}
	return dragScrollTick(m.dragGen, dragScrollEvery)
}
