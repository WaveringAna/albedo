package tui

import (
	"fmt"
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
)

var actionMark = regexp.MustCompile(`\x1b_albedo:(copy):([0-9a-f]+-[0-9a-f]+)\x1b\\`)

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
	if act, ok := actionOf(m.frameLines[row]); ok && act.verb == verbCopy {
		return m.copyReply(act.key)
	}
	return nil
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
