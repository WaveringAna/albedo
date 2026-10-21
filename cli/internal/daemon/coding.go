package daemon

import (
	"io"
	"net/http"
	"strings"
	"sync"

	"github.com/klauspost/compress/zstd"
)

// Request bodies at least this large are compressed when the daemon
// advertises zstd_requests; smaller ones are not worth a frame.
const compressedRequestBytes = 16 * 1024

// The daemon compresses with a small window; anything larger is refused.
const zstdWindowBytes = 8 << 20

// EncodeAll is safe for concurrent use; one encoder amortises its tables
// across every request body.
var zstdEncoder, _ = zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest), zstd.WithEncoderConcurrency(1))

// Decoders are the expensive half: a fresh one allocates its frame state per
// response. Each body borrows one for its exclusive use and hands it back
// when it closes.
var zstdDecoders = sync.Pool{New: func() any {
	decoder, _ := zstd.NewReader(nil, zstd.WithDecoderConcurrency(1), zstd.WithDecoderMaxWindow(zstdWindowBytes))
	return decoder
}}

// requestBody returns the payload to send and its Content-Encoding, empty
// for identity.
func requestBody(conn *Connection, payload []byte) ([]byte, string) {
	if len(payload) < compressedRequestBytes || conn.capability("zstd_requests") < 1 {
		return payload, ""
	}
	return zstdEncoder.EncodeAll(payload, nil), "zstd"
}

// codingTransport asks for zstd responses and decodes them, the way
// net/http does for gzip when no Accept-Encoding is set.
type codingTransport struct{ base http.RoundTripper }

func (transport codingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Header.Get("Accept-Encoding") == "" {
		req = req.Clone(req.Context())
		req.Header.Set("Accept-Encoding", "zstd")
	}
	res, err := transport.base.RoundTrip(req)
	if err != nil || !strings.EqualFold(res.Header.Get("Content-Encoding"), "zstd") {
		return res, err
	}
	decoder := zstdDecoders.Get().(*zstd.Decoder)
	// A frame that is not zstd fails on the first Read, as it does for any
	// streamed decoder; only a closed decoder fails here.
	if err := decoder.Reset(res.Body); err != nil {
		decoder.Close()
		_ = res.Body.Close()
		return nil, err
	}
	res.Body = &zstdBody{decoder: decoder, body: res.Body}
	res.Header.Del("Content-Encoding")
	res.Header.Del("Content-Length")
	res.ContentLength = -1
	res.Uncompressed = true
	return res, nil
}

func (transport codingTransport) CloseIdleConnections() {
	if closer, ok := transport.base.(interface{ CloseIdleConnections() }); ok {
		closer.CloseIdleConnections()
	}
}

type zstdBody struct {
	decoder  *zstd.Decoder
	body     io.ReadCloser
	released bool
}

func (body *zstdBody) Read(target []byte) (int, error) {
	if body.released {
		return 0, io.ErrClosedPipe
	}
	return body.decoder.Read(target)
}

func (body *zstdBody) Close() error {
	if body.released {
		return nil
	}
	body.released = true
	err := body.body.Close()
	// Detach the closed body before the decoder is reused for another stream.
	_ = body.decoder.Reset(nil)
	zstdDecoders.Put(body.decoder)
	return err
}
