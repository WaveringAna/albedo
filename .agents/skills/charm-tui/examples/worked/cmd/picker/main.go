// picker is a runnable demonstration, not a deployment tool.
package main

import (
	tea "charm.land/bubbletea/v2"
	"flag"
	"fmt"
	"github.com/charmbracelet/x/term"
	"os"
)

var servers = []item{
	{"dev-eu", "development", "eu · ready"},
	{"stage-eu", "staging", "eu · ready"},
	{"prod-eu", "production", "eu · healthy"},
	{"prod-jp", "東京 production", "jp · healthy"},
	{"queue-eu", "queue worker", "eu · busy"},
}

func run(args []string) (int, error) {
	flags := flag.NewFlagSet("picker", flag.ContinueOnError)
	id := flags.String("id", "", "select an exact ID without opening a terminal")
	list := flags.Bool("list", false, "print IDs and labels without opening a terminal")
	if err := flags.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return 0, nil
		}
		return 2, err
	}
	if flags.NArg() != 0 {
		return 2, fmt.Errorf("unexpected arguments")
	}
	if *list && *id != "" {
		return 2, fmt.Errorf("choose either --list or --id")
	}
	if *list {
		for _, row := range servers {
			if _, err := fmt.Fprintf(os.Stdout, "%s\t%s\n", row.ID, row.Label); err != nil {
				return 2, err
			}
		}
		return 0, nil
	}
	if *id != "" {
		for _, row := range servers {
			if row.ID == *id {
				return finish(os.Stdout, outcome{Accepted: true, ID: row.ID})
			}
		}
		return 2, fmt.Errorf("unknown ID %q", *id)
	}
	// stdout may be a pipe. Only stdin and the UI's stderr must be terminals.
	// Do not open a hidden /dev/tty in unattended jobs.
	if !term.IsTerminal(os.Stdin.Fd()) || !term.IsTerminal(os.Stderr.Fd()) {
		return 2, fmt.Errorf("interactive mode needs terminal stdin and stderr; use --list or --id")
	}
	final, err := tea.NewProgram(newModel(servers), tea.WithInput(os.Stdin), tea.WithOutput(os.Stderr)).Run()
	if err != nil {
		return 2, fmt.Errorf("picker: %w", err)
	}
	m, ok := final.(*model)
	if !ok {
		return 2, fmt.Errorf("unexpected final model %T", final)
	}
	return finish(os.Stdout, m.result)
}

func main() {
	code, err := run(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	os.Exit(code) // run's defers and Bubble Tea cleanup have already completed.
}
