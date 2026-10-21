package daemon

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
)

// A fresh decoder allocates the frame header's tables and window for every
// response; the pooled one reuses them, which is what this measures.
func BenchmarkZstdResponse(b *testing.B) {
	payload := []byte(`{"items":[` + strings.Repeat(`{"id":"0123456789abcdef","kind":"assistant","text":"`+strings.Repeat("durable history content ", 200)+`"},`, 16) + `{}]}`)
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest), zstd.WithEncoderConcurrency(1))
	if err != nil {
		b.Fatal(err)
	}
	encoded := encoder.EncodeAll(payload, nil)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Encoding", "zstd")
		_, _ = w.Write(encoded)
	}))
	defer server.Close()
	client := &http.Client{Transport: codingTransport{base: http.DefaultTransport}}
	b.SetBytes(int64(len(payload)))
	b.ReportAllocs()
	for b.Loop() {
		response, err := client.Get(server.URL)
		if err != nil {
			b.Fatal(err)
		}
		n, err := io.Copy(io.Discard, response.Body)
		_ = response.Body.Close()
		if err != nil || n != int64(len(payload)) {
			b.Fatalf("decoded %d of %d bytes: %v", n, len(payload), err)
		}
	}
}
