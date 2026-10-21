package terminal

import (
	"os"
	"regexp"
	"testing"
)

// the TUI relies on cli/third_party/bubbletea painting on demand; a
// dependency bump that drops the replace silently brings back a 60fps
// ticker on every idle client. test binaries carry no module deps in their
// build info, so this reads go.mod.
func TestBubbleteaIsThePatchedCopy(t *testing.T) {
	mod, err := os.ReadFile("../../go.mod")
	if err != nil {
		t.Fatal(err)
	}
	replace := regexp.MustCompile(`(?m)^replace charm\.land/bubbletea/v2 => \./third_party/bubbletea$`)
	if !replace.Match(mod) {
		t.Fatal("cli/go.mod no longer replaces bubbletea with third_party/bubbletea (see third_party/bubbletea.patch)")
	}
}
