// Disabled capability navigation must keep keyboard cursor visible.
package tui

import (
	"albedo/cli/internal/config"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// A refresh from a closed page must not satisfy a reopened page's reload.
// The TUI routes both replies by app state, so E2E cannot force this ordering.
func TestCapabilityStaleReplyFromReplacedInstanceIsRejected(t *testing.T) {
	home, workspaceA, workspaceB := t.TempDir(), t.TempDir(), t.TempDir()
	t.Setenv("HOME", home) // keep skill discovery out of the real home directory
	for _, workspace := range []string{workspaceA, workspaceB} {
		if err := os.MkdirAll(filepath.Join(workspace, ".agents", "skills", "draft"), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(workspace, ".agents", "skills", "draft", "SKILL.md"), []byte("---\nname: draft\ndescription: test\n---\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := config.SetCapability(home, "s", "skills", "draft", true, false); err != nil {
		t.Fatal(err)
	}

	// Instance A loads, refreshes, and is left behind while the refresh is
	// still in flight.
	a := NewCapabilityPageModel(nil, "s", workspaceA, "skills")
	a.Home = home
	a.SetSize(65, 14)
	a, _ = a.Update(a.Init()().(capabilityLoadedMsg))
	a, refresh := a.Update(tea.KeyPressMsg{Code: 'r'})
	a, _ = a.Update(tea.KeyPressMsg{Code: tea.KeyEscape})

	// The reopened instance replaces A. It loads, saves, and waits for its
	// post-save reload.
	b := NewCapabilityPageModel(nil, "s", workspaceB, "skills")
	b.Home = home
	b.SetSize(65, 14)
	b, _ = b.Update(b.Init()().(capabilityLoadedMsg))
	if len(b.Items) != 1 || b.Items[0].ID != "draft" {
		t.Fatalf("expected the draft skill, got %+v (err=%q)", b.Items, b.Error)
	}
	// space starts a save under a fresh generation; the daemon side of the
	// toggle is out of scope here, so the command it returned is dropped and
	// the successful reply is fed below.
	before := b.Generation
	b, _ = b.Update(tea.KeyPressMsg{Code: tea.KeySpace})
	if !b.Saving || b.Generation == before {
		t.Fatalf("a toggle must start a save under a fresh generation: saving=%v gen=%d", b.Saving, b.Generation)
	}
	saveGen := b.Generation
	b, cmd := b.Update(capabilitySavedMsg{Gen: saveGen})
	if b.Saving || !b.Loading {
		t.Fatal("a completed save must leave the page loading its post-save state")
	}
	var reloaded capabilityLoadedMsg
	for _, sub := range cmd().(tea.BatchMsg) {
		if msg, ok := sub().(capabilityLoadedMsg); ok {
			reloaded = msg
		}
	}

	// A's refresh reply lands between B's save and B's reload reply. Its
	// generation belongs to a fetch of another instance and must collide
	// with nothing B is waiting for.
	zombie := refresh().(capabilityLoadedMsg)
	if zombie.Gen == saveGen || zombie.Gen == reloaded.Gen {
		t.Fatalf("generations are not unique across instances: zombie %d, save %d, reload %d", zombie.Gen, saveGen, reloaded.Gen)
	}
	b, _ = b.Update(zombie)
	if !b.Loading {
		t.Fatal("the replaced instance's reply cleared Loading while the post-save reload was still in flight")
	}

	// B's own reload reply is the one that answers.
	b, _ = b.Update(reloaded)
	if b.Loading || b.Prefs.Enabled("s", "skills", "draft") {
		t.Fatalf("the post-save reload reply was not accepted: loading=%v enabled=%v", b.Loading, b.Prefs.Enabled("s", "skills", "draft"))
	}
	if len(b.Items) != 1 || b.Items[0].ID != "draft" {
		t.Fatalf("the post-save reload was rejected: %+v (err=%q)", b.Items, b.Error)
	}
}

func TestCapabilityPagesFindDisabledEntriesAndKeepCursorVisible(t *testing.T) {
	home, workspace := t.TempDir(), t.TempDir()
	if err := os.MkdirAll(filepath.Join(workspace, ".agents", "skills", "draft"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, ".agents", "skills", "draft", "SKILL.md"), []byte(`---
name: draft
description: test
---
`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "AGENTS.md"), []byte("instructions"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := config.SetCapability(home, "s", "skills", "draft", true, false); err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"skills", "instructions"} {
		m := NewCapabilityPageModel(nil, "s", workspace, kind)
		m.Home = home
		m.SetSize(65, 14)
		loaded := m.Init()().(capabilityLoadedMsg)
		m, _ = m.Update(loaded)
		want := "draft"
		if kind == "instructions" {
			want = "project:AGENTS.md"
		}
		found := false
		for i, item := range m.Items {
			if item.ID == want {
				found = true
				m.Cursor = i
				if kind == "skills" && m.Prefs.Enabled("s", kind, item.ID) {
					t.Fatal("disabled skill appeared enabled")
				}
				break
			}
		}
		if !found {
			t.Fatalf("%s: missing %s; err=%q", kind, want, m.Error)
		}
	}
	m := NewCapabilityPageModel(nil, "s", workspace, "skills")
	m.SetSize(40, 12)
	m.Loading = false
	for i := 0; i < 30; i++ {
		m.Items = append(m.Items, capabilityItem{ID: strings.Repeat("a", i+1), Title: strings.Repeat("a", i+1)})
	}
	for i := 0; i < 29; i++ {
		m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	}
	if !strings.Contains(ansi.Strip(m.View()), strings.Repeat("a", 29)) {
		t.Fatal("selected row scrolled offscreen")
	}
}
