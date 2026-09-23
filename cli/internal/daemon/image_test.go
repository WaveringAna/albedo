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

func TestImageLabel(t *testing.T) {
	cases := []struct {
		meta     ImageMetadata
		expected string
	}{
		{ImageMetadata{MimeType: ImagePNG, Width: 800, Height: 600, Bytes: 500}, "PNG 800×600 · 500 B"},
		{ImageMetadata{MimeType: ImageJPEG, Width: 1920, Height: 1080, Bytes: 150000}, "JPEG 1920×1080 · 147 KB"},
		{ImageMetadata{MimeType: ImageWEBP, Width: 2048, Height: 1536, Bytes: 2500000}, "WEBP 2048×1536 · 2.4 MB"},
	}

	for _, tc := range cases {
		if res := ImageLabel(tc.meta); res != tc.expected {
			t.Errorf("expected %s, got %s", tc.expected, res)
		}
	}
}
