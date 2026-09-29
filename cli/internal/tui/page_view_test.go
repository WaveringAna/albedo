// The detail pane is a pure rendering decision: the daemon sends the same
// document either way, so no e2e through the daemon can catch a wrong split
// threshold, a misaligned pane, or detail dropped from parsing.
package tui

import (
	"strings"
	"testing"
)

func detailFixture() *PageDocument {
	return &PageDocument{
		Title:   "paperclips",
		Summary: "1 open",
		Empty:   "nothing vented yet",
		Rows: []PageRow{{
			ID:     "1",
			Text:   "ruff not on PATH",
			Badge:  "open",
			Tone:   ToneWarning,
			Detail: "ruff is missing from PATH; the binary lives in pre-commit's env.\n\nsuggestion: document the canonical invocation",
		}},
	}
}

func TestWidePageShowsDetailBesideTheList(t *testing.T) {
	m := NewPageViewModel(nil, "s", "/paperclips")
	m.SetSize(120, 30)
	m.Doc = detailFixture()
	view := m.View()
	for _, want := range []string{"ruff not on PATH", "│", "suggestion: document the canonical invocation", "#1 · open"} {
		if !strings.Contains(view, want) {
			t.Fatalf("wide view lost %q:\n%s", want, view)
		}
	}
}

func TestNarrowPageKeepsTheListAlone(t *testing.T) {
	m := NewPageViewModel(nil, "s", "/paperclips")
	m.SetSize(80, 24)
	m.Doc = detailFixture()
	view := m.View()
	if !strings.Contains(view, "ruff not on PATH") {
		t.Fatalf("narrow view lost the list:\n%s", view)
	}
	for _, unwanted := range []string{"│", "pre-commit's env"} {
		if strings.Contains(view, unwanted) {
			t.Fatalf("narrow view should not show the detail pane, found %q:\n%s", unwanted, view)
		}
	}
}

func TestRowsWithoutDetailKeepTheFullWidth(t *testing.T) {
	m := NewPageViewModel(nil, "s", "/work")
	m.SetSize(120, 30)
	doc := detailFixture()
	doc.Rows[0].Detail = ""
	m.Doc = doc
	if strings.Contains(m.View(), "│") {
		t.Fatal("a page without details should not split")
	}
}
