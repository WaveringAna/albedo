package daemon

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
)

// The window a frame declares is what the client's decoder holds for as long
// as the body is open, and a session stream keeps one open for the client's
// life. The daemon compresses with a 64 KiB window; a daemon that predates it
// declares level 1's 512 KiB one, and both must decode.
func TestCodedResponseWindows(t *testing.T) {
	payload := []byte(strings.Repeat("the client keeps one decoder for its session stream. ", 22000))
	for _, window := range []int{64 << 10, 512 << 10} {
		encoder, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest), zstd.WithEncoderConcurrency(1), zstd.WithWindowSize(window))
		if err != nil {
			t.Fatal(err)
		}
		encoded := encoder.EncodeAll(payload, nil)
		_ = encoder.Close()
		var header zstd.Header
		if err := header.Decode(encoded); err != nil {
			t.Fatal(err)
		}
		if header.WindowSize != uint64(window) {
			t.Fatalf("frame declares window %d, want %d", header.WindowSize, window)
		}
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Encoding", "zstd")
			_, _ = w.Write(encoded)
		}))
		client := &http.Client{Transport: codingTransport{base: http.DefaultTransport}}
		response, err := client.Get(server.URL)
		if err != nil {
			t.Fatal(err)
		}
		got, err := io.ReadAll(response.Body)
		_ = response.Body.Close()
		server.Close()
		if err != nil || !bytes.Equal(got, payload) {
			t.Fatalf("window %d: decoded %d of %d bytes: %v", window, len(got), len(payload), err)
		}
	}
}

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
