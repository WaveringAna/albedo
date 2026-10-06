package daemon

import (
	"io"
	"net/http"
	"strings"

	"github.com/klauspost/compress/zstd"
)

// Request bodies at least this large are compressed when the daemon
// advertises zstd_requests; smaller ones are not worth a frame.
const compressedRequestBytes = 16 * 1024

// The daemon compresses with a small window; anything larger is refused.
const zstdWindowBytes = 8 << 20

var zstdEncoder, _ = zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest), zstd.WithEncoderConcurrency(1))

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
	decoder, err := zstd.NewReader(res.Body, zstd.WithDecoderConcurrency(1), zstd.WithDecoderMaxWindow(zstdWindowBytes))
	if err != nil {
		_ = res.Body.Close()
		return nil, err
	}
	res.Body = zstdBody{decoder: decoder, body: res.Body}
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
	decoder *zstd.Decoder
	body    io.ReadCloser
}

func (body zstdBody) Read(target []byte) (int, error) { return body.decoder.Read(target) }

func (body zstdBody) Close() error {
	body.decoder.Close()
	return body.body.Close()
}
