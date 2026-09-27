// A streamed, unfinished JSON tool argument still needs to expose code for live progress; E2E timing cannot reliably stop mid-argument.
package daemon

import (
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
