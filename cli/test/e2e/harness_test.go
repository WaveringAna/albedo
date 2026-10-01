//go:build unix

// Package e2e drives a real daemon through the CLI and TUI with a scripted
// model provider. Scenarios isolate provider routes and workspaces; most run
// in parallel. The suite uses Unix signals for daemon teardown and PID checks.
package e2e

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
)

// suite is the process-wide fixture: one daemon, one provider server, one
// hermetic home. A restart scenario must update daemonPID.
var suite struct {
	conn      *daemon.Connection
	provider  *fakeProvider
	root      string // the albedo repository
	cli       string // the freshly built CLI binary
	home      string // hermetic ALBEDO_HOME
	env       []string
	daemonPID int
}

func TestMain(m *testing.M) {
	started := time.Now()
	shutdown, err := bootSuite()
	if err != nil {
		fmt.Fprintln(os.Stderr, "go e2e setup failed:", err)
		if shutdown != nil {
			// The daemon may already be running; take it down either way.
			report, ok := shutdown()
			fmt.Fprintf(os.Stderr, "go e2e teardown after failed setup: %s\n", report)
			if !ok {
				fmt.Fprintln(os.Stderr, "go e2e teardown failed; a daemon may be leaked")
			}
		}
		os.Exit(1)
	}
	code := m.Run()
	report, ok := shutdown()
	fmt.Printf("go e2e suite: %s, %s\n", time.Since(started).Round(time.Millisecond), report)
	if !ok {
		code = 1
	}
	os.Exit(code)
}

func bootSuite() (func() (string, bool), error) {
	root, err := repoRoot()
	if err != nil {
		return nil, err
	}
	temp, err := os.MkdirTemp("", "albedo-go-e2e-")
	if err != nil {
		return nil, err
	}
	teardown := func() (string, bool) { return teardownSuite(temp) }

	home := filepath.Join(temp, "home")
	userHome := filepath.Join(temp, "user-home")
	scratch := filepath.Join(temp, "tmp")
	for _, dir := range []string{home, userHome, scratch} {
		if mkdirErr := os.MkdirAll(dir, 0o700); mkdirErr != nil {
			return teardown, mkdirErr
		}
	}

	// Build the exact CLI the scenarios drive, so the suite never depends on
	// (or races with) a stale cli/bin/albedo.
	suite.cli = filepath.Join(temp, "bin", "albedo")
	build := exec.Command("go", "build", "-o", suite.cli, "./cmd/albedo")
	build.Dir = filepath.Join(root, "cli")
	if out, buildErr := build.CombinedOutput(); buildErr != nil {
		return teardown, fmt.Errorf("building ./cmd/albedo: %w\n%s", buildErr, out)
	}

	launcher, err := snapshotDaemon(root, filepath.Join(temp, "daemon"))
	if err != nil {
		return teardown, err
	}

	suite.root, suite.home = root, home
	suite.env = hermeticEnv(root, home, userHome, scratch, launcher)
	suite.provider = newFakeProvider()
	// A models.dev refresh or the cache-TTL table's remote copy would reach
	// the network from a test.
	if writeErr := os.WriteFile(filepath.Join(home, "extensions.json"),
		[]byte(`{"models": {"refreshHours": 0}, "cacheTtl": {"url": null}}`), 0o600); writeErr != nil {
		return teardown, writeErr
	}

	if _, stderr, startupErr := runCLI("sessions"); startupErr != nil {
		return teardown, bootFailure(startupErr, stderr)
	}
	snap, err := awaitDaemon(home)
	if err != nil {
		return teardown, err
	}
	suite.conn = daemon.NewConnection(snap, home)
	suite.daemonPID = snap.Pid
	return teardown, nil
}

// teardownSuite shuts the daemon down, waits for its process to exit, kills it
// if it must, and removes the hermetic tree. A surviving daemon fails the run,
// because it would poison the next one.
func teardownSuite(temp string) (string, bool) {
	var report []string
	ok := true
	switch snap, err := readDaemonSnapshot(suite.home); {
	case err != nil:
		report = append(report, "daemon record unreadable: "+err.Error())
		if suite.daemonPID != 0 {
			ok = false
			if !awaitExit(suite.daemonPID, 500*time.Millisecond) {
				_ = syscall.Kill(suite.daemonPID, syscall.SIGKILL)
			}
		}
	case suite.conn == nil:
		// Setup never reached the daemon; the parent watcher takes it down
		// when this process exits.
		report = append(report, fmt.Sprintf("daemon %d recorded but never connected", snap.Pid))
	default:
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if _, err := daemon.Request[map[string]any](ctx, suite.conn, "/shutdown", map[string]any{}); err != nil {
			report = append(report, fmt.Sprintf("shutdown request failed: %v", err))
		}
		if awaitExit(snap.Pid, 15*time.Second) {
			report = append(report, fmt.Sprintf("daemon %d exited cleanly", snap.Pid))
		} else {
			_ = syscall.Kill(snap.Pid, syscall.SIGKILL)
			ok = false
			report = append(report, fmt.Sprintf("daemon %d ignored shutdown and was killed", snap.Pid))
		}
	}
	if suite.provider != nil {
		suite.provider.close()
	}
	_ = os.RemoveAll(temp)
	return strings.Join(report, "; "), ok
}

