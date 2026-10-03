package daemon

import (
	"albedo/cli/internal/testwire"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

const generationA = testwire.GenerationA
const generationB = testwire.GenerationB

var canonicalSession = testwire.Session
var canonicalInput = testwire.Input
var canonicalEvent = testwire.Event
var canonicalText = testwire.Text
var writeBatch = testwire.WriteBatch
var writeInitialStream = testwire.InitialStream
var canonicalProgress = testwire.Progress

func controlledConnection(t *testing.T, handler http.HandlerFunc) *Connection {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/server" {
			_, _ = w.Write([]byte(testwire.Server))
			return
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	conn, err := Attach(t.Context(), ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token", Version: ProtocolVersion}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(conn.HTTPClient().CloseIdleConnections)
	return conn
}
