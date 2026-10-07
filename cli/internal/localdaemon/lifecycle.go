package localdaemon

import (
	"albedo/cli/internal/daemon"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	pollInterval   = 10 * time.Millisecond
	startupTimeout = 30 * time.Second
	// A ready daemon's owner observations may queue behind other work.
	discoveryProbeTimeout = 5 * time.Second
)

type DiscoveryKind int

const (
	Absent DiscoveryKind = iota
	Stale
	Running
)

type Discovery struct {
	Kind     DiscoveryKind
	Snapshot daemon.ConnectionSnapshot
	Server   daemon.ServerInfo
}

type LocalOptions struct {
	HomeDir     string
	ProjectRoot string
}

type LocalErrorKind string

const (
	InvalidDiscovery     LocalErrorKind = "invalid_discovery"
	DiscoveryUnavailable LocalErrorKind = "discovery_unavailable"
	UnreachableDaemon    LocalErrorKind = "unreachable_daemon"
	UnhealthyDaemon      LocalErrorKind = "unhealthy_daemon"
	IncompatibleDaemon   LocalErrorKind = "incompatible_daemon"
	AuthenticationFailed LocalErrorKind = "authentication_failed"
	TargetChanged        LocalErrorKind = "target_changed"
	LauncherLockFailure  LocalErrorKind = "launcher_lock_failure"
	StartupFailed        LocalErrorKind = "startup_failed"
	HomeInUse            LocalErrorKind = "home_in_use"
)

type LocalError struct {
	Kind    LocalErrorKind
	HomeDir string
	Cause   error
}

func (e *LocalError) Error() string {
	return fmt.Sprintf("Albedo %s in %s: %v", strings.ReplaceAll(string(e.Kind), "_", " "), e.HomeDir, e.Cause)
}
func (e *LocalError) Unwrap() error { return e.Cause }

// Discover distinguishes missing and proven stale records from unsafe failures.
// A valid live endpoint is returned even when its API contract needs upgrading.
func Discover(ctx context.Context, homeDir string) (Discovery, error) {
	if err := ctx.Err(); err != nil {
		return Discovery{}, err
	}
	fail := func(kind LocalErrorKind, cause error) (Discovery, error) {
		return Discovery{}, &LocalError{Kind: kind, HomeDir: homeDir, Cause: cause}
	}
	file, err := os.Open(filepath.Join(homeDir, "daemon.json"))
	if errors.Is(err, os.ErrNotExist) {
		return Discovery{Kind: Absent}, nil
	}
	if err != nil {
		return fail(DiscoveryUnavailable, err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 64*1024+1))
	if err != nil {
		return fail(DiscoveryUnavailable, err)
	}
	if len(data) > 64*1024 {
		return fail(InvalidDiscovery, errors.New("daemon.json exceeds 64 KiB"))
	}
	var snapshot daemon.ConnectionSnapshot
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return fail(InvalidDiscovery, err)
	}
	if snapshot.Pid <= 0 || snapshot.Port < 1 || snapshot.Port > 65535 || snapshot.Token == "" || snapshot.Version <= 0 {
		return fail(InvalidDiscovery, errors.New("daemon.json requires a positive PID, valid port, token and protocol version"))
	}
	probeCtx, cancel := context.WithTimeout(ctx, discoveryProbeTimeout)
	connection := daemon.NewConnection(snapshot, nil)
	server, err := daemon.ProbeServer(probeCtx, connection)
	connection.HTTPClient().CloseIdleConnections()
	cancel()
	if err != nil {
		if ctx.Err() != nil {
			return Discovery{}, ctx.Err()
		}
		if !processAlive(snapshot.Pid) && endpointRefused(err) {
			return Discovery{Kind: Stale, Snapshot: snapshot}, nil
		}
		if api, ok := errors.AsType[*daemon.APIError](err); ok {
			if api.StatusCode == http.StatusUnauthorized || api.StatusCode == http.StatusForbidden {
				return fail(AuthenticationFailed, err)
			}
			if api.StatusCode == http.StatusNotFound && snapshot.Version != daemon.ProtocolVersion {
				return fail(IncompatibleDaemon, &daemon.CompatibilityError{Version: snapshot.Version})
			}
			return fail(UnhealthyDaemon, err)
		}
		if _, ok := errors.AsType[*daemon.ProtocolError](err); ok {
			return fail(UnhealthyDaemon, err)
		}
		return fail(UnreachableDaemon, err)
	}
	if server.Protocol != snapshot.Version || (server.Build != "" && server.Build != snapshot.Build) ||
		(server.Digest != "" && snapshot.Digest != "" && server.Digest != snapshot.Digest) {
		return fail(InvalidDiscovery, errors.New("server identity does not match daemon.json"))
	}
	if snapshot.InstanceID != "" && snapshot.InstanceID != server.InstanceID {
		return fail(InvalidDiscovery, errors.New("server identity does not match daemon.json"))
	}
	snapshot.InstanceID, snapshot.Digest = server.InstanceID, server.Digest
	discovery := Discovery{Kind: Running, Snapshot: snapshot, Server: server}
	return discovery, daemon.CheckCompatible(server)
}

