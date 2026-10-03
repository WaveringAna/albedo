package tui

import (
	"strings"

	"github.com/charmbracelet/x/ansi"
)

func wrapOrChunkLine(line string, width int) []string {
	if width <= 0 {
		width = 80
	}
	if ansi.StringWidth(line) <= width {
		return []string{line}
	}
	// Match wrap-ansi's hard:true, trim:false word placement: a separator
	// consumes a cell before deciding whether the next word fits.
	words := strings.Split(line, " ")
	rows := []string{""}
	used := 0
	for i, word := range words {
		if i > 0 {
			if used >= width {
				rows = append(rows, "")
				used = 0
			}
			rows[len(rows)-1] += " "
			used++
		}
		wordWidth := ansi.StringWidth(word)
		if wordWidth > width {
			remaining := width - used
			breaksHere := 1 + (wordWidth-remaining-1)/width
			breaksNext := (wordWidth - 1) / width
			if breaksNext < breaksHere {
				rows = append(rows, "")
				used = 0
			}
			wrapped := strings.Split(ansi.Hardwrap(rows[len(rows)-1]+word, width, true), "\n")
			rows[len(rows)-1] = wrapped[0]
			rows = append(rows, wrapped[1:]...)
			used = ansi.StringWidth(rows[len(rows)-1])
			continue
		}
		if used+wordWidth > width && used > 0 && wordWidth > 0 {
			rows = append(rows, "")
			used = 0
		}
		rows[len(rows)-1] += word
		used += wordWidth
	}
	// Every viewport row can be rendered alone after a history scroll. Reopen
	// styles that cross a physical wrap, as wrap-ansi does for the TS rows.
	style := ""
	for i, row := range rows {
		if style != "" {
			rows[i] = style + row
		}
		for _, code := range sgrCode.FindAllString(row, -1) {
			if code == "\x1b[0m" || code == "\x1b[m" {
				style = ""
			} else {
				style += code
			}
		}
		if style != "" && i < len(rows)-1 {
			rows[i] += "\x1b[0m"
		}
	}
	return rows
}

func (m ChatModel) promptLines() int {
	lineCount := m.TextArea.LineCount()
	if lineCount <= 1 {
		return max(1, m.TextArea.LineInfo().Height)
	}
	cp := m.TextArea
	for cp.Line() > 0 {
		cp.CursorUp()
	}
	total := 0
	for line := range lineCount {
		total += cp.LineInfo().Height
		if line < lineCount-1 {
			curr := cp.Line()
			for cp.Line() == curr {
				beforeRow := cp.LineInfo().RowOffset
				cp.CursorDown()
				if cp.Line() == curr && cp.LineInfo().RowOffset == beforeRow {
					break
				}
			}
		}
	}
	return max(1, total)
}

func (m ChatModel) maxPromptHeight() int {
	if m.Height > 0 {
		return max(1, min(6, (m.Height-8)/2))
	}
	return 6
}

func (m ChatModel) promptHeight() int {
	return min(m.promptLines(), m.maxPromptHeight())
}

func (m ChatModel) inputRows() int {
	if len(m.effortOptions) > 0 {
		return 4 // breathing room, title, choices, keyboard hint; no composer
	}
	menu := min(4, len(m.CommandMenu.Matches(m.TextArea.Value())))
	return m.promptHeight() + menu
}

func (m ChatModel) chromeRows() int {
	return m.inputRows() + m.Notices.ChromeRows()
}

func (m *ChatModel) syncLayout() {
	m.TextArea.SetHeight(m.maxPromptHeight())
	m.Viewport.SetHeight(max(1, m.Height-6-m.chromeRows()))
	m.refreshViewportContent()
}

func (m *ChatModel) SetSize(width, height int) {
	if m == nil || m.History == nil {
		return
	}
	m.Width, m.Height = max(1, width), max(1, height)

	available := max(1, m.Width-2*m.padding())
	transcriptWidth := available
	if sw := m.sidebarWidth(); sw > 0 {
		transcriptWidth -= sw + 2
	}

	m.Viewport.SetWidth(transcriptWidth)
	m.TextArea.SetWidth(available)
	m.TextArea.SetHeight(m.maxPromptHeight())
	m.Viewport.SetHeight(max(1, m.Height-6-m.chromeRows()))

	// settled rows are rendered at the body width alone, so only a new body
	// width renders them again
	if body := min(100, available); body != m.Renderer.BodyWidth {
		m.Renderer.BodyWidth = body
		m.rebuildSettledLines()
	}
	m.refreshViewportContent()
}
