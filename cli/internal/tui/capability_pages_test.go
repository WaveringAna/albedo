// Stale replies from closed capability pages must not satisfy reopened pages.
// E2E cannot deterministically interleave replies across discarded views.
package tui

import (
	"albedo/cli/internal/config"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestCapabilityStaleReplyFromReplacedInstanceIsRejected(t *testing.T) {
	prefs := config.CapabilityPrefs{Global: map[string]map[string]bool{"skills": {"draft": false}}}
	items := []capabilityItem{{ID: "draft"}}
	a := NewCapabilityPageModel(nil, "s", "workspace-a", "skills")
	a, _ = a.Update(capabilityLoadedMsg{Gen: a.Generation, Items: items, Prefs: prefs})
	a, _ = a.Update(tea.KeyPressMsg{Code: 'r'})
	zombie := capabilityLoadedMsg{Gen: a.Generation, Items: items, Prefs: prefs}
	a, _ = a.Update(tea.KeyPressMsg{Code: tea.KeyEscape})

	b := NewCapabilityPageModel(nil, "s", "workspace-b", "skills")
	b, _ = b.Update(capabilityLoadedMsg{Gen: b.Generation, Items: items, Prefs: prefs})
	before := b.Generation
	b, _ = b.Update(tea.KeyPressMsg{Code: tea.KeySpace})
	if !b.Saving || b.Generation == before {
		t.Fatal("a toggle must start a save under a fresh generation")
	}
	saveGen := b.Generation
	b, _ = b.Update(capabilitySavedMsg{Gen: saveGen})
	if b.Saving || !b.Loading {
		t.Fatal("a completed save must fetch acknowledged state")
	}
	reloaded := capabilityLoadedMsg{Gen: b.Generation, Items: items, Prefs: prefs}
	if zombie.Gen == saveGen || zombie.Gen == reloaded.Gen {
		t.Fatal("generations collided across page instances")
	}
	b, _ = b.Update(zombie)
	if !b.Loading {
		t.Fatal("the discarded page's reply cleared the current fetch")
	}
	b, _ = b.Update(reloaded)
	if b.Loading || b.Prefs.Enabled("s", "skills", "draft") || len(b.Items) != 1 {
		t.Fatal("the current page's acknowledged state was not accepted")
	}
}
