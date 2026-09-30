package daemon

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var sanitizerRegex = regexp.MustCompile(`[\p{Cc}\x{202a}-\x{202e}\x{2066}-\x{2069}]`)

// SessionText replaces control characters and direction overrides in session metadata.
func SessionText(s string) string { return sanitizerRegex.ReplaceAllString(s, " ") }

const (
	pollInterval = 100 * time.Millisecond
	pollAttempts = 300
)

type ConnectionSnapshot struct {
	Port    int    `json:"port"`
	Token   string `json:"token"`
	Pid     int    `json:"pid"`
	Version int    `json:"version"`
	Build   string `json:"build,omitempty"`
}

type Connection struct {
	snapshot   atomic.Pointer[ConnectionSnapshot]
	refreshMu  sync.Mutex
	homeDir    string
	httpOnce   sync.Once
	httpClient *http.Client
}

// NewConnection binds a daemon snapshot to its discovery directory. An empty
// directory permits HTTP requests but disables automatic rediscovery.
func NewConnection(snap ConnectionSnapshot, homeDir string) *Connection {
	c := &Connection{homeDir: homeDir}
	c.snapshot.Store(&snap)
	return c
}

func (c *Connection) Snapshot() ConnectionSnapshot {
	if c == nil {
		return ConnectionSnapshot{}
	}
	p := c.snapshot.Load()
	if p == nil {
		return ConnectionSnapshot{}
	}
	return *p
}

func (c *Connection) Port() int {
	return c.Snapshot().Port
}

func (c *Connection) Token() string {
	return c.Snapshot().Token
}

func (c *Connection) Pid() int {
	return c.Snapshot().Pid
}

func (c *Connection) Version() int {
	return c.Snapshot().Version
}

func (c *Connection) Build() string {
	return c.Snapshot().Build
}

func (c *Connection) BaseURL() string {
	port := c.Port()
	if port <= 0 {
		return ""
	}
	return fmt.Sprintf("http://127.0.0.1:%d", port)
}

func (c *Connection) AuthToken() string {
	return c.Token()
}

func (c *Connection) HomeDir() string {
	if c == nil {
		return ""
	}
	return c.homeDir
}

func (c *Connection) SetHomeDir(dir string) {
	if c != nil {
		c.homeDir = dir
	}
}

func (c *Connection) Update(other *Connection) {
	if c == nil || other == nil || c == other {
		return
	}
	snap := other.Snapshot()
	c.snapshot.Store(&snap)
	if other.homeDir != "" {
		c.homeDir = other.homeDir
	}
}

func (c *Connection) Refresh(ctx context.Context) error {
	if c == nil {
		return errors.New("Not connected to Albedo.")
	}
	c.refreshMu.Lock()
	defer c.refreshMu.Unlock()

	homeDir := c.HomeDir()
	if homeDir == "" {
		return errors.New("Cannot reconnect without a daemon home directory.")
	}

	const attempts = 20
	const interval = 100 * time.Millisecond

	var lastErr error
	for i := 0; i < attempts; i++ {
		if ctx != nil && ctx.Err() != nil {
			return ctx.Err()
		}
		latest, err := Existing(homeDir)
		if err != nil {
			lastErr = err
		} else if latest != nil {
			if _, compErr := checkCompatible(latest); compErr != nil {
				return compErr
			}
			c.Update(latest)
			return nil
		}
		if i < attempts-1 {
			select {
			case <-time.After(interval):
			case <-ctxDone(ctx):
				return ctx.Err()
			}
		}
	}
	if lastErr != nil {
		return lastErr
	}
	return fmt.Errorf("Could not reconnect to Albedo. Check whether it is running with ALBEDO_HOME=%s.", homeDir)
}

// HTTPClient returns the reusable HTTP client owned by this Connection.
// Address and token updates retain the same client and pool.
func (c *Connection) HTTPClient() *http.Client {
	c.httpOnce.Do(func() { c.httpClient = NewReconnectingClient(c) })
	return c.httpClient
}

func (c *Connection) MarshalJSON() ([]byte, error) {
	snap := c.Snapshot()
	return json.Marshal(snap)
}

func (c *Connection) UnmarshalJSON(data []byte) error {
	var snap ConnectionSnapshot
	if err := json.Unmarshal(data, &snap); err != nil {
		return err
	}
	c.snapshot.Store(&snap)
	return nil
}

