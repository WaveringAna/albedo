// A streamed, unfinished JSON tool argument still needs to expose code for live progress; E2E timing cannot reliably stop mid-argument.
package daemon

import (
	"encoding/json"
	"strings"
	"testing"
)

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

func TestToolProgressReporterPreview(t *testing.T) {
	tests := []struct {
		want      *ToolCodePreview
		name      string
		arguments string
	}{
		{name: "empty", arguments: `{"code":""}`},
		{name: "short", arguments: `{"code":"print('hello')"}`, want: &ToolCodePreview{Text: "print('hello')"}},
		{name: "512 runes", arguments: `{"code":"` + strings.Repeat("a", 512) + `"}`, want: &ToolCodePreview{Text: strings.Repeat("a", 512)}},
		{name: "513 runes", arguments: `{"code":"x` + strings.Repeat("a", 512) + `"}`, want: &ToolCodePreview{Offset: 1, Text: strings.Repeat("a", 512)}},
		{name: "multibyte", arguments: `{"code":"é界🙂"}`, want: &ToolCodePreview{Text: "é界🙂"}},
		{name: "long unicode", arguments: `{"code":"` + strings.Repeat("é", 600) + strings.Repeat("界🙂", 256) + `"}`, want: &ToolCodePreview{Offset: 600, Text: strings.Repeat("界🙂", 256)}},
		{name: "control and formatting", arguments: `{"code":"a\n\t\r\b\f\u0000\u007f\u0085\u200b\u202eb"}`, want: &ToolCodePreview{Text: "a" + strings.Repeat(" ", 10) + "b"}},
		{name: "sanitized tail offset", arguments: `{"code":"\n` + strings.Repeat("a", 511) + `\u200b"}`, want: &ToolCodePreview{Offset: 1, Text: strings.Repeat("a", 511) + " "}},
		{name: "malformed utf8", arguments: "{\"code\":\"a\xff\xc0\xafz\"}", want: &ToolCodePreview{Text: "a���z"}},
		{name: "malformed utf8 tail", arguments: "{\"code\":\"\xff" + strings.Repeat("界", 512) + "\"}", want: &ToolCodePreview{Offset: 1, Text: strings.Repeat("界", 512)}},
		{name: "escaped json", arguments: `{"code":"print(\"é\")\\path\/\u754c\ud83d\ude42"}`, want: &ToolCodePreview{Text: "print(\"é\")\\path/界🙂"}},
		{name: "unfinished string", arguments: `{"code":"read('second.`, want: &ToolCodePreview{Text: "read('second."}},
		{name: "unfinished escape", arguments: `{"code":"hello\`, want: &ToolCodePreview{Text: "hello"}},
		{name: "unfinished unicode escape", arguments: `{"code":"hello\u75`, want: &ToolCodePreview{Text: "hello"}},
		{name: "unfinished utf8", arguments: "{\"code\":\"hello\xe7\x95", want: &ToolCodePreview{Text: "hello"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var published *ToolProgress
			reporter := NewToolProgressReporter(func(progress *ToolProgress) error {
				published = progress
				return nil
			})
			call := &ToolCallAssembly{ID: "preview"}
			call.Function.Name = "python"
			call.Function.Arguments = test.arguments
			if err := reporter.Report(call, "generating"); err != nil {
				t.Fatal(err)
			}
			if published == nil {
				t.Fatal("no progress published")
			}
			if test.want == nil {
				if published.Code != nil {
					t.Fatalf("expected no preview, got %+v", published.Code)
				}
				return
			}
			if published.Code == nil || *published.Code != *test.want {
				t.Fatalf("preview = %+v, want %+v", published.Code, test.want)
			}
		})
	}
}

var benchmarkPreviewBytes int

func BenchmarkToolProgressGrowingPythonArguments(b *testing.B) {
	for _, payload := range []struct {
		name string
		size int
	}{
		{name: "16KiB", size: 16 * 1024},
		{name: "128KiB", size: 128 * 1024},
	} {
		b.Run(payload.name, func(b *testing.B) {
			arguments, err := json.Marshal(map[string]string{"code": "#" + strings.Repeat("a", payload.size-1)})
			if err != nil {
				b.Fatal(err)
			}
			encoded := string(arguments)
			var prefixes []string
			for end := 1024; end < len(encoded); end += 1024 {
				prefixes = append(prefixes, encoded[:end])
			}
			prefixes = append(prefixes, encoded)
			publish := func(progress *ToolProgress) error {
				if progress.Code != nil {
					benchmarkPreviewBytes += len(progress.Code.Text)
				}
				return nil
			}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				reporter := NewToolProgressReporter(publish)
				call := &ToolCallAssembly{ID: "benchmark"}
				call.Function.Name = "python"
				for _, prefix := range prefixes {
					call.Function.Arguments = prefix
					if err := reporter.Report(call, "generating"); err != nil {
						b.Fatal(err)
					}
				}
			}
		})
	}
}
