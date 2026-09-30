// TUI routing and in-flight save rendering cannot be exercised by daemon E2E
// tests. These checks keep display text from controlling either state machine.
package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"fmt"
	"testing"
)

func TestCatalogFailureUsesErrorIdentity(t *testing.T) {
	for _, tc := range []struct {
		err  error
		show bool
	}{
		{fmt.Errorf("catalog: %w", daemon.UpgradeNeeded("for commands")), true},
		{errors.New("unrelated service needs an update"), false},
	} {
		m := AppModel{}
		next, _ := m.Update(commandCatalogLoadedMsg{Err: tc.err})
		if next.(AppModel).Notices.HasError() != tc.show {
			t.Fatalf("catalog failure was routed using its wording: %v", tc.err)
		}
	}
}