func ctxDone(ctx context.Context) <-chan struct{} {
	if ctx == nil {
		return nil
	}
	return ctx.Done()
}

// Stale is a live daemon from a build other than the one this client bundles.
type Stale struct {
	Running *Connection
	Bundled string
}

// Replace decides whether a stale daemon stops so the bundled build can start.
type Replace func(Stale) bool

type Session struct {
	ID              string `json:"id"`
	Title           string `json:"title,omitempty"`
	LastAssistantAt *int64 `json:"last_assistant_at,omitempty"`
	Workspace       string `json:"workspace"`
	Model           string `json:"model"`
	Effort          string `json:"effort,omitempty"`
	Protocol        string `json:"protocol"`
	Provider        string `json:"provider"`
}

func AssistantAge(timestamp *int64, now time.Time) string {
	if timestamp == nil {
		return "time unknown"
	}
	sec := now.Unix() - *timestamp
	if sec < 0 {
		sec = 0
	}
	if sec < 60 {
		return "just now"
	}
	if sec < 3600 {
		return fmt.Sprintf("%dm ago", sec/60)
	}
	if sec < 86400 {
		return fmt.Sprintf("%dh ago", sec/3600)
	}
	return fmt.Sprintf("%dd ago", sec/86400)
}

func SessionListing(sessions []Session, now time.Time) string {
	if len(sessions) == 0 {
		return "no sessions"
	}

	lines := make([]string, 0, len(sessions))
	for _, s := range sessions {
		title := SessionText(s.Title)
		title = strings.TrimSpace(title)
		if title == "" {
			title = "session name unavailable"
		}
		shortID := s.ID
		if len(shortID) > 8 {
			shortID = shortID[:8]
		}
		lines = append(lines, fmt.Sprintf("%s  [%s]\n  last assistant: %s", title, shortID, AssistantAge(s.LastAssistantAt, now)))
	}

	return strings.Join(lines, "\n\n")
}

func Existing(homeDir string) (*Connection, error) {
	recordPath := filepath.Join(homeDir, "daemon.json")
	fi, err := os.Stat(recordPath)
	if err != nil || fi.Size() > 64*1024 {
		return nil, nil
	}
	data, err := os.ReadFile(recordPath)
	if err != nil {
		return nil, nil
	}

	var snap ConnectionSnapshot
	if err := json.Unmarshal(data, &snap); err != nil {
		return nil, nil
	}

	if snap.Port < 1 || snap.Port > 65535 || snap.Token == "" || (snap.Version != 1 && snap.Version != 2) {
		return nil, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("http://127.0.0.1:%d/health", snap.Port), nil)
	if err != nil {
		return nil, nil
	}
	req.Header.Set("Authorization", "Bearer "+snap.Token)

	// Refresh calls Existing; a reconnecting health probe would recurse into Refresh.
	client := &http.Client{
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	res, err := client.Do(req)
	if err != nil {
		return nil, nil
	}
	defer res.Body.Close()

	if res.StatusCode != http.StatusOK {
		return nil, nil
	}

	body, err := readBounded(res.Body, 64*1024)
	if err != nil {
		return nil, nil
	}

	var health struct {
		Version int `json:"version"`
	}
	if err := json.Unmarshal(body, &health); err != nil {
		return nil, nil
	}

	if health.Version == snap.Version {
		return NewConnection(snap, homeDir), nil
	}

	return nil, nil
}

func checkCompatible(conn *Connection) (*Connection, error) {
	if conn.Version() != 2 {
		return nil, errors.New("This client cannot connect to the copy of Albedo already running. After its work has finished, run albedo daemon --stop, then launch Albedo again.")
	}
	return conn, nil
}

func resolveDaemonExecutable(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("ALBEDO_DAEMON must point to an executable using its full path: %q", path)
	}
	resolved, err := exec.LookPath(path)
	if err != nil {
		return "", fmt.Errorf("Cannot run the executable specified by ALBEDO_DAEMON (%q): %w", path, err)
	}
	fi, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("Cannot run the executable specified by ALBEDO_DAEMON (%q): %w", path, err)
	}
	if fi.IsDir() {
		return "", fmt.Errorf("ALBEDO_DAEMON points to a directory (%q). Set it to the executable file instead.", path)
	}
	return resolved, nil
}