// Rediscover waits for a verified replacement endpoint without starting one.
func Rediscover(ctx context.Context, homeDir string) (daemon.ConnectionSnapshot, error) {
	for range 20 {
		discovery, err := Discover(ctx, homeDir)
		if err == nil && discovery.Kind == Running {
			return discovery.Snapshot, nil
		}
		if err != nil {
			var local *LocalError
			if !errors.As(err, &local) || (local.Kind != UnreachableDaemon && local.Kind != UnhealthyDaemon) {
				return daemon.ConnectionSnapshot{}, err
			}
			var api *daemon.APIError
			if errors.As(err, &api) && !api.DaemonRestarting() {
				return daemon.ConnectionSnapshot{}, err
			}
			if _, ok := errors.AsType[*daemon.ProtocolError](err); ok {
				return daemon.ConnectionSnapshot{}, err
			}
		}
		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return daemon.ConnectionSnapshot{}, ctx.Err()
		case <-timer.C:
		}
	}
	return daemon.ConnectionSnapshot{}, &LocalError{Kind: UnreachableDaemon, HomeDir: homeDir, Cause: errors.New("could not rediscover a ready daemon; check whether it is running")}
}

func resolveDaemonExecutable(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("ALBEDO_DAEMON must point to an executable using its full path: %q", path)
	}
	resolved, err := exec.LookPath(path)
	if err != nil {
		return "", fmt.Errorf("cannot run ALBEDO_DAEMON (%q): %w", path, err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if info.IsDir() {
		return "", fmt.Errorf("ALBEDO_DAEMON points to a directory (%q)", path)
	}
	return resolved, nil
}

// Local launch filters provider overrides; daemon bootstrap owns all defaults.
func daemonCommand(options LocalOptions) (*exec.Cmd, error) {
	return LocalCommand(context.Background(), options)
}

// LocalCommand selects the local daemon executable without launching its server.
func LocalCommand(ctx context.Context, options LocalOptions, args ...string) (*exec.Cmd, error) {
	executable := os.Getenv("ALBEDO_DAEMON")
	if executable == "" {
		if options.ProjectRoot == "" {
			return nil, errors.New("set ALBEDO_DAEMON to its full executable path or ALBEDO_ROOT to a source checkout")
		}
		root, err := filepath.Abs(options.ProjectRoot)
		if err != nil {
			return nil, err
		}
		if _, err := exec.LookPath("gleam"); err != nil {
			return nil, fmt.Errorf("source daemon requires gleam: %w", err)
		}
		executable = filepath.Join(root, "priv", "bin", "albedo-daemon")
	}
	executable, err := resolveDaemonExecutable(executable)
	if err != nil {
		return nil, err
	}
	cmd := exec.CommandContext(ctx, executable, args...)
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		switch key {
		case "ALBEDO_API_KEY", "ALBEDO_MODEL", "ALBEDO_BASE_URL", "ALBEDO_PROTOCOL", "ALBEDO_HOME":
		default:
			cmd.Env = append(cmd.Env, entry)
		}
	}
	cmd.Env = append(cmd.Env, "ALBEDO_HOME="+options.HomeDir)
	return cmd, nil
}

