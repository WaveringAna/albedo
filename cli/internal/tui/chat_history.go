package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"fmt"
	"maps"
	"slices"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func (m *ChatModel) syncViewportHeight() {
	if m == nil || m.History == nil || m.Height <= 0 {
		return
	}
	m.Viewport.SetHeight(max(1, m.Height-6-m.chromeRows()))
	m.refreshViewportContent()
}

func (m *ChatModel) rebuildSettledLines() {
	// Re-rendering retained history must not move the reading position: it
	// keeps its distance from the end of the settled rows, and trimming waits
	// until it is placed.
	fromEnd := m.settledOffset + len(m.settledLines) - m.scrollOffset
	m.settledLines = nil
	m.settledLinesBytes = 0
	m.droppedSettledLines = 0
	m.userRows = nil
	m.rebuilding = true
	entries := m.History.Entries()
	// Only a reader scrolled up keeps the blocks: each older page rebuilds
	// everything retained, and reuses what the last rebuild rendered.
	var kept map[settledKey]settledBlock
	if !m.Follow {
		kept = make(map[settledKey]settledBlock, len(entries))
	}
	for i := range entries {
		key, named := m.settledKey(entries[:i], entries[i])
		block, ok := m.settled[key]
		if !named || !ok {
			block.rows, block.head = m.Renderer.Settle(entries[:i], entries[i], m.Flags)
		}
		if named && kept != nil {
			kept[key] = block
		}
		m.appendRows(entries[i], block)
	}
	m.settled = kept
	m.rebuilding = false
	m.settledOffset = len(m.headerLines())
	m.scrollOffset = max(0, m.settledOffset+len(m.settledLines)-fromEnd)
	m.trimSettledLines()
}

// headerLines lead the transcript: where older history stands. Their count
// only changes with what is loaded, and refreshViewportContent keeps the
// reading position steady when it does.
func (m ChatModel) headerLines() []string {
	var line string
	switch {
	case m.loadingOlder:
		line = DefaultStyles.Faint.Render("↑ loading earlier messages…")
	case m.hasOlder():
		line = DefaultStyles.Faint.Render("↑ earlier messages load as you scroll up")
	case m.History.TruncationNotice() != "":
		line = DefaultStyles.Warning.Render(m.History.TruncationNotice())
	default:
		return nil
	}
	return []string{markChrome + m.Renderer.rail(laneNone) + line, ""}
}

// hasOlder is whether scrolling past the top can show more: rows trimmed
// from the rendering, or transcript the daemon has not sent.
func (m ChatModel) hasOlder() bool {
	_, more := m.olderCursor()
	return m.droppedSettledLines > 0 || more
}

// olderCursor is the row the next older page ends before. Evicted entries
// move it forward: everything up to the newest evicted row is re-read.
func (m ChatModel) olderCursor() (int64, bool) {
	before, more := m.olderBefore, m.olderMore
	if through := m.History.EvictedThrough(); through > 0 && through >= before {
		before, more = through+1, true
	}
	return before, more && before > 0
}

// settledBlock is an entry's settled rows, head indexing its own first one.
type settledBlock struct {
	rows []string
	head int
}

// settledKey names what an entry's settled rows depend on: the entry, the
// author and time before it, how it joins the entry above, and the burst it
// ends, by the IDs at its ends and how it joins the entry above that.
type settledKey struct {
	workspace      string
	id             string
	burstFirst     string
	burstLast      string
	prior          prior
	burst          int
	epoch          int
	width          int
	follows        lane
	burstFollows   lane
	flags          DisplayFlags
	separated      bool
	burstSeparated bool
}

// settledKey is false for an entry, or a burst end, without an ID to name.
func (m ChatModel) settledKey(before []HistoryEntry, entry HistoryEntry) (settledKey, bool) {
	key := settledKey{id: entry.ID, prior: priorOf(before), epoch: m.burstEpoch, width: m.Renderer.BodyWidth, workspace: m.Renderer.Workspace, flags: m.Flags}
	if entry.ID == "" || Compact(entry, m.Flags) {
		return key, false
	}
	if n := len(before); n > 0 {
		key.follows, key.separated = laneOf(before[n-1]), Separated(&before[n-1], entry, m.Flags)
	}
	burst := trailingBurst(before, m.Flags)
	if len(burst) == 0 {
		return key, true
	}
	key.burstFirst, key.burstLast, key.burst = burst[0].ID, burst[len(burst)-1].ID, len(burst)
	if n := len(before) - len(burst); n > 0 {
		key.burstFollows, key.burstSeparated = laneOf(before[n-1]), Separated(&before[n-1], burst[0], m.Flags)
	}
	return key, key.burstFirst != "" && key.burstLast != ""
}

