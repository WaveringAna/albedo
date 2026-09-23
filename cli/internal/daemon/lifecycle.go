package daemon

import (
	"bytes"
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
	"strings"
	"time"
)

var sanitizerRegex = regexp.MustCompile(`[\p{Cc}\x{202a}-\x{202e}\x{2066}-\x{2069}]`)

const (
	pollInterval = 100 * time.Millisecond
	pollAttempts = 300
)

type Connection struct {
	Port    int    `json:"port"`
	Token   string `json:"token"`
	Pid     int    `json:"pid"`
	Version int    `json:"version"`
}

type Session struct {
	ID              string `json:"id"`
	Title           string `json:"title,omitempty"`
	LastAssistantAt *int64 `json:"last_assistant_at,omitempty"`
	Workspace       string `json:"workspace"`
	Model           string `json:"model"`
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
		title := sanitizerRegex.ReplaceAllString(s.Title, " ")
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

	var conn Connection
	if err := json.Unmarshal(data, &conn); err != nil {
		return nil, nil
	}

	if conn.Port < 1 || conn.Port > 65535 || conn.Token == "" || (conn.Version != 1 && conn.Version != 2) {
		return nil, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("http://127.0.0.1:%d/health", conn.Port), nil)
	if err != nil {
		return nil, nil
	}
	req.Header.Set("Authorization", "Bearer "+conn.Token)

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

	if health.Version == conn.Version {
		return &conn, nil
	}

	return nil, nil
}

func checkCompatible(conn *Connection) (*Connection, error) {
	if conn.Version != 2 {
		return nil, errors.New("an older daemon is running; when its work is finished, run albedo daemon --stop, then start albedo again")
	}
	return conn, nil
}

func resolveDaemonExecutable(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("ALBEDO_DAEMON must be an absolute executable path: %q", path)
	}
	resolved, err := exec.LookPath(path)
	if err != nil {
		return "", fmt.Errorf("invalid ALBEDO_DAEMON executable %q: %w", path, err)
	}
	fi, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("invalid ALBEDO_DAEMON executable %q: %w", path, err)
	}
	if fi.IsDir() {
		return "", fmt.Errorf("invalid ALBEDO_DAEMON executable %q: is a directory", path)
	}
	return resolved, nil
}

func buildDaemonEnv(homeDir, tokenHex string) []string {
	var env []string
	filteredVars := map[string]bool{
		"ALBEDO_API_KEY":  true,
		"ALBEDO_MODEL":    true,
		"ALBEDO_BASE_URL": true,
		"ALBEDO_PROTOCOL": true,
	}
	for _, kv := range os.Environ() {
		k := strings.SplitN(kv, "=", 2)[0]
		if !filteredVars[k] {
			env = append(env, kv)
		}
	}
	return append(env, "ALBEDO_HOME="+homeDir, "ALBEDO_TOKEN="+tokenHex)
}

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

func Ensure(homeDir, projectRoot string) (*Connection, error) {
	current, err := Existing(homeDir)
	if err != nil {
		return nil, err
	}
	if current != nil {
		return checkCompatible(current)
	}

	daemonExe := os.Getenv("ALBEDO_DAEMON")
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
			return nil, fmt.Errorf("daemon startup timed out; inspect %s/daemon.log; remove %s if its starter is no longer running", homeDir, lockPath)
		}
		return nil, err
	}
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

	env := buildDaemonEnv(homeDir, tokenHex)
	cmd, err := daemonCommand(daemonExe, projectRoot, env)
	if err != nil {
		_ = logFile.Close()
		return nil, err
	}
	cmd.Stdout = logFile
	cmd.Stderr = logFile

	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return nil, err
	}
	_ = logFile.Close()

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

	return nil, fmt.Errorf("daemon startup timed out; inspect %s/daemon.log", homeDir)
}

func Request[T any](ctx context.Context, conn *Connection, path string, body any) (T, error) {
	var zero T
	if ctx == nil {
		ctx = context.Background()
	}

	reqCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	method := http.MethodGet
	var bodyReader io.Reader
	if body != nil {
		method = http.MethodPost
		encoded, err := json.Marshal(body)
		if err != nil {
			return zero, err
		}
		bodyReader = bytes.NewReader(encoded)
	}

	reqURL := fmt.Sprintf("http://127.0.0.1:%d%s", conn.Port, path)
	req, err := http.NewRequestWithContext(reqCtx, method, reqURL, bodyReader)
	if err != nil {
		return zero, err
	}

	req.Header.Set("Authorization", "Bearer "+conn.Token)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	res, err := client.Do(req)
	if err != nil {
		return zero, err
	}
	defer res.Body.Close()

	respData, err := readBounded(res.Body, 50*1024*1024)
	if err != nil {
		return zero, err
	}

	if res.StatusCode < 200 || res.StatusCode >= 300 {
		var errResp struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(respData, &errResp)
		if errResp.Error != "" {
			return zero, errors.New(errResp.Error)
		}
		return zero, fmt.Errorf("HTTP %d", res.StatusCode)
	}

	var result T
	if len(respData) > 0 {
		if err := json.Unmarshal(respData, &result); err != nil {
			return zero, err
		}
	}
	return result, nil
}
