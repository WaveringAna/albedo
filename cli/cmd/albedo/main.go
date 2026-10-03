// Command albedo wires the services and reports command failures once.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"albedo/cli/internal/app"
	"albedo/cli/internal/cli"
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/storage"
	"albedo/cli/internal/terminal"
)

var buildRoot string // Embedded via -ldflags "-X main.buildRoot=...".

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run(args []string) error {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	streams := cli.Streams{In: os.Stdin, Out: os.Stdout, Err: os.Stderr}
	home := config.HomeDir()
	term := &terminal.Service{In: streams.In, Out: streams.Out, Err: streams.Err, Capable: terminal.IsTTY(streams.In, streams.Out), Home: home}
	if os.Getenv("ALBEDO_NO_BROWSER") == "" {
		term.OpenBrowser = config.OpenBrowser
	}
	options := daemon.LocalOptions{HomeDir: home, ProjectRoot: findProjectRoot()}
	rediscover := func(ctx context.Context) (daemon.ConnectionSnapshot, error) { return daemon.Rediscover(ctx, home) }
	var chosen *daemon.Connection
	application := &app.Service{
		Connect: func(ctx context.Context) (*daemon.Connection, error) {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			if chosen != nil {
				return chosen, nil
			}
			found, err := daemon.Discover(ctx, home)
			if err != nil {
				if _, compatibleFailure := errors.AsType[*daemon.CompatibilityError](err); !compatibleFailure || found.Kind != daemon.Running {
					return nil, err
				}
			}
			if found.Kind != daemon.Running {
				chosen, err = daemon.Launch(ctx, options)
				return chosen, err
			}
			// An unknown protocol cannot safely authorize the shutdown operation.
			if found.Server.Protocol != daemon.ProtocolVersion {
				return nil, daemon.CheckCompatible(found.Server)
			}
			// A restart offer needs a reason: a provable build difference,
			// or a difference no digest or label can rule out. Proven
			// sameness attaches and keeps the running sessions warm.
			selected := selectedBuild(options.ProjectRoot)
			running := daemon.BuildIdentity{Build: found.Snapshot.Build, Digest: found.Snapshot.Digest}
			if daemon.BuildMismatch(running, selected) {
				restart, err := term.ConfirmRestart(ctx, found.Snapshot, selected)
				if err != nil {
					return nil, err
				}
				if restart {
					return daemon.Upgrade(ctx, options, found.Snapshot)
				}
			}
			chosen, err = daemon.Attach(ctx, found.Snapshot, rediscover)
			return chosen, err
		},
		Existing: func(ctx context.Context) (*daemon.Connection, error) {
			found, err := daemon.Discover(ctx, home)
			if err != nil {
				if _, compatibleFailure := errors.AsType[*daemon.CompatibilityError](err); !compatibleFailure || found.Kind != daemon.Running {
					return nil, err
				}
			}
			if found.Kind != daemon.Running {
				return nil, nil
			}
			if found.Server.Protocol != daemon.ProtocolVersion {
				return nil, daemon.CheckCompatible(found.Server)
			}
			return daemon.Attach(ctx, found.Snapshot, nil)
		},
	}
	store := &storage.Service{
		Home: home, Now: time.Now,
		Running: func() (bool, error) {
			found, err := daemon.Discover(ctx, home)
			if _, compatibilityFailure := errors.AsType[*daemon.CompatibilityError](err); compatibilityFailure && found.Kind == daemon.Running {
				return true, nil
			}
			return found.Kind == daemon.Running, err
		},
		DeleteSessions: application.DeleteSessions,
		OnlineReport:   application.StorageReport,
	}
	workspace, err := os.Getwd()
	if err != nil {
		workspace = "."
	}
	return cli.Execute(ctx, args, cli.Dependencies{Application: application, Storage: store, Terminal: term, Workspace: workspace}, streams)
}