// appendBlock settles entry after the entries before it.
func (m *ChatModel) appendBlock(before []HistoryEntry, entry HistoryEntry) {
	var block settledBlock
	block.rows, block.head = m.Renderer.Settle(before, entry, m.Flags)
	m.appendRows(entry, block)
}

func (m *ChatModel) appendRows(entry HistoryEntry, block settledBlock) {
	if entry.Kind == EntryUser && (entry.Source == "" || entry.Source == "chat") {
		m.userRows = append(m.userRows, len(m.settledLines)+block.head)
	}
	for _, row := range block.rows {
		m.settledLines = append(m.settledLines, row)
		m.settledLinesBytes += int64(len(row))
	}
	m.trimSettledLines()
}

// trimSettledLines drops the oldest rows past the caps. While you are scrolled
// up the caps stretch by readingSlack and the row you are reading is never
// dropped, so output arriving meanwhile cannot push your place off the top;
// the normal caps apply again once the transcript follows its end.
func (m *ChatModel) trimSettledLines() {
	if m.rebuilding {
		return
	}
	maxLines, maxBytes := MaxSettledLines, int64(MaxSettledLinesBytes)
	if !m.Follow {
		maxLines, maxBytes = maxLines*readingSlack, maxBytes*readingSlack
	}
	dropped := 0
	for len(m.settledLines) > maxLines || m.settledLinesBytes > maxBytes {
		if len(m.settledLines) == 0 || !m.Follow && dropped >= m.scrollOffset-m.settledOffset {
			break
		}
		removed := m.settledLines[0]
		m.settledLinesBytes -= int64(len(removed))
		m.settledLines[0] = ""
		m.settledLines = m.settledLines[1:]
		dropped++
	}

	if dropped > 0 {
		m.droppedSettledLines += dropped
		m.scrollOffset = max(0, m.scrollOffset-dropped)
		kept := m.userRows[:0]
		for _, row := range m.userRows {
			if row >= dropped {
				kept = append(kept, row-dropped)
			}
		}
		m.userRows = kept
		// Rendered rows own their text: body chunks are concatenated with a
		// nonempty rail; separators retain only small rail strings or empty text.
		fresh := make([]string, len(m.settledLines))
		copy(fresh, m.settledLines)
		clear(m.settledLines)
		m.settledLines = fresh
	}
}

// replaceSettled swaps the n settled rows at from for rows, and returns how
// many rows the caps then dropped from the top.
func (m *ChatModel) replaceSettled(from, n int, rows []string) int {
	m.settledLinesBytes += rowBytes(rows) - rowBytes(m.settledLines[from:from+n])
	m.settledLines = slices.Replace(m.settledLines, from, from+n, rows...)
	for i, at := range m.userRows {
		if at >= from+n {
			m.userRows[i] += len(rows) - n
		}
	}
	dropped := m.droppedSettledLines
	m.trimSettledLines()
	return m.droppedSettledLines - dropped
}

func rowBytes(rows []string) int64 {
	var n int64
	for _, row := range rows {
		n += int64(len(row))
	}
	return n
}

func (m *ChatModel) appendSettledEntry(entry HistoryEntry) {
	if Compact(entry, m.Flags) {
		facts := factsOf(entry)
		entry.facts = &facts
	}
	if m.History.Replace(entry) {
		m.burstEpoch++
		m.rebuildSettledLines()
		return
	}
	m.appendBlock(m.History.Entries(), entry)
	m.History.Append(entry)
}

// settleActiveStream appends assembled text and retains a live thought's last
// line as the compact action until the next action replaces it.
func (m *ChatModel) settleActiveStream() {
	watched := !m.transcript.thinkingSince.IsZero()
	for _, entry := range m.transcript.settle(m.AgentName) {
		if watched && entry.Kind == EntryThinking {
			m.ThoughtProgressText = cmp.Or(thinkingLine(entry.Text), "thinking")
		}
		m.appendSettledEntry(entry)
	}
}

