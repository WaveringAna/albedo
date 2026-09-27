// Display flags persist across TUI chat switches and process restarts.
package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"path/filepath"

	tea "charm.land/bubbletea/v2"
	"testing"
)

func TestDisplayPreferencesFollowChatsAndRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "picker.json")
	first := daemon.Session{ID: "first"}
	app := NewAppModel(nil, config.Profiles{}, &first, "/work", false)
	app.LoadPrefs(path)
	for _, command := range []string{"/t", "/v"} {
		app.Chat.TextArea.SetValue(command)
		updated, _ := app.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
		app = updated.(AppModel)
	}
	if !app.Chat.Flags.Thinking || !app.Chat.Flags.Tools {
		t.Fatal("toggles did not apply")
	}
	if saved := loadSessionPrefs(path); !saved.Thinking || !saved.Tools {
		t.Fatalf("not saved: %+v", saved)
	}
	second := daemon.Session{ID: "second"}
	chat := app.newChatModel(&second)
	if !chat.Flags.Thinking || !chat.Flags.Tools {
		t.Fatal("new chat reset display choices")
	}
	restarted := NewAppModel(nil, config.Profiles{}, &second, "/work", false)
	restarted.LoadPrefs(path)
	if !restarted.Chat.Flags.Thinking || !restarted.Chat.Flags.Tools {
		t.Fatal("restart reset display choices")
	}
	restarted.Chat.TextArea.SetValue("/t")
	updated, _ := restarted.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	restarted = updated.(AppModel)
	if !restarted.Chat.Flags.Tools || restarted.Chat.Flags.Thinking {
		t.Fatal("thinking toggle also reset verbose")
	}
	if saved := loadSessionPrefs(path); saved.Thinking || !saved.Tools {
		t.Fatalf("off state not saved: %+v", saved)
	}
}
