// Theme token ownership and ANSI background continuity are cross-screen
// visual invariants. Both fail silently in a real terminal — a screen that
// drifts from the palette, a selection tint cut short by a reset — and no
// daemon e2e observes terminal rendering.
package tui

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// Colors are chosen in the theme alone. A screen that picks its own drifts
// from the rest, which is how the session screen grew a second palette.
func TestColorsComeFromTheTheme(t *testing.T) {
	owners := map[string]bool{"theme.go": true, "ink.go": true, "ink_unix.go": true, "ink_other.go": true}
	positions := token.NewFileSet()
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") || owners[name] {
			continue
		}
		file, err := parser.ParseFile(positions, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, position := range themeViolations(file) {
			t.Errorf("%s picks its own color, use a theme token", positions.Position(position))
		}
	}
}

func themeViolations(file *ast.File) []token.Pos {
	imports := make(map[string]string)
	for _, spec := range file.Imports {
		path, _ := strconv.Unquote(spec.Path.Value)
		name := path[strings.LastIndexByte(path, '/')+1:]
		if strings.HasSuffix(path, "/lipgloss/v2") {
			name = "lipgloss"
		}
		if spec.Name != nil {
			name = spec.Name.Name
		}
		imports[name] = path
	}
	palette := regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)
	ansi := regexp.MustCompile("\x1b\\[([0-9;]*)m")
	var violations []token.Pos
	ast.Inspect(file, func(node ast.Node) bool {
		switch value := node.(type) {
		case *ast.SelectorExpr:
			if owner, ok := value.X.(*ast.Ident); ok && strings.HasSuffix(imports[owner.Name], "/lipgloss/v2") {
				if value.Sel.Name == "Color" || value.Sel.Name == "AdaptiveColor" {
					violations = append(violations, value.Pos())
				}
			}
		case *ast.CallExpr:
			function, ok := ast.Unparen(value.Fun).(*ast.SelectorExpr)
			if !ok {
				break
			}
			switch function.Sel.Name {
			case "Background":
				if owner, ok := function.X.(*ast.Ident); ok && imports[owner.Name] == "context" {
					break
				}
				violations = append(violations, value.Pos())
			case "Foreground":
				violations = append(violations, value.Pos())
			case "Faint", "Reverse":
				if len(value.Args) == 1 {
					if argument, ok := ast.Unparen(value.Args[0]).(*ast.Ident); ok && argument.Name == "true" {
						violations = append(violations, value.Pos())
					}
				}
			}
		case *ast.BasicLit:
			if value.Kind != token.STRING {
				break
			}
			text, err := strconv.Unquote(value.Value)
			if err != nil {
				break
			}
			if palette.MatchString(text) {
				violations = append(violations, value.Pos())
			}
			for _, sequence := range ansi.FindAllStringSubmatch(text, -1) {
				for parameter := range strings.SplitSeq(sequence[1], ";") {
					code, _ := strconv.Atoi(parameter)
					if code == 2 || code == 7 || code >= 30 && code <= 49 || code >= 90 && code <= 107 {
						violations = append(violations, value.Pos())
						return false
					}
				}
			}
		}
		return true
	})
	return violations
}

func TestThemeOwnershipSurvivesFormattingAndIgnoresComments(t *testing.T) {
	for _, scenario := range []struct {
		source string
		bad    bool
	}{
		{`// lipgloss.Color("#ffffff")
var x = context.Background()`, false},
		{`var x = (gl.Color)("2")`, true},
		{`var x = gl.AdaptiveColor{}`, true},
		{`var x = style.
Foreground(color)`, true},
		{`var x = style.Background(color)`, true},
		{`var x = style.Faint((true))`, true},
		{`var x = style.Reverse(false)`, false},
		{`var x = "\u0023ffffff"`, true},
		{`var x = "\u001b[38;2;1;2;3m"`, true},
		{`var x = "\x1b[0m"`, false},
	} {
		t.Run(scenario.source, func(t *testing.T) {
			file, err := parser.ParseFile(token.NewFileSet(), "screen.go", "package tui\nimport gl \"charm.land/lipgloss/v2\"\nimport \"context\"\n"+scenario.source, 0)
			if err != nil {
				t.Fatal(err)
			}
			if bad := len(themeViolations(file)) > 0; bad != scenario.bad {
				t.Fatalf("color violation = %v, want %v", bad, scenario.bad)
			}
		})
	}
}

// A full reset comes as "ESC[m" from Lip Gloss and "ESC[0m" from the raw ink;
// the selection surface and a diff row's tint must survive both.
func TestBackgroundsOutliveStyledSpans(t *testing.T) {
	span := DefaultStyles.Muted.Render("a")
	marked := DefaultStyles.Selected.Render("\x00")
	open := marked[:strings.IndexByte(marked, 0)]
	if line := selectedLine(span+" b", 0); !strings.Contains(line, open+" b") {
		t.Errorf("selection surface ends at the first span: %q", line)
	}
	if kept := keepBackground(span); strings.Contains(kept, "\x1b[m") || strings.Contains(kept, "\x1b[0m") {
		t.Errorf("a span still resets the row tint: %q", kept)
	}
}