// awaitExit polls until the process is gone.
func awaitExit(pid int, within time.Duration) bool {
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return true
		}
		time.Sleep(100 * time.Millisecond)
	}
	return false
}

// bootFailure wraps a setup error with the daemon log, the only record of a
// daemon that died before it could publish daemon.json.
func bootFailure(err error, cliStderr string) error {
	log, _ := os.ReadFile(filepath.Join(suite.home, "daemon.log"))
	return fmt.Errorf("%w\ncli: %s\ndaemon.log: %s", err, cliStderr, log)
}

// awaitDaemon waits for the booting daemon to publish daemon.json.
func awaitDaemon(home string) (daemon.ConnectionSnapshot, error) {
	deadline := time.Now().Add(2 * time.Minute)
	for time.Now().Before(deadline) {
		if snap, err := readDaemonSnapshot(home); err == nil {
			return snap, nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return daemon.ConnectionSnapshot{}, bootFailure(errors.New("daemon did not publish daemon.json"), "")
}

func readDaemonSnapshot(home string) (daemon.ConnectionSnapshot, error) {
	data, err := os.ReadFile(filepath.Join(home, "daemon.json"))
	if err != nil {
		return daemon.ConnectionSnapshot{}, err
	}
	var snap daemon.ConnectionSnapshot
	if err := json.Unmarshal(data, &snap); err != nil {
		return daemon.ConnectionSnapshot{}, err
	}
	if snap.Port < 1 {
		return daemon.ConnectionSnapshot{}, fmt.Errorf("daemon.json has no port: %s", data)
	}
	return snap, nil
}

func repoRoot() (string, error) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		return "", errors.New("cannot locate the e2e source file")
	}
	for dir := filepath.Dir(file); ; dir = filepath.Dir(dir) {
		if _, err := os.Stat(filepath.Join(dir, "gleam.toml")); err == nil {
			return dir, nil
		}
		if parent := filepath.Dir(dir); parent == dir {
			return "", fmt.Errorf("no albedo repository above %s", filepath.Dir(file))
		}
	}
}

// snapshotDaemon returns the launcher the daemon boots from instead of
// `gleam run`: test.sh's snapshot when it passes ALBEDO_TEST_DAEMON, else a
// fresh one in out (see test/snapshot-daemon.sh).
func snapshotDaemon(root, out string) (string, error) {
	if launcher := os.Getenv("ALBEDO_TEST_DAEMON"); launcher != "" {
		return launcher, nil
	}
	launcher, err := exec.Command(filepath.Join(root, "test", "snapshot-daemon.sh"), out).Output()
	if err != nil {
		if exit, ok := errors.AsType[*exec.ExitError](err); ok {
			return "", fmt.Errorf("snapshotting the daemon: %w\n%s", err, exit.Stderr)
		}
		return "", fmt.Errorf("snapshotting the daemon: %w", err)
	}
	return strings.TrimSpace(string(launcher)), nil
}

// hermeticEnv builds the environment for every CLI invocation and the daemon
// it spawns: no real home, no inherited albedo state, temporary files inside
// the suite's tree, the snapshot's launcher, and the parent watcher.
func hermeticEnv(root, home, userHome, scratch, daemonExe string) []string {
	var env []string
	for _, kv := range os.Environ() {
		name, _, _ := strings.Cut(kv, "=")
		if name == "HOME" || name == "TMPDIR" || name == "ERL_FLAGS" || strings.HasPrefix(name, "ALBEDO_") {
			continue
		}
		env = append(env, kv)
	}
	return append(env,
		"HOME="+userHome,
		"TMPDIR="+scratch,
		"ALBEDO_HOME="+home,
		"ALBEDO_PARENT_PID="+strconv.Itoa(os.Getpid()),
		"ALBEDO_ROOT="+root,
		"ALBEDO_DAEMON="+daemonExe,
		"ALBEDO_NO_BROWSER=1",
		// Two schedulers keep a booting test VM from pinning every core.
		"ERL_FLAGS=+S 2:2 +SDcpu 2:2 +sbwt none +sbwtdcpu none +sbwtdio none",
	)
}

// runCLI runs the built binary the way a user would and returns its output.
func runCLI(args ...string) (string, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, suite.cli, args...)
	cmd.Dir = suite.root
	cmd.Env = suite.env
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

