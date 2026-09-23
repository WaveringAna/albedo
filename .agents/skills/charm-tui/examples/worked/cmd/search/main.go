package main

import (
	tea "charm.land/bubbletea/v2"
	"context"
	"fmt"
	"github.com/charmbracelet/x/term"
	"os"
)

func run() error {
	if !term.IsTerminal(os.Stdin.Fd()) || !term.IsTerminal(os.Stderr.Fd()) {
		return fmt.Errorf("search demo requires terminal stdin and stderr")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m := newModel(ctx, demoSearch)
	defer m.state.stop()
	_, err := tea.NewProgram(m, tea.WithContext(ctx), tea.WithInput(os.Stdin), tea.WithOutput(os.Stderr)).Run()
	return err
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
