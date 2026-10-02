// Command albedo wires the services and reports command failures once.
package main

import (
	"context"
	"fmt"
	"os"
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
	streams := cli.Streams{In: os.Stdin, Out: os.Stdout, Err: os.Stderr}
	home := config.HomeDir()
	term := &terminal.Service{In: streams.In, Out: streams.Out, Err: streams.Err, Capable: terminal.IsTTY(streams.In, streams.Out), Home: home}
	if os.Getenv("ALBEDO_NO_BROWSER") == "" {
		term.OpenBrowser = config.OpenBrowser
	}
	application := &app.Service{
		Connect: func(ctx context.Context) (*daemon.Connection, error) {
			return daemon.EnsureContext(ctx, home, findProjectRoot(), term.ReplaceStale)
		},
		Existing: func(ctx context.Context) (*daemon.Connection, error) { return daemon.ExistingContext(ctx, home) },
	}
	store := &storage.Service{
		Home: home, Now: time.Now,
		Running:        func() (bool, error) { conn, err := daemon.Existing(home); return conn != nil, err },
		DeleteSessions: application.DeleteSessions,
	}
	workspace, err := os.Getwd()
	if err != nil {
		workspace = "."
	}
	return cli.Execute(context.Background(), args, cli.Dependencies{Application: application, Storage: store, Terminal: term, Workspace: workspace}, streams)
}