func (m *ChatModel) refreshViewportContent() int {
	if m.Viewport.Height() != max(1, m.Height-6-m.chromeRows()) {
		m.SetSize(m.Width, m.Height)
		return m.scrollLimit
	}
	if m.Follow {
		// Reading older history stretched both caps; at the end they return.
		m.History.Trim()
		m.trimSettledLines()
		m.settled = nil
	}
	allLines := m.headerLines()
	if !m.Follow {
		// a header growing or shrinking above must not move what you read
		m.scrollOffset = max(0, m.scrollOffset+len(allLines)-m.settledOffset)
	}
	m.settledOffset = len(allLines)
	allLines = append(allLines, m.settledLines...)

	last, stacks := laneNone, false
	if entries := m.History.Entries(); len(entries) > 0 {
		last = laneOf(entries[len(entries)-1])
		stacks = Compact(entries[len(entries)-1], m.Flags)
		if burst := trailingBurst(entries, m.Flags); len(burst) > 0 {
			if key := m.rowsKey(); key != m.burstRowsKey {
				m.burstRows = m.Renderer.BurstBlock(entries[:len(entries)-len(burst)], burst, m.Flags)
				m.burstRowsKey = key
				m.burstRenders++
			}
			allLines = append(allLines, m.burstRows...)
		}
	}
	if m.transcript.activeKind != StreamKindNone && m.transcript.activeText != "" &&
		(m.transcript.activeKind != StreamKindThinking || m.Flags.Thinking) {
		activeEntry := HistoryEntry{Kind: m.transcript.activeEntryKind(), Speaker: m.AgentName, Text: m.transcript.activeText, Live: true}
		allLines = append(allLines, m.liveBlock(activeEntry)...)
		last, stacks = laneOf(activeEntry), false
	}

	// One live-tail slot stays occupied by the last action until another begins.
	action := ""
	switch {
	case m.transcript.activeKind == StreamKindThinking && m.transcript.activeText != "" && !m.Flags.Thinking:
		action = m.renderThought()
	case m.toolLabel() != "" && (m.latestProgress() != nil || !m.Flags.Tools):
		action = m.renderProgress()
	case m.ThoughtProgressText != "" && !m.Flags.Thinking:
		width := max(1, m.Renderer.BodyWidth-railWidth)
		action = markChrome + DefaultStyles.Faint.Render(ansi.Truncate(m.ThoughtProgressText, width, "…"))
	}
	if action != "" {
		if len(allLines) > 0 && !stacks {
			allLines = append(allLines, strings.TrimRight(m.Renderer.rail(joint(last, laneBusy)), " "))
		}
		allLines = append(allLines, m.Renderer.rail(laneBusy)+action)
	}
	allLines = append(allLines, m.pendingRows()...)
	m.frameLines = allLines

	totalLines := len(allLines)
	vpHeight := max(1, m.Viewport.Height())
	maxScroll := max(0, totalLines-vpHeight)
	m.scrollLimit = maxScroll

	var visibleSlice []string
	if m.Follow {
		m.scrollOffset = maxScroll
		visibleSlice = allLines[maxScroll:totalLines]
	} else {
		m.scrollOffset = max(0, min(m.scrollOffset, maxScroll))
		end := min(totalLines, m.scrollOffset+vpHeight)
		if m.scrollOffset < end {
			visibleSlice = allLines[m.scrollOffset:end]
		}
	}
	m.Viewport.rows = visibleSlice
	return maxScroll
}

// rowsKey names what rows drawn after the settled transcript depend on.
func (m ChatModel) rowsKey() burstRowsKey {
	return burstRowsKey{entries: m.History.Len(), evicted: m.History.EvictedCount(), epoch: m.burstEpoch, width: m.Renderer.BodyWidth, workspace: m.Renderer.Workspace, flags: m.Flags}
}

// liveBlock is the reply streaming in as rows, rendered again only when the
// reply or the transcript end before it changed.
func (m *ChatModel) liveBlock(entry HistoryEntry) []string {
	key := liveRowsKey{burstRowsKey: m.rowsKey(), text: entry.Text, kind: entry.Kind}
	if key != m.liveRowsKey {
		start := time.Now()
		m.liveRows, _ = m.Renderer.Block(m.History.Entries(), entry, m.Flags)
		m.liveRowsKey, m.liveDrawn = key, start
		m.liveInterval = max(liveFrame, 4*time.Since(start))
	}
	return m.liveRows
}

