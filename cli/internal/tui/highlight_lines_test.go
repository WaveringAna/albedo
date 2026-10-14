// Highlighting a diff in one pass must color every line exactly as
// highlighting it alone did. Daemon E2E cannot see the TUI's escapes.
package tui

import (
	"slices"
	"strings"
	"testing"

	"github.com/alecthomas/chroma/v2"
	"github.com/alecthomas/chroma/v2/formatters"
	chromastyles "github.com/alecthomas/chroma/v2/styles"
)

func TestHighlightLinesMatchesOneLineAtATime(t *testing.T) {
	lines := []string{"func main() {", "\tx := \"a string\" // note", "\treturn 42", "}", "", "/* open comment", "import \"fmt\""}
	for _, name := range []string{"x.go", "x.py", "x.gleam", "x.md", "noext"} {
		lexer := lexerFor(name)
		cache := &highlightCache{}
		got := HighlightLines(lines, lexer, cache)
		if again := HighlightLines(lines, lexer, cache); !slices.Equal(again, got) {
			t.Errorf("%s: cached lines differ: %q", name, again)
		}
		for i, line := range lines {
			want := line
			if lexer != nil {
				tokens, _ := chroma.Coalesce(lexer).Tokenise(nil, line)
				var b strings.Builder
				_ = formatters.TTY256.Format(&b, chromastyles.Get(codeTheme(transcriptInk)), tokens)
				want = strings.ReplaceAll(b.String(), "\n", "")
			}
			if got[i] != want {
				t.Errorf("%s line %d: got %q want %q", name, i, got[i], want)
			}
		}
	}
}
