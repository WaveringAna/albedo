// Where the detail goes is a pure rendering decision: the daemon sends the
// same document at every size, so no e2e through the daemon can catch a
// wrong split threshold, a pane that overflows the terminal, or detail
// dropped from parsing.
package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func detailFixture() *PageDocument {
	return &PageDocument{
		Title:   "paperclips",
		Summary: "1 open · 1 resolved",
		Empty:   "nothing vented yet",
		Rows: []PageRow{{
			ID:     "1",
			Text:   "ruff not on PATH",
			Badge:  "open",
			Tone:   ToneWarning,
			Detail: "ruff is missing from PATH; the binary lives in pre-commit's env.\n\nsuggestion: document the canonical invocation",
		}, {
			ID:    "2",
			Text:  "stale binary",
			Badge: "resolved",
			Tone:  ToneMuted,
		}},
	}
}

func pageAt(width, height int, doc *PageDocument) PageViewModel {
	m := NewPageViewModel(nil, "s", "/paperclips")
	m.SetSize(width, height)
	m.Doc, m.Busy = doc, false
	return m
}

func TestPageFitsEveryTerminal(t *testing.T) {
	for _, size := range [][2]int{{170, 40}, {120, 30}, {96, 14}, {80, 24}, {60, 12}, {40, 8}, {20, 4}} {
		view := pageAt(size[0], size[1], detailFixture()).View()
		lines := strings.Split(view, "\n")
		if len(lines) > size[1] {
			t.Fatalf("%dx%d: %d lines:\n%s", size[0], size[1], len(lines), view)
		}
		for _, line := range lines {
			if w := ansi.StringWidth(line); w > size[0] {
				t.Fatalf("%dx%d: a line is %d wide:\n%s", size[0], size[1], w, view)
			}
		}
	}
}

func TestWidePageShowsDetailBesideTheList(t *testing.T) {
	view := ansi.Strip(pageAt(120, 30, detailFixture()).View())
	for _, want := range []string{"ruff not on PATH", "│", "suggestion: document the canonical invocation", "open · #1"} {
		if !strings.Contains(view, want) {
			t.Fatalf("wide view lost %q:\n%s", want, view)
		}
	}
}

func TestNarrowPageStacksTheDetailUnderTheList(t *testing.T) {
	view := ansi.Strip(pageAt(80, 24, detailFixture()).View())
	if strings.Contains(view, "│") {
		t.Fatalf("a narrow view should not split side by side:\n%s", view)
	}
	list, detail := strings.Index(view, "stale binary"), strings.Index(view, "pre-commit's env")
	if list < 0 || detail < list {
		t.Fatalf("a narrow view should show the detail under the list:\n%s", view)
	}
}

func TestRowsWithoutDetailKeepTheFullWidth(t *testing.T) {
	doc := detailFixture()
	doc.Rows[0].Detail = ""
	view := ansi.Strip(pageAt(120, 30, doc).View())
	if strings.Contains(view, "│") || strings.Contains(view, "open · #1") {
		t.Fatalf("a page without details should keep the list alone:\n%s", view)
	}
}