func waitForPoll(ctx context.Context) error {
	timer := time.NewTimer(pollInterval)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func acquireLauncher(ctx context.Context, homeDir string) (*os.File, error) {
	// The launcher must create its lock directory before the daemon can start.
	if err := os.MkdirAll(homeDir, 0700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(homeDir, "launcher.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	for {
		if err := ctx.Err(); err != nil {
			file.Close()
			return nil, err
		}
		acquired, err := tryLauncherLock(file)
		if err != nil {
			file.Close()
			return nil, err
		}
		if acquired {
			return file, nil
		}
		if err := waitForPoll(ctx); err != nil {
			file.Close()
			return nil, err
		}
	}
}

// Launch serializes local startup without weakening the daemon's home lock.
func Launch(parent context.Context, options LocalOptions) (*daemon.Connection, error) {
	return launchLocal(parent, options, nil)
}

// Upgrade stops only the exact authenticated protocol 3 daemon approved by the caller.
func Upgrade(parent context.Context, options LocalOptions, approved daemon.ConnectionSnapshot) (*daemon.Connection, error) {
	return launchLocal(parent, options, &approved)
}

func launchLocal(parent context.Context, options LocalOptions, approved *daemon.ConnectionSnapshot) (*daemon.Connection, error) {
	ctx, cancel := context.WithTimeout(parent, startupTimeout)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if options.HomeDir == "" {
		return nil, errors.New("local launch requires HomeDir")
	}
	home, err := filepath.Abs(options.HomeDir)
	if err != nil {
		return nil, err
	}
	options.HomeDir = home
	// Validate the replacement executable before taking any destructive action.
	cmd, err := daemonCommand(options)
	if err != nil {
		return nil, err
	}
	lock, err := acquireLauncher(ctx, home)
	if err != nil {
		return nil, &LocalError{Kind: LauncherLockFailure, HomeDir: home, Cause: err}
	}
	defer lock.Close() // Closing releases the advisory lock; its inode persists.
	discovery, discoveryErr := Discover(ctx, home)
	if approved == nil {
		if discoveryErr != nil {
			return nil, discoveryErr
		}
		if discovery.Kind == Running {
			return daemon.Attach(ctx, discovery.Snapshot, func(ctx context.Context) (daemon.ConnectionSnapshot, error) { return Rediscover(ctx, home) })
		}
	} else {
		var compatible *daemon.CompatibilityError
		if discoveryErr != nil && !errors.As(discoveryErr, &compatible) {
			return nil, discoveryErr
		}
		if discovery.Kind != Running || discovery.Snapshot != *approved {
			return nil, &LocalError{Kind: TargetChanged, HomeDir: home, Cause: errors.New("the daemon changed after approval; review the current daemon before restarting")}
		}
		if discovery.Server.Protocol != daemon.ProtocolVersion {
			return nil, &daemon.CompatibilityError{Version: discovery.Server.Protocol}
		}
		connection := daemon.NewConnection(discovery.Snapshot, nil)
		stopErr := daemon.StopDaemon(ctx, connection)
		connection.HTTPClient().CloseIdleConnections()
		if stopErr != nil {
			return nil, stopErr
		}
		for processAlive(discovery.Snapshot.Pid) {
			if err := waitForPoll(ctx); err != nil {
				return nil, err
			}
		}
		current, err := Discover(ctx, home)
		if err != nil {
			return nil, err
		}
		if current.Kind == Running {
			return nil, &LocalError{Kind: TargetChanged, HomeDir: home, Cause: errors.New("another daemon started during shutdown")}
		}
	}
	return startLocal(ctx, cmd, options)
}

func startLocal(ctx context.Context, cmd *exec.Cmd, options LocalOptions) (*daemon.Connection, error) {
	logPath := filepath.Join(options.HomeDir, "daemon.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return nil, err
	}
	logStart, _ := logFile.Seek(0, io.SeekEnd)
	cmd.Stdout, cmd.Stderr = logFile, logFile
	detach(cmd)
	passFileLimit()
	if err := ctx.Err(); err != nil {
		logFile.Close()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		logFile.Close()
		return nil, err
	}
	logFile.Close()
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	contended := false
	for {
		discovery, err := Discover(ctx, options.HomeDir)
		if err == nil && discovery.Kind == Running {
			return daemon.Attach(ctx, discovery.Snapshot, func(ctx context.Context) (daemon.ConnectionSnapshot, error) { return Rediscover(ctx, options.HomeDir) })
		}
		if err != nil && ctx.Err() == nil {
			var local *LocalError
			var api *daemon.APIError
			unreachable := errors.As(err, &local) && local.Kind == UnreachableDaemon
			starting := errors.As(err, &api) && api.DaemonRestarting()
			if !unreachable && !starting {
				return nil, err
			}
		}
		select {
		case waitErr := <-exited:
			exited = nil
			var exit *exec.ExitError
			if errors.As(waitErr, &exit) && exit.ExitCode() == 75 {
				contended = true
			} else {
				return nil, &LocalError{Kind: StartupFailed, HomeDir: options.HomeDir, Cause: startupExitError(waitErr, logPath, logStart, options.ProjectRoot)}
			}
		case <-ctx.Done():
			if contended && errors.Is(ctx.Err(), context.DeadlineExceeded) {
				return nil, &LocalError{Kind: HomeInUse, HomeDir: options.HomeDir, Cause: fmt.Errorf("home is held by another daemon or maintenance command; wait for it to finish and retry: %w", ctx.Err())}
			}
			return nil, ctx.Err()
		case <-time.After(pollInterval):
		}
	}
}

func startupExitError(waitErr error, logPath string, logStart int64, projectRoot string) error {
	message := "daemon stopped before it finished starting"
	if file, err := os.Open(logPath); err == nil {
		defer file.Close()
		if _, err := file.Seek(logStart, io.SeekStart); err == nil {
			output, _ := io.ReadAll(io.LimitReader(file, 4096))
			if tail := strings.TrimSpace(string(output)); tail != "" {
				message += ":\n" + tail
			}
		}
	}
	if projectRoot != "" {
		message += fmt.Sprintf("\nsource checkout: %s; check ALBEDO_ROOT", projectRoot)
	}
	if waitErr != nil {
		return fmt.Errorf("%s: %w", message, waitErr)
	}
	return errors.New(message)
}
