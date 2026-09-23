package main

import (
	tea "charm.land/bubbletea/v2"
	"context"
	"fmt"
	"github.com/charmbracelet/x/term"
	"os"
	"time"
)

func run() error {
	if !term.IsTerminal(os.Stdin.Fd()) || !term.IsTerminal(os.Stderr.Fd()) {
		return fmt.Errorf("tail demo requires terminal stdin and stderr")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m := &model{ctx: ctx, cancel: cancel, events: produce(ctx, 80, 250*time.Millisecond), history: newHistory(32), width: 80, height: 24}
	_, err := tea.NewProgram(m, tea.WithInput(os.Stdin), tea.WithOutput(os.Stderr)).Run()
	return err
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
