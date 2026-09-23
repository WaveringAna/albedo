package display

import (
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestRowAndPanelStayWithinCellBudget(t *testing.T) {
	labels := []string{"prod-api-01", "東京サーバー", "e\u0301", "👩‍💻", strings.Repeat("x", 200)}
	for w := 0; w <= 100; w++ {
		for _, label := range labels {
			for _, selected := range []bool{false, true} {
				for _, got := range []string{Row(label, "long metadata here", w, selected), Panel(label, w)} {
					if !utf8.ValidString(got) || lipgloss.Width(got) > w {
						t.Fatalf("width=%d: %q", w, got)
					}
				}
			}
		}
	}
}

func TestResponsiveMetadataAndExactPanelWidth(t *testing.T) {
	if strings.Contains(ansi.Strip(Row("alpha", "EU-WEST", 24, false)), "EU-WEST") {
		t.Fatal("metadata should disappear")
	}
	if !strings.Contains(ansi.Strip(Row("alpha", "EU-WEST", 60, false)), "EU-WEST") {
		t.Fatal("metadata should fit")
	}
	if got := lipgloss.Width(Panel("alpha", 40)); got != 40 {
		t.Fatalf("outer width %d", got)
	}
}

func TestRowRefactorPreservesLiteralPrefixAndLabel(t *testing.T) {
	// A before/after contract for the two previously duplicated branches.
	for _, label := range []string{"alpha", "東京", "e\u0301"} {
		for _, active := range []bool{false, true} {
			before := "  " + label
			if active {
				before = "> " + label
			}
			if got := ansi.Strip(Row(label, "", 32, active)); got != before {
				t.Fatalf("%q != %q", got, before)
			}
		}
	}
}

func TestRowRefactorMatchesPreviousRenderingByteForByte(t *testing.T) {
	for _, width := range []int{3, 10, 32, 60} {
		for _, label := range []string{"alpha", "東京", "e\u0301", strings.Repeat("x", 100)} {
			for _, current := range []bool{false, true} {
				name := ansi.Truncate(label, width-2, "…")
				var before string
				if current {
					before = lipgloss.NewStyle().Bold(true).Render("> " + name)
				} else {
					before = lipgloss.NewStyle().Bold(false).Render("  " + name)
				}
				if got := Row(label, "", width, current); got != before {
					t.Fatalf("width=%d current=%v: %q != %q", width, current, got, before)
				}
			}
		}
	}
}