// fakeProvider scripts the model network. Each scenario registers its own
// route, so one shared httptest server isolates scenarios instead of a daemon
// per test.
type fakeProvider struct {
	server  *httptest.Server
	byName  map[string]*fakeRoute // by provider profile name
	byRoute map[string]*fakeRoute // by path segment under /t/
	seq     int

	mu sync.Mutex
}

// fakeRoute is one scripted profile: a reply function and every request the
// daemon sent to it.
type fakeRoute struct {
	reply    func(request map[string]any) string
	requests []map[string]any // {authorization, model, body}
	mu       sync.Mutex
}

func newFakeProvider() *fakeProvider {
	p := &fakeProvider{
		byName:  make(map[string]*fakeRoute),
		byRoute: make(map[string]*fakeRoute),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/t/", p.serve)
	p.server = httptest.NewServer(mux)
	return p
}

func (p *fakeProvider) close() { p.server.Close() }

// addProfile registers a scripted route and saves it through the daemon,
// which owns config.json and makes the saved profile active; earlier profiles
// stay configured so their sessions keep working.
func (p *fakeProvider) addProfile(name string, reply func(map[string]any) string) error {
	p.mu.Lock()
	p.seq++
	segment := strconv.Itoa(p.seq)
	route := &fakeRoute{reply: reply}
	p.byName[name] = route
	p.byRoute[segment] = route
	p.mu.Unlock()
	return daemon.SaveProvider(context.Background(), suite.conn, name, config.Settings{
		Extension: "openai",
		BaseURL:   p.server.URL + "/t/" + segment,
		APIKey:    "fixture-key",
		Model:     "fixture-model",
		Protocol:  "chat_completions",
	})
}

// requests returns what the daemon sent to the named profile.
func (p *fakeProvider) requests(name string) []map[string]any {
	p.mu.Lock()
	route := p.byName[name]
	p.mu.Unlock()
	if route == nil {
		return nil
	}
	route.mu.Lock()
	defer route.mu.Unlock()
	return slices.Clone(route.requests)
}

func (p *fakeProvider) routeFor(path string) *fakeRoute {
	segment, _, _ := strings.Cut(strings.TrimPrefix(path, "/t/"), "/")
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.byRoute[segment]
}

func (p *fakeProvider) serve(w http.ResponseWriter, r *http.Request) {
	route := p.routeFor(r.URL.Path)
	if route == nil {
		http.NotFound(w, r)
		return
	}
	switch r.Method {
	case http.MethodGet:
		// The models catalog endpoint; scenarios script none.
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte("{}"))
	case http.MethodPost:
		route.serveChat(w, r)
	default:
		http.NotFound(w, r)
	}
}

// serveChat records the request and streams it a scripted reply in the chat
// completions SSE wire format the daemon parses.
func (r *fakeRoute) serveChat(w http.ResponseWriter, req *http.Request) {
	body, err := io.ReadAll(io.LimitReader(req.Body, 4<<20))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var decoded map[string]any
	_ = json.Unmarshal(body, &decoded) // record even a malformed body

	r.mu.Lock()
	r.requests = append(r.requests, map[string]any{
		"authorization": req.Header.Get("Authorization"),
		"model":         decoded["model"],
		"body":          decoded,
	})
	reply := r.reply
	r.mu.Unlock()

	text := "fixture reply"
	if reply != nil {
		text = reply(decoded)
	}

	w.Header().Set("Content-Type", "text/event-stream")
	flusher, _ := w.(http.Flusher)
	emit := func(delta map[string]any, finish string) {
		choice := map[string]any{"index": 0, "delta": delta, "finish_reason": nil}
		if finish != "" {
			choice["finish_reason"] = finish
		}
		chunk, _ := json.Marshal(map[string]any{"id": "fixture", "choices": []any{choice}})
		fmt.Fprintf(w, "data: %s\n\n", chunk)
		if flusher != nil {
			flusher.Flush()
		}
	}
	for _, chunk := range chunks(text, 20) {
		emit(map[string]any{"content": chunk}, "")
	}
	emit(map[string]any{}, "stop")
	fmt.Fprint(w, "data: [DONE]\n\n")
}

// --- scenario helpers; new scenarios in this package build on these ---

// conn returns the shared daemon connection and fails if the daemon under it
// is no longer the one this suite booted.
func conn(t *testing.T) *daemon.Connection {
	t.Helper()
	snap, err := readDaemonSnapshot(suite.home)
	if err != nil {
		t.Fatalf("daemon record: %v", err)
	}
	if snap.Pid != suite.daemonPID {
		t.Fatalf("daemon %d replaced the suite daemon %d", snap.Pid, suite.daemonPID)
	}
	return suite.conn
}

