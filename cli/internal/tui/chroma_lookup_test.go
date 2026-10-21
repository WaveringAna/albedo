package tui

import (
	"slices"
	"testing"

	"github.com/alecthomas/chroma/v2/lexers"
)

// The patched lexers package answers lookups out of an index instead of a
// registry that already holds every lexer, so each way of naming a lexer is
// pinned here: by name, by alias, by file name (and the suffix an editor
// leaves on one), by mime type, and by sniffing the text. chroma's own tests
// are not vendored, so nothing else would notice a lookup that stops working.
func TestChromaFindsLexersEveryWay(t *testing.T) {
	for _, name := range []string{"Go", "go", "golang", "EmacsLisp", "elisp", "markdown", "Markdown", "PHTML"} {
		if lexers.Get(name) == nil {
			t.Errorf("Get(%q) found no lexer", name)
		}
	}
	for file, want := range map[string]string{
		"x.go":      "Go",
		"x.go.bak":  "Go",
		"x.py":      "Python",
		"x.el":      "EmacsLisp",
		"Makefile":  "Makefile",
		"x.md":      "markdown",
		"x.toml":    "TOML",
		"x.unknown": "",
		"README":    "",
		"x.phtml":   "PHTML",
		"x.go~":     "Go",
	} {
		got := ""
		if lexer := lexers.Match(file); lexer != nil {
			got = lexer.Config().Name
		}
		if got != want {
			t.Errorf("Match(%q) = %q, want %q", file, got, want)
		}
	}
	if lexer := lexers.MatchMimeType("text/x-gosrc"); lexer == nil || lexer.Config().Name != "Go" {
		t.Errorf("MatchMimeType(text/x-gosrc) = %v", lexer)
	}
	if lexer := lexers.Analyse("package main\n\nimport \"fmt\"\n\nfunc main() { fmt.Println(1) }\n"); lexer == nil || lexer.Config().Name != "Go" {
		t.Errorf("Analyse(go source) = %v", lexer)
	}
	if !slices.Contains(lexers.Names(false), "Go") || !slices.Contains(lexers.Aliases(true), "golang") {
		t.Error("Names or Aliases lost the Go lexer")
	}
	// A Go file's registration replaces the lexer its XML file defines, and
	// the rules that come with it are the ones a code block is lexed with.
	if got := lexers.Get("Go").Config().Name; got != "Go" {
		t.Errorf("Get(Go) is %q", got)
	}
}
