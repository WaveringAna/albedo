package tui

import (
	"albedo/cli/internal/config"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

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
		m, _ = m.Update(tea.KeyMsg{Type: tea.KeyDown})
	}
	if !strings.Contains(ansi.Strip(m.View()), strings.Repeat("a", 29)) {
		t.Fatal("selected row scrolled offscreen")
	}
}