// bundledBuild names a packaged daemon by its resolved executable, which a
// content-addressed install changes on every build. A source checkout has none.
func bundledBuild(daemonExe string) string {
	if daemonExe == "" {
		return ""
	}
	resolved, err := resolveDaemonExecutable(daemonExe)
	if err != nil {
		return ""
	}
	if real, err := filepath.EvalSymlinks(resolved); err == nil {
		return real
	}
	return resolved
}

func buildDaemonEnv(homeDir, tokenHex, build string) []string {
	var env []string
	filteredVars := map[string]bool{
		"ALBEDO_API_KEY":  true,
		"ALBEDO_MODEL":    true,
		"ALBEDO_BASE_URL": true,
		"ALBEDO_PROTOCOL": true,
		"ALBEDO_BUILD":    true,
	}
	erlFlags := daemonErlFlags
	for _, kv := range os.Environ() {
		k, v, _ := strings.Cut(kv, "=")
		if k == "ERL_FLAGS" {
			// The operator's flags come last so they override the defaults.
			erlFlags += " " + v
			continue
		}
		if !filteredVars[k] {
			env = append(env, kv)
		}
	}
	env = append(env, "ERL_FLAGS="+erlFlags, "ALBEDO_HOME="+homeDir, "ALBEDO_TOKEN="+tokenHex)
	if build != "" {
		env = append(env, "ALBEDO_BUILD="+build)
	}
	return env
}

// Sized for one local daemon, measured with ALBEDO_INSPECT (three large
// sessions running turns at once peaked near 80 MB instead of 100).
//
// +P/+Q: the process and port tables are preallocated at their limits; the
// defaults (1,048,576 processes, 65,536 ports) cost about 16 MB up front.
//
// +MB*/+MH* (binary and heap allocators): transcripts are loaded and dropped
// per turn, so allocations come in bursts. Small carriers, address-order
// best fit, a low single-block threshold (so large binaries get their own
// mapping) and no carrier pooling let freed bursts go back to the OS instead
// of staying resident as empty carrier space.
const daemonErlFlags = "+P 65536 +Q 16384" +
	" +MBsbct 16 +MHsbct 32 +MBlmbcs 256 +MHlmbcs 256 +MBsmbcs 32 +MHsmbcs 32" +
	" +MBas aobf +MHas aobf +MBacul 0 +MHacul 0"

func daemonCommand(daemonExe, projectRoot string, env []string) (*exec.Cmd, error) {
	if daemonExe != "" {
		resolved, err := resolveDaemonExecutable(daemonExe)
		if err != nil {
			return nil, err
		}
		cmd := exec.Command(resolved)
		cmd.Dir = ""
		cmd.Env = env
		return cmd, nil
	}

	cmd := exec.Command("gleam", "run")
	cmd.Dir = projectRoot
	cmd.Env = env
	return cmd, nil
}

// stop shuts a daemon down and waits until its process has exited, so the
// next daemon can take the home.
func stop(homeDir string, conn *Connection) error {
	_, _ = Request[any](context.Background(), conn, "/shutdown", map[string]any{})
	for attempt := 0; attempt < pollAttempts; attempt++ {
		running, err := Existing(homeDir)
		if err != nil {
			return err
		}
		if running == nil && !processAlive(conn.Pid()) {
			return nil
		}
		time.Sleep(pollInterval)
	}
	return fmt.Errorf("Albedo did not stop. Check %s for details. The running process ID is %d.", filepath.Join(homeDir, "daemon.log"), conn.Pid())
}

