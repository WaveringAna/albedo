package daemon

import (
	"testing"
)

func TestParsePythonIntent(t *testing.T) {
	cases := []struct {
		code     string
		expected *ToolIntent
	}{
		{
			code:     "from pathlib import Path\nPath('demo.py').write_text('hello')",
			expected: &ToolIntent{Kind: "write", Target: "demo.py"},
		},
		{
			code:     "read('second.py')",
			expected: &ToolIntent{Kind: "read", Target: "second.py"},
		},
		{
			code:     "edit('main.go')",
			expected: &ToolIntent{Kind: "edit", Target: "main.go"},
		},
		{
			code:     "job = run('go', 'test', './...', cwd='cli')",
			expected: &ToolIntent{Kind: "run", Target: "go test ./..."},
		},
		{
			code:     "await rem.run(\"ls\", \"-la\")",
			expected: &ToolIntent{Kind: "run", Target: "ls -la"},
		},
		{
			code:     "open('test.txt', 'r')",
			expected: &ToolIntent{Kind: "read", Target: "test.txt"},
		},
		{
			code:     "open('test.txt', 'w')",
			expected: &ToolIntent{Kind: "write", Target: "test.txt"},
		},
		{
			code:     "p = Path('data.csv')\np.write_text('a,b,c')",
			expected: &ToolIntent{Kind: "write", Target: "data.csv"},
		},
	}

	if intent := ParsePythonIntent("await cells.run('abc', replacements=[])"); intent != nil {
		t.Fatalf("cells.run is not a program run: %+v", intent)
	}
	for _, tc := range cases {
		intent := ParsePythonIntent(tc.code)
		if intent == nil {
			t.Fatalf("expected intent for %s, got nil", tc.code)
		}
		if intent.Kind != tc.expected.Kind || intent.Target != tc.expected.Target {
			t.Fatalf("for %s: expected %+v, got %+v", tc.code, tc.expected, intent)
		}
	}
}

func TestExtractPartialJSONCode(t *testing.T) {
	code1 := ExtractPartialJSONCode(`{"code":"read('second.`)
	if code1 != "read('second." {
		t.Fatalf("expected read('second., got %s", code1)
	}

	code2 := ExtractPartialJSONCode(`{"code":"from pathlib import Path\nPath('demo.py').write_text('hello')"}`)
	expected2 := "from pathlib import Path\nPath('demo.py').write_text('hello')"
	if code2 != expected2 {
		t.Fatalf("expected %s, got %s", expected2, code2)
	}
}
