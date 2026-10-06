//go:build unix

package e2e

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	"github.com/klauspost/compress/zstd"
)

// uploadRecorder keeps the Content-Encoding of each input upload.
type uploadRecorder struct {
	upstream  http.RoundTripper
	mu        sync.Mutex
	encodings []string
}

func (recorder *uploadRecorder) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Method == http.MethodPut && strings.Contains(req.URL.Path, "/inputs/") {
		recorder.mu.Lock()
		recorder.encodings = append(recorder.encodings, req.Header.Get("Content-Encoding"))
		recorder.mu.Unlock()
	}
	return recorder.upstream.RoundTrip(req)
}

// rawGet reads a daemon resource without the CLI's transport, so the test
// sees the coding the daemon chose.
func rawGet(t *testing.T, path string, headers map[string]string) *http.Response {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, conn(t).BaseURL()+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+conn(t).Snapshot().Token)
	for name, value := range headers {
		req.Header.Set(name, value)
	}
	res, err := (&http.Client{Transport: &http.Transport{DisableCompression: true}}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = res.Body.Close() })
	return res
}

func decoded(t *testing.T, res *http.Response) []byte {
	t.Helper()
	var body io.Reader = res.Body
	if res.Header.Get("Content-Encoding") == "zstd" {
		decoder, err := zstd.NewReader(res.Body)
		if err != nil {
			t.Fatal(err)
		}
		defer decoder.Close()
		body = decoder
	}
	data, err := io.ReadAll(body)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// A large upload crosses zstd-coded once the daemon advertises it, the reply
// and its history come back coded and identical to identity, the session
// stream decodes frame by frame, and the attached image is served as itself.
func TestZstdCodingAndRawImages(t *testing.T) {
	profile := providerRoute(t, echoReply)
	t.Parallel()
	attached, err := daemon.Attach(t.Context(), conn(t).Snapshot(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(attached.HTTPClient().CloseIdleConnections)
	recorder := &uploadRecorder{upstream: attached.HTTPClient().Transport}
	attached.HTTPClient().Transport = recorder

	id := newSession(t, t.TempDir())
	png := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
	prompt := strings.Repeat("a long prompt that compresses well. ", 600)
	image := daemon.ImageAttachment{Data: png, ImageMetadata: daemon.ImageMetadata{MimeType: daemon.ImagePNG, Width: 1, Height: 1, Bytes: 69}}
	if _, err := daemon.NewChatClient(attached, id).Send(context.Background(), prompt, []daemon.ImageAttachment{image}); err != nil {
		t.Fatalf("compressed upload: %v", err)
	}
	waitIdle(t, id, profile, 1)
	if recorder.encodings[0] != "zstd" {
		t.Fatalf("a %d byte upload went out as %q", len(prompt), recorder.encodings[0])
	}
	if forwarded := lastUserText(suite.provider.requests(profile)[0]["body"].(map[string]any)); !strings.Contains(forwarded, prompt) {
		t.Fatal("the decoded upload lost the prompt")
	}

	path := "/sessions/" + id + "/history?limit=200"
	coded := rawGet(t, path, map[string]string{"Accept-Encoding": "gzip, zstd"})
	plain := rawGet(t, path, nil)
	if coded.Header.Get("Content-Encoding") != "zstd" || !strings.Contains(coded.Header.Get("Vary"), "Accept-Encoding") || plain.Header.Get("Content-Encoding") != "" {
		t.Fatalf("history coding: %q vary %q, identity %q", coded.Header.Get("Content-Encoding"), coded.Header.Get("Vary"), plain.Header.Get("Content-Encoding"))
	}
	history := decoded(t, coded)
	if !bytes.Equal(history, decoded(t, plain)) {
		t.Fatal("the zstd history differs from identity")
	}
	refused := rawGet(t, path, map[string]string{"Accept-Encoding": "zstd;q=0"})
	if refused.Header.Get("Content-Encoding") != "" {
		t.Fatal("zstd;q=0 still got zstd")
	}

	var page struct {
		Items []struct {
			Content []struct {
				Image *struct {
					Reference struct{ URL string } `json:"reference"`
				} `json:"image"`
			} `json:"content"`
		} `json:"items"`
	}
	if err := json.Unmarshal(history, &page); err != nil {
		t.Fatal(err)
	}
	var url string
	for _, item := range page.Items {
		for _, part := range item.Content {
			if part.Image != nil {
				url = part.Image.Reference.URL
			}
		}
	}
	served := rawGet(t, url, map[string]string{"Accept-Encoding": "zstd"})
	want, _ := base64.StdEncoding.DecodeString(png)
	if got, _ := io.ReadAll(served.Body); served.StatusCode != http.StatusOK || served.Header.Get("Content-Type") != "image/png" || served.Header.Get("Content-Encoding") != "" || !bytes.Equal(got, want) {
		t.Fatalf("image %s: %d %q %q, %d bytes", url, served.StatusCode, served.Header.Get("Content-Type"), served.Header.Get("Content-Encoding"), len(got))
	}

	stream := rawGet(t, "/sessions/"+id, map[string]string{"Accept": "text/event-stream", "Accept-Encoding": "zstd"})
	if stream.Header.Get("Content-Encoding") != "zstd" {
		t.Fatal("the session stream was not zstd-coded")
	}
	frames, err := zstd.NewReader(stream.Body, zstd.WithDecoderConcurrency(1))
	if err != nil {
		t.Fatal(err)
	}
	defer frames.Close()
	first := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReaderSize(frames, 1<<20).ReadString('\n')
		first <- line
	}()
	select {
	case line := <-first:
		if !strings.HasPrefix(line, "data: {") {
			t.Fatalf("first stream frame: %q", line)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the coded stream withheld its first frame")
	}
}

// A coded body must be one frame that declares a size within the route's
// limit; anything else is refused before the operation runs.
func TestZstdRequestBodiesAreBounded(t *testing.T) {
	t.Parallel()
	unsized, _ := zstd.NewWriter(nil)
	var streamed bytes.Buffer
	unsized.Reset(&streamed)
	_, _ = unsized.Write([]byte(`{"name":"x"}`))
	_ = unsized.Close()
	bomb, _ := zstd.NewWriter(nil)
	for name, body := range map[string][]byte{
		"garbage":   []byte("not zstd"),
		"unsized":   streamed.Bytes(),
		"oversized": bomb.EncodeAll(bytes.Repeat([]byte{' '}, 1<<20), nil),
	} {
		req, _ := http.NewRequestWithContext(t.Context(), http.MethodPost, conn(t).BaseURL()+"/hosts/coded/probe", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+conn(t).Snapshot().Token)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Content-Encoding", "zstd")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		problem, _ := io.ReadAll(res.Body)
		_ = res.Body.Close()
		if res.StatusCode != http.StatusBadRequest || !strings.Contains(string(problem), "does not decode") {
			t.Errorf("%s body: %d %s", name, res.StatusCode, problem)
		}
	}
}
