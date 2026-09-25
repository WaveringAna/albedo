package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestContextInspectorPrefersProviderUsageToEstimate(t *testing.T) {
	measured, cached, estimate := 194000, 12000, 217000
	m := NewContextInspectorModel(nil, "fixture")
	m.SetSize(100, 25)
	m.Loading = false
	m.Snapshot = &ContextSnapshot{
		State: "ready", Model: "fixture", Sections: []ContextSection{},
		Compaction: CompactionState{
			Status: "compacted", EstimatedInputTokens: &estimate,
			ProviderInputTokens: &measured, ProviderCachedInputTokens: &cached,
		},
	}
	if err := validContextSnapshot(*m.Snapshot); err != nil {
		t.Fatal(err)
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "provider input: 194,000 tokens · 12,000 cached tokens") || strings.Contains(view, "estimated input:") {
		t.Fatalf("provider usage should be primary: %s", view)
	}
	m.Snapshot.Compaction.ProviderInputTokens = nil
	m.Snapshot.Compaction.ProviderCachedInputTokens = nil
	if !strings.Contains(ansi.Strip(m.View()), "estimated input: 217,000 tokens") {
		t.Fatal("estimate missing when the provider did not report usage")
	}
	invalid := -1
	m.Snapshot.Compaction.ProviderInputTokens = &invalid
	if validContextSnapshot(*m.Snapshot) == nil {
		t.Fatal("accepted negative provider usage")
	}
}
