// The client must reject untrusted image metadata exceeding bounds before rendering; E2E validates the server side, not this client parser.
package daemon

import (
	"testing"
)

func TestParseImageMetadata(t *testing.T) {
	valid := map[string]any{
		"mimeType": "image/png",
		"width":    800,
		"height":   600,
		"bytes":    120000,
	}
	meta := ParseImageMetadata(valid)
	if meta == nil {
		t.Fatal("expected valid image metadata")
	}
	if meta.MimeType != ImagePNG || meta.Width != 800 || meta.Height != 600 || meta.Bytes != 120000 {
		t.Fatalf("unexpected metadata values: %+v", meta)
	}

	// Bad mimeType
	badMime := map[string]any{
		"mimeType": "image/gif",
		"width":    800,
		"height":   600,
		"bytes":    120000,
	}
	if ParseImageMetadata(badMime) != nil {
		t.Fatal("expected nil for image/gif")
	}

	// Too large dimensions
	hugeDim := map[string]any{
		"mimeType": "image/jpeg",
		"width":    10000,
		"height":   10000,
		"bytes":    120000,
	}
	if ParseImageMetadata(hugeDim) != nil {
		t.Fatal("expected nil for dimension product > 40M")
	}

	// Too many bytes
	hugeBytes := map[string]any{
		"mimeType": "image/webp",
		"width":    100,
		"height":   100,
		"bytes":    10 * 1024 * 1024,
	}
	if ParseImageMetadata(hugeBytes) != nil {
		t.Fatal("expected nil for bytes > 5MB")
	}
}
