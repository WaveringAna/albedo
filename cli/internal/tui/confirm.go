package tui

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// confirm is the one way a screen asks before something far-reaching:
// enter does it, esc leaves it, and every other key is ignored, so a stray
// press while you read the question changes nothing.
type confirm struct {
	prompt string // what will happen, and the question
	verb   string // what enter does, in the hint
	what   string // which action this asks about; the screen dispatches on it
	target string // what the action applies to
	failed bool   // the last attempt failed, so enter retries
}

func (c confirm) asking() bool { return c.prompt != "" }

func (c *confirm) ask(what, target, verb, prompt string) {
	*c = confirm{prompt: prompt, verb: verb, what: what, target: target}
}

func (c *confirm) dismiss() { *c = confirm{} }

// key settles a key press while asking: yes on enter, dismissed on esc,
// and ignored otherwise. It reports whether the key was for the question.
func (c *confirm) key(msg tea.KeyPressMsg) (yes bool) {
	switch msg.String() {
	case "enter":
		return true
	case "esc", "ctrl+c":
		c.dismiss()
	}
	return false
}

// footer is the question, the last failure if there was one, and the keys.
func (c confirm) footer(width int, failure string) string {
	var rows []string
	for line := range strings.SplitSeq(ansi.Wrap(c.prompt, max(1, width-1), " "), "\n") {
		rows = append(rows, " "+DefaultStyles.Warning.Render(line))
	}
	if failure != "" {
		rows = append(rows, " "+DefaultStyles.Error.Render(ansi.Truncate(failure, max(1, width-1), "…")))
	}
	verb := c.verb
	if c.failed || failure != "" {
		verb = "retry"
	}
	return strings.Join(append(rows, " "+keyHints(hint{"enter", verb}, hint{"esc", "cancel"})), "\n")
}