// cli runs the built binary and fails the test when it exits non-zero.
func cli(t *testing.T, args ...string) string {
	t.Helper()
	stdout, stderr, err := runCLI(args...)
	if err != nil {
		t.Fatalf("albedo %s: %v\nstdout: %s\nstderr: %s", strings.Join(args, " "), err, stdout, stderr)
	}
	return stdout
}

// newSession creates a session on the test's own provider route, so tests
// running side by side never depend on which profile is active.
func newSession(t *testing.T, workspace string) string {
	t.Helper()
	created, err := daemon.Request[daemon.Session](context.Background(), conn(t), "/sessions",
		map[string]string{"workspace": workspace, "provider": t.Name()})
	if err != nil || created.ID == "" {
		t.Fatalf("creating a session on %s: %v", t.Name(), err)
	}
	return created.ID
}

// cliSession creates a session through the CLI, exactly as a user would, on
// whichever profile is active.
func cliSession(t *testing.T, workspace string) string {
	t.Helper()
	var created struct {
		Session string `json:"session"`
	}
	if err := json.Unmarshal([]byte(cli(t, "new", workspace)), &created); err != nil || created.Session == "" {
		t.Fatalf("albedo new did not report a session: %v", err)
	}
	return created.Session
}

// providerRoute registers a scripted provider profile for one scenario and
// selects it, named after the test so failure output points at its owner.
// Selecting is global: a scenario whose turns go to the active profile (on a
// session the CLI or the TUI created), that saves a default, or that restarts
// the daemon runs alone, and every other one calls t.Parallel(). Go runs the
// parallel ones only after all the others have finished.
func providerRoute(t *testing.T, reply func(map[string]any) string) string {
	t.Helper()
	if err := suite.provider.addProfile(t.Name(), reply); err != nil {
		t.Fatalf("provider route: %v", err)
	}
	return t.Name()
}

// waitIdle waits for the turn to reach the provider before accepting idle:
// a newly submitted turn can be queued while its kernel boots.
func waitIdle(t *testing.T, session, profile string, wantRequests int) {
	t.Helper()
	connection := conn(t)
	deadline := time.Now().Add(60 * time.Second)
	for {
		status, err := daemon.Request[struct {
			Running bool `json:"running"`
		}](context.Background(), connection, "/sessions/"+url.PathEscape(session)+"/status", nil)
		if err != nil {
			t.Fatalf("status of %s: %v", session, err)
		}
		seen := len(suite.provider.requests(profile))
		if !status.Running && seen >= wantRequests {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("session %s never settled after %d provider requests (got %d)",
				session, wantRequests, seen)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// streamSnapshot reads the first non-empty page of a session's event stream.
func streamSnapshot(t *testing.T, session string) []map[string]any {
	t.Helper()
	connection := conn(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		connection.BaseURL()+"/sessions/"+url.PathEscape(session)+"/stream", nil)
	if err != nil {
		t.Fatalf("stream request: %v", err)
	}
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Authorization", "Bearer "+connection.Token())
	res, err := connection.HTTPClient().Do(req)
	if err != nil {
		t.Fatalf("stream: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("stream: %s", res.Status)
	}
	scanner := bufio.NewScanner(res.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var page struct {
			Events []map[string]any `json:"events"`
		}
		if json.Unmarshal([]byte(line[len("data: "):]), &page) != nil {
			continue
		}
		if len(page.Events) > 0 {
			return page.Events
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("read stream of %s: %v", session, err)
	}
	t.Fatalf("stream of %s produced no event page", session)
	return nil
}

// eventText collects the text of every event of one kind.
func eventText(events []map[string]any, kind string) []string {
	var texts []string
	for _, event := range events {
		if event["type"] == kind {
			if text, _ := event["text"].(string); text != "" {
				texts = append(texts, text)
			}
		}
	}
	return texts
}

// echoReply scripts a provider that echoes the prompt back as assistant text,
// so an assertion on the transcript proves the prompt crossed the whole stack.
func echoReply(request map[string]any) string {
	if prompt := lastUserText(request); prompt != "" {
		return "echo: " + prompt
	}
	return "fixture reply"
}

// lastUserText finds the prompt the daemon forwarded.
func lastUserText(request map[string]any) string {
	messages, _ := request["messages"].([]any)
	for _, raw := range slices.Backward(messages) {
		message, _ := raw.(map[string]any)
		if message["role"] != "user" {
			continue
		}
		switch content := message["content"].(type) {
		case string:
			return content
		case []any:
			var parts []string
			for _, part := range content {
				if item, ok := part.(map[string]any); ok {
					if text, _ := item["text"].(string); text != "" {
						parts = append(parts, text)
					}
				}
			}
			return strings.Join(parts, " ")
		}
	}
	return ""
}

// chunks splits text into stream-sized pieces.
func chunks(text string, size int) []string {
	var parts []string
	for len(text) > size {
		parts = append(parts, text[:size])
		text = text[size:]
	}
	return append(parts, text)
}