// pendingRows are your messages the daemon has not echoed yet, greyed out at
// the end of the transcript where they will settle. Each follows whatever is
// live above it, so the rails and names join up as they will once settled.
func (m ChatModel) pendingRows() []string {
	if len(m.pendingUsers) == 0 && len(m.pendingContinuations) == 0 {
		return nil
	}
	before := slices.Clone(recent(m.History.Entries()))
	if m.transcript.activeKind != StreamKindNone && m.transcript.activeText != "" {
		before = append(before, HistoryEntry{Kind: m.transcript.activeEntryKind(), Speaker: m.AgentName})
	}
	if m.toolLabel() != "" && (m.latestProgress() != nil || !m.Flags.Tools) {
		before = append(before, HistoryEntry{Kind: EntryTool, Speaker: m.AgentName})
	} else if m.ThoughtProgressText != "" && !m.Flags.Thinking {
		before = append(before, HistoryEntry{Kind: EntryThinking, Speaker: m.AgentName})
	}
	var rows []string
	for _, p := range m.pendingUsers {
		state := sending
		if p.Queued {
			state = queued
		}
		text := p.Text
		if p.Expired {
			state = unresolved
			text += "\nOperation " + p.OperationID + " expired; its outcome is unknown."
		}
		if p.BlockingReason != "" && !p.Expired {
			text += "\nWaiting: " + p.BlockingReason
		}
		entry := HistoryEntry{Kind: EntryUser, Speaker: "You", Text: text, Timestamp: p.At, Pending: state}
		block, _ := m.Renderer.Block(before, entry, m.Flags)
		rows = append(rows, block...)
		before = append(before, entry)
	}
	for _, id := range slices.Sorted(maps.Keys(m.pendingContinuations)) {
		if m.pendingContinuations[id].Expired {
			entry := HistoryEntry{Kind: EntryError, Text: "Continue operation " + id + " expired; its outcome is unresolved."}
			block, _ := m.Renderer.Block(before, entry, m.Flags)
			rows = append(rows, block...)
		}
	}
	return rows
}

// jumpToYou scrolls to the start of your previous or next message. Past
// your newest message it follows the live transcript again.
func (m *ChatModel) jumpToYou(back bool) {
	at := m.scrollOffset
	if m.Follow {
		at = m.scrollLimit
	}
	target := -1
	for _, row := range m.userRows {
		row += m.settledOffset
		if back && row < at {
			target = row
		}
		if !back && row > at {
			target = row
			break
		}
	}
	switch {
	case target >= 0 && target < m.scrollLimit:
		m.Follow = false
		m.scrollOffset = target
	case !back || target >= 0:
		m.Follow = true
	}
	m.refreshViewportContent()
}

// scrollBy moves through the complete rendered transcript, including live output.
func (m *ChatModel) scrollBy(rows int) {
	if rows < 0 {
		m.Follow = false
	} else if m.Follow {
		return
	}
	m.scrollOffset = max(0, m.scrollOffset+rows)
	maxScroll := m.refreshViewportContent()
	if rows > 0 && m.scrollOffset >= maxScroll {
		m.Follow = true
		m.refreshViewportContent()
	}
}

// loadOlder runs when you are scrolled to the top of the transcript: rows
// trimmed from the rendering come back from retained history first, then a
// page is asked of the daemon.
func (m *ChatModel) loadOlder() tea.Cmd {
	if m.Follow || m.scrollOffset > 0 || m.loadingOlder {
		return nil
	}
	if m.droppedSettledLines > 0 {
		m.rebuildSettledLines()
		m.refreshViewportContent()
		return nil
	}
	before, more := m.olderCursor()
	if !more {
		return nil
	}
	m.loadingOlder = true
	m.refreshViewportContent()
	client, id, generation := m.client, m.SessionID, m.Generation
	return func() tea.Msg {
		page, err := client.History(context.Background(), before, olderPageRows)
		return ChatOlderLoadedMsg{SessionID: id, Generation: generation, Page: page, Err: err}
	}
}

// showOlder puts a fetched page above what is shown without moving it.
func (m *ChatModel) showOlder(msg ChatOlderLoadedMsg) ChatModel {
	if msg.SessionID != m.SessionID || msg.Generation != m.Generation || !m.loadingOlder {
		return *m
	}
	m.loadingOlder = false
	if msg.Err != nil {
		m.AddError(fmt.Sprintf("Could not load earlier messages: %v", msg.Err))
		return *m
	}
	events := make([]daemon.StreamEvent, 0, len(msg.Page.Events))
	for _, event := range msg.Page.Events {
		if event.EntryID == "" || m.History.Find(event.EntryID) < 0 {
			events = append(events, event)
		}
	}
	older := replayTranscript(events, m.AgentName)
	for i := range older {
		if Compact(older[i], m.Flags) {
			facts := factsOf(older[i])
			older[i].facts = &facts
		}
	}
	m.History.Prepend(older)
	m.olderBefore, m.olderMore = msg.Page.Before, msg.Page.More && msg.Page.Before > 0
	m.rebuildSettledLines()
	m.refreshViewportContent()
	return *m
}