// Ensure connects to the running daemon or starts one. When this client bundles
// a daemon and the running one is another build, replace (if non-nil) decides
// whether it is stopped first.
func Ensure(homeDir, projectRoot string, replace Replace) (*Connection, error) {
	daemonExe := os.Getenv("ALBEDO_DAEMON")
	build := bundledBuild(daemonExe)

	current, err := Existing(homeDir)
	if err != nil {
		return nil, err
	}
	if current != nil {
		if build == "" || current.Build() == build || replace == nil || !replace(Stale{current, build}) {
			return checkCompatible(current)
		}
		if err := stop(homeDir, current); err != nil {
			return nil, err
		}
	}

	if daemonExe != "" {
		if _, err := resolveDaemonExecutable(daemonExe); err != nil {
			return nil, err
		}
	}

	if err := os.MkdirAll(homeDir, 0700); err != nil {
		return nil, err
	}
	_ = os.Chmod(homeDir, 0700)

	lockPath := filepath.Join(homeDir, "starting.lock")
	lockFile, err := os.OpenFile(lockPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil && os.IsExist(err) && staleLock(lockPath) {
		_ = os.Remove(lockPath)
		lockFile, err = os.OpenFile(lockPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	}
	if err != nil {
		if os.IsExist(err) {
			for attempt := 0; attempt < pollAttempts; attempt++ {
				running, err := Existing(homeDir)
				if err != nil {
					return nil, err
				}
				if running != nil {
					return checkCompatible(running)
				}
				time.Sleep(pollInterval)
			}
			return nil, fmt.Errorf("Albedo is taking too long to start. Check %s/daemon.log for details. Only remove %s if the process starting Albedo is no longer running.", homeDir, lockPath)
		}
		return nil, err
	}
	_, _ = fmt.Fprintf(lockFile, "%d", os.Getpid())
	defer func() {
		_ = lockFile.Close()
		_ = os.Remove(lockPath)
	}()

	again, err := Existing(homeDir)
	if err != nil {
		return nil, err
	}
	if again != nil {
		return checkCompatible(again)
	}

	logPath := filepath.Join(homeDir, "daemon.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return nil, err
	}

	randomToken := make([]byte, 32)
	_, _ = rand.Read(randomToken)
	tokenHex := hex.EncodeToString(randomToken)

	env := buildDaemonEnv(homeDir, tokenHex, build)
	cmd, err := daemonCommand(daemonExe, projectRoot, env)
	if err != nil {
		_ = logFile.Close()
		return nil, err
	}
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	detach(cmd)

	logStart, _ := logFile.Seek(0, io.SeekEnd)
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return nil, err
	}
	_ = logFile.Close()

	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()

	for attempt := 0; attempt < pollAttempts; attempt++ {
		running, err := Existing(homeDir)
		if err != nil {
			return nil, err
		}
		if running != nil {
			return checkCompatible(running)
		}
		select {
		case waitErr := <-exited:
			root := projectRoot
			if daemonExe != "" {
				root = ""
			}
			return nil, startupExitError(waitErr, logPath, logStart, root)
		case <-time.After(pollInterval):
		}
	}

	return nil, fmt.Errorf("Albedo is taking too long to start. Check %s/daemon.log for details.", homeDir)
}

// staleLock reports whether the startup lock was left by a starter that is no
// longer running (e.g. one interrupted with ctrl-c before it could clean up).
func staleLock(lockPath string) bool {
	data, err := os.ReadFile(lockPath)
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		// Locks from older clients carry no pid; treat them as stale once they
		// are older than the startup window.
		fi, statErr := os.Stat(lockPath)
		return statErr == nil && time.Since(fi.ModTime()) > pollInterval*pollAttempts
	}
	return !processAlive(pid)
}

func startupExitError(waitErr error, logPath string, logStart int64, projectRoot string) error {
	msg := "Albedo stopped before it finished starting"

	if f, err := os.Open(logPath); err == nil {
		defer f.Close()
		if _, err := f.Seek(logStart, io.SeekStart); err == nil {
			out, _ := io.ReadAll(io.LimitReader(f, 4096))
			if tail := strings.TrimSpace(string(out)); tail != "" {
				msg += ":\n" + tail
			}
		}
	}
	if projectRoot != "" {
		msg += fmt.Sprintf("\nSource checkout: %s. If this is not your Albedo checkout, set ALBEDO_ROOT to its full path.", projectRoot)
	}
	if waitErr != nil {
		return fmt.Errorf("%s: %w", msg, waitErr)
	}
	return errors.New(msg)
}

// Capabilities lists what the daemon at conn says it supports.
func Capabilities(ctx context.Context, conn *Connection) ([]string, error) {
	health, err := Request[struct {
		Capabilities []string `json:"capabilities"`
	}](ctx, conn, "/health", nil)
	return health.Capabilities, err
}

// CheckCapability is UpgradeNeeded(feature) when the daemon answers /health
// without capability. A /health that fails is left to the request after it.
func CheckCapability(ctx context.Context, conn *Connection, capability, feature string) error {
	if caps, err := Capabilities(ctx, conn); err == nil && !slices.Contains(caps, capability) {
		return UpgradeNeeded(feature)
	}
	return nil
}

// UpgradeNeeded is the error for a feature the running daemon predates;
// feature finishes the sentence, as in "for /tree" or "to switch providers".
func UpgradeNeeded(feature string) error {
	return &UpgradeRequiredError{Feature: feature}
}
