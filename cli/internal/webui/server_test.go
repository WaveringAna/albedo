package webui

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	"albedo/cli/internal/daemon"
)

// These cover the boundary that keeps the daemon token out of the browser;
// the e2e suites drive the daemon through the CLI and never load this page.

type fakeUpstream struct {
	snapshot  daemon.ConnectionSnapshot
	refreshes atomic.Int32
}

func (f *fakeUpstream) Snapshot() daemon.ConnectionSnapshot { return f.snapshot }
func (f *fakeUpstream) Refresh(context.Context) error {
	f.refreshes.Add(1)
	return nil
}

func newServer(t *testing.T, daemonHandler http.HandlerFunc) (*Server, *fakeUpstream) {
	t.Helper()
	dist := t.TempDir()
	if err := os.WriteFile(filepath.Join(dist, "index.html"), []byte("<!doctype html>"), 0o600); err != nil {
		t.Fatal(err)
	}
	upstream := &fakeUpstream{snapshot: daemon.ConnectionSnapshot{Token: "secret"}}
	if daemonHandler != nil {
		backend := httptest.NewServer(daemonHandler)
		t.Cleanup(backend.Close)
		upstream.snapshot.Port = backend.Listener.Addr().(*net.TCPAddr).Port
	}
	server, err := New(dist, upstream)
	if err != nil {
		t.Fatal(err)
	}
	return server, upstream
}

func request(method, target string, cookie string) *http.Request {
	r := httptest.NewRequest(method, "http://127.0.0.1:4317"+target, nil)
	if cookie != "" {
		r.AddCookie(&http.Cookie{Name: cookieName, Value: cookie})
	}
	return r
}

func TestLaunchKeyBecomesCookieAndUnlocksTheAPI(t *testing.T) {
	var forwarded *http.Request
	server, _ := newServer(t, func(w http.ResponseWriter, r *http.Request) {
		forwarded = r.Clone(context.Background())
		w.WriteHeader(http.StatusOK)
	})

	signIn := httptest.NewRecorder()
	server.ServeHTTP(signIn, request(http.MethodGet, "/?key="+server.key, ""))
	if signIn.Code != http.StatusSeeOther || signIn.Header().Get("Location") != "/" {
		t.Fatalf("sign-in answered %d to %q", signIn.Code, signIn.Header().Get("Location"))
	}
	cookies := signIn.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Value != server.key || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatalf("sign-in set %+v", cookies)
	}

	call := request(http.MethodGet, "/api/sessions?scope=roots", server.key)
	call.Header.Set("Origin", "http://127.0.0.1:4317")
	response := httptest.NewRecorder()
	server.ServeHTTP(response, call)
	if response.Code != http.StatusOK || forwarded == nil {
		t.Fatalf("api answered %d, forwarded %v", response.Code, forwarded != nil)
	}
	if forwarded.URL.Path != "/sessions" || forwarded.URL.RawQuery != "scope=roots" {
		t.Errorf("forwarded %s?%s", forwarded.URL.Path, forwarded.URL.RawQuery)
	}
	if forwarded.Header.Get("Authorization") != "Bearer secret" {
		t.Errorf("forwarded authorization %q", forwarded.Header.Get("Authorization"))
	}
	if forwarded.Header.Get("Origin") != "" || forwarded.Header.Get("Cookie") != "" {
		t.Errorf("forwarded browser headers: origin %q cookie %q", forwarded.Header.Get("Origin"), forwarded.Header.Get("Cookie"))
	}
}

func TestRefusesWithoutReachingTheDaemon(t *testing.T) {
	var reached atomic.Bool
	server, _ := newServer(t, func(http.ResponseWriter, *http.Request) { reached.Store(true) })

	crossOrigin := request(http.MethodPost, "/api/sessions", server.key)
	crossOrigin.Header.Set("Origin", "http://127.0.0.1:9999")
	rebound := request(http.MethodGet, "/api/sessions", server.key)
	rebound.Host = "evil.example:4317"

	for name, test := range map[string]struct {
		request *http.Request
		status  int
	}{
		"no cookie":    {request(http.MethodGet, "/api/sessions", ""), http.StatusUnauthorized},
		"wrong cookie": {request(http.MethodGet, "/api/sessions", "guess"), http.StatusUnauthorized},
		"wrong key":    {request(http.MethodGet, "/?key=guess", ""), http.StatusForbidden},
		"cross origin": {crossOrigin, http.StatusForbidden},
		"foreign host": {rebound, http.StatusMisdirectedRequest},
	} {
		response := httptest.NewRecorder()
		server.ServeHTTP(response, test.request)
		if response.Code != test.status {
			t.Errorf("%s: status %d, want %d", name, response.Code, test.status)
		}
		if len(response.Result().Cookies()) != 0 {
			t.Errorf("%s: set a cookie", name)
		}
	}
	if reached.Load() {
		t.Fatal("a refused request reached the daemon")
	}
}

func TestNetworksReadAsCIDROrTrailingZeros(t *testing.T) {
	for text, want := range map[string]string{
		"10.0.0.0":       "10.0.0.0/8",
		"100.64.0.0":     "100.64.0.0/16",
		"192.168.1.0":    "192.168.1.0/24",
		"10.0.0.174":     "10.0.0.174/32",
		"100.64.0.0/10":  "100.64.0.0/10",
		"192.168.1.7/24": "192.168.1.0/24",
	} {
		network, err := ParseNetwork(text)
		if err != nil || network.String() != want {
			t.Errorf("%s read as %v (%v), want %s", text, network, err, want)
		}
	}
	for _, text := range []string{"", "lan", "fe80::1", "10.0.0"} {
		if _, err := ParseNetwork(text); err == nil {
			t.Errorf("%q was accepted", text)
		}
	}
}

