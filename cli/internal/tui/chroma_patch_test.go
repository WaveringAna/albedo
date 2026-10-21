// Highlighting goes through chroma, and cli/third_party replaces it with a
// copy whose lexers and styles are built the first time one is asked for
// instead of all of them at init (see third_party/chroma.patch). A highlighted
// code block and a highlighted diff must not change: every language a reply
// names, and every file name a diff names, is rendered through the real path
// and compared against testdata/chroma_highlights.golden, taken from the
// stock module. Daemon E2E sees transcript bytes, not the escapes a code block
// carries.
package tui

import (
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// chromaCase is one thing a client highlights: a fenced code block, or the
// lines of a diff for a file.
type chromaCase struct {
	name string
	// fence is the language a reply's fence names; empty renders a fence with
	// no language, which glamour sniffs for.
	fence string
	code  string
}

var chromaFences = []chromaCase{
	{name: "go", fence: "go", code: "func main() {\n\tfmt.Println(\"hi\", 42) // note\n}"},
	{name: "golang alias", fence: "golang", code: "type thing struct { name string }"},
	{name: "python", fence: "python", code: "def f(x):\n    return f\"{x!r}\"  # note\n"},
	{name: "gleam", fence: "gleam", code: "pub fn main() { io.println(\"hi\") }"},
	{name: "rust", fence: "rust", code: "fn main() { let x: u8 = 1; }"},
	{name: "javascript", fence: "js", code: "const a = async () => await fetch('/x');"},
	{name: "typescript", fence: "ts", code: "let a: number = 1; // note"},
	{name: "shell", fence: "sh", code: "ps -o %cpu= -p $(pgrep -n albedo)"},
	{name: "json", fence: "json", code: `{"a": [1, 2.5, null]}`},
	{name: "yaml", fence: "yaml", code: "a: 1\nb: [x, y]"},
	{name: "toml", fence: "toml", code: "a = 1\n[b]\nc = \"d\""},
	{name: "markdown", fence: "md", code: "# heading\n\n- item **bold**"},
	{name: "html", fence: "html", code: "<p class=\"x\">hi</p>"},
	{name: "svelte", fence: "svelte", code: "<script>let a = 1;</script>\n<p>{a}</p>"},
	{name: "erb", fence: "erb", code: "<p><%= a %></p>"},
	{name: "emacs lisp", fence: "elisp", code: "(defun f (x) (message \"%s\" x))"},
	{name: "caddyfile", fence: "caddyfile", code: "example.com {\n\troot * /srv\n}"},
	{name: "diff", fence: "diff", code: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b"},
	{name: "sql", fence: "sql", code: "SELECT `a` FROM [b] WHERE c = 'd';"},
	{name: "unknown language", fence: "notalanguage", code: "some text here"},
	{name: "no language", fence: "", code: "package main\n\nfunc main() {}"},
	{name: "no language, prose", fence: "", code: "just some words, nothing to sniff"},
}

// chromaDiffFiles are file names a transcript highlights a diff by: the
// patterns chroma matches on, and the names no lexer claims.
var chromaDiffFiles = []string{"x.go", "x.py", "x.gleam", "x.rs", "x.ts", "main.c", "x.rb", "Makefile", "x.toml", "x.el", "x.md", "x.html", "README", "x.unknown", "Dockerfile"}

var chromaDiffLines = []string{
	"func main() {\n\tx := \"a string\" // note\n\treturn 42\n}",
	"# comment\nkey = \"value\"\nkey2: 1",
}

// TestChromaHighlightsLikeStock renders every case and compares it against the
// golden. Set ALBEDO_WRITE_GOLDEN=1 to rewrite it; the golden in the tree was
// written by running this against the stock module:
//
//	go -C cli test -modfile=<a copy of go.mod without the chroma replace> \
//	  ./internal/tui -run TestChromaHighlightsLikeStock -count=1
func TestChromaHighlightsLikeStock(t *testing.T) {
	if os.Getenv("ALBEDO_WRITE_GOLDEN") != "" {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile("testdata/chroma_highlights.golden", []byte(strings.Join(chromaRender(t), "\n")+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	golden, err := os.ReadFile("testdata/chroma_highlights.golden")
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Split(strings.TrimSuffix(string(golden), "\n"), "\n")
	got := chromaRender(t)
	if len(got) != len(want) {
		t.Fatalf("golden has %d cases, this renders %d", len(want), len(got))
	}
	for i, line := range got {
		if line != want[i] {
			quotedWant, err := strconv.Unquote(want[i])
			if err != nil {
				t.Fatalf("case %d: golden line %q: %v", i, want[i], err)
			}
			quotedGot, _ := strconv.Unquote(line)
			t.Fatalf("case %d changed\n got: %q\nwant: %q", i, quotedGot, quotedWant)
		}
	}
}

// chromaRender is one quoted line per case: a code block rendered at 80
// columns, or the lines of a diff highlighted for a file.
func chromaRender(t *testing.T) []string {
	t.Helper()
	before, styles := transcriptInk, DefaultStyles
	t.Cleanup(func() { useInk(before); DefaultStyles = styles })
	var out []string
	render := func(section string, text string) {
		out = append(out, strconv.Quote(section+"\x00"+text))
	}
	for _, palette := range []bool{false, true} {
		if palette {
			useInk(testInk(t))
		}
		for _, c := range chromaFences {
			fence := "```"
			if c.fence != "" {
				fence += c.fence
			}
			doc := fence + "\n" + c.code + "\n```\n"
			render("fence/"+c.name, RenderMarkdownAnsi(doc, 80))
		}
		for _, file := range chromaDiffFiles {
			for _, diff := range chromaDiffLines {
				render("diff/"+file, strings.Join(HighlightLines(strings.Split(diff, "\n"), lexerFor(file), nil), "\n"))
			}
		}
	}
	return out
}

// TestChromaIsThePatchedCopy catches a dependency bump that drops the replace
// and quietly builds every lexer and style at init again.
func TestChromaIsThePatchedCopy(t *testing.T) {
	mod, err := os.ReadFile("../../go.mod")
	if err != nil {
		t.Fatal(err)
	}
	replace := regexp.MustCompile(`(?m)^replace github\.com/alecthomas/chroma/v2 => \./third_party/chroma$`)
	if !replace.Match(mod) {
		t.Fatal("cli/go.mod no longer replaces chroma with third_party/chroma (see third_party/chroma.patch)")
	}
}