func TestSharedNetworksStillNeedTheKey(t *testing.T) {
	server, _ := newServer(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	home, _ := ParseNetwork("10.0.0.0")
	if shared := server.Share([]*net.IPNet{home}, []string{"10.0.0.5", "100.64.0.5"}); len(shared) != 1 || shared[0] != "10.0.0.5" {
		t.Fatalf("shared %v", shared)
	}
	lan := func(target, cookie, from string) *http.Request {
		r := request(http.MethodGet, target, cookie)
		r.Host = "10.0.0.5:4317"
		r.RemoteAddr = from + ":50000"
		return r
	}
	outside := lan("/api/sessions", server.key, "10.0.0.9")
	outside.Host = "100.64.0.5:4317"

	for name, test := range map[string]struct {
		request *http.Request
		status  int
	}{
		"signed out":        {lan("/api/sessions", "", "10.0.0.9"), http.StatusUnauthorized},
		"sign in":           {lan("/?key="+server.key, "", "10.0.0.9"), http.StatusSeeOther},
		"signed in":         {lan("/api/sessions", server.key, "10.0.0.9"), http.StatusOK},
		"this machine":      {lan("/api/sessions", server.key, "127.0.0.1"), http.StatusOK},
		"other network":     {lan("/api/sessions", server.key, "192.168.1.4"), http.StatusForbidden},
		"address not given": {outside, http.StatusMisdirectedRequest},
	} {
		response := httptest.NewRecorder()
		server.ServeHTTP(response, test.request)
		if response.Code != test.status {
			t.Errorf("%s: status %d, want %d", name, response.Code, test.status)
		}
	}
}

func TestUnreachableDaemonIsRediscovered(t *testing.T) {
	server, upstream := newServer(t, nil)
	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	upstream.snapshot.Port = closed.Addr().(*net.TCPAddr).Port
	closed.Close()

	response := httptest.NewRecorder()
	server.ServeHTTP(response, request(http.MethodGet, "/api/sessions", server.key))
	if response.Code != http.StatusBadGateway || upstream.refreshes.Load() != 1 {
		t.Fatalf("status %d after %d refreshes", response.Code, upstream.refreshes.Load())
	}
}

func TestStaticAssetsAreCachedButTheShellIsNot(t *testing.T) {
	server, _ := newServer(t, nil)
	if err := os.MkdirAll(filepath.Join(server.dist, "assets"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(server.dist, "assets", "index-abc.js"), []byte("1"), 0o600); err != nil {
		t.Fatal(err)
	}
	for path, cache := range map[string]string{"/": "no-cache", "/assets/index-abc.js": "public, max-age=31536000, immutable"} {
		response := httptest.NewRecorder()
		server.ServeHTTP(response, request(http.MethodGet, path, ""))
		if response.Code != http.StatusOK || response.Header().Get("Cache-Control") != cache {
			t.Errorf("%s: %d with cache %q", path, response.Code, response.Header().Get("Cache-Control"))
		}
	}
}

func TestMissingBuildNamesTheFix(t *testing.T) {
	if _, err := New(t.TempDir(), &fakeUpstream{}); err == nil {
		t.Fatal("an empty dist was accepted")
	}
}

func TestArtifactFrameBoundary(t *testing.T) {
	var got *http.Request
	server, _ := newServer(t, func(w http.ResponseWriter, r *http.Request) {
		got = r.Clone(context.Background())
		w.Header().Set("Content-Type", "text/html")
		// A copy from the daemon must not stand beside the frame's own.
		w.Header().Set("Access-Control-Allow-Origin", "https://elsewhere")
		_, _ = w.Write([]byte("<h1>ok</h1>"))
	})
	req := request(http.MethodGet, "/frame/id.key/1/index.html", "")
	req.Header.Set("Cookie", "albedo_web=bad")
	req.Header.Set("Origin", "https://elsewhere")
	req.Header.Set("Referer", "https://elsewhere/")
	response := httptest.NewRecorder()
	server.ServeHTTP(response, req)
	if response.Code != http.StatusOK || got == nil || got.URL.Path != "/extensions/artifacts/frame/id.key/1/index.html" {
		t.Fatalf("frame answered %d, request %+v", response.Code, got)
	}
	if got.Header.Get("Authorization") != "Bearer secret" || got.Header.Get("Cookie") != "" || got.Header.Get("Origin") != "" || got.Header.Get("Referer") != "" {
		t.Fatalf("browser headers crossed boundary: %+v", got.Header)
	}
	for key, want := range frameHeaders {
		if values := response.Header().Values(key); len(values) != 1 || values[0] != want {
			t.Errorf("%s = %q", key, values)
		}
	}
	for _, method := range []string{http.MethodPut, http.MethodDelete} {
		response = httptest.NewRecorder()
		server.ServeHTTP(response, request(method, "/frame/id.key/1/index.html", ""))
		if response.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s answered %d", method, response.Code)
		}
	}
	response = httptest.NewRecorder()
	server.ServeHTTP(response, request(http.MethodPost, "/frame/id.key/1/index.html", ""))
	if response.Code != http.StatusMethodNotAllowed {
		t.Errorf("post file answered %d", response.Code)
	}
}
