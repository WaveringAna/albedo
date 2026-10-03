package tui

import (
	"cmp"
	"fmt"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

func (m WebhooksPageModel) View() string {
	width := max(1, m.Width)
	rows := m.header("/webhooks", "all sessions")
	if m.Loading && !m.Loaded {
		rows = append(rows, DefaultStyles.Faint.Render("loading webhooks…"))
		return strings.Join(rows, "\n")
	}
	if !m.Loaded {
		return strings.Join(append(rows, "", keyHints(hint{"r", "retry"}, hint{"esc", "back"})), "\n")
	}
	// Give the confirmation the screen instead of truncating its consequence or target.
	if m.Confirm != "" && m.selected() != nil {
		question := "Its URL will stop working; accepted deliveries stay in the inbox. Delete " + m.selected().Name + "?"
		if m.Confirm == "rotate" {
			question = "The sender must use the new secret. Replace the secret for " + m.selected().Name + "?"
		}
		rows = append(rows, "")
		for line := range strings.SplitSeq(ansi.Wrap(question, width, " "), "\n") {
			rows = append(rows, DefaultStyles.Warning.Render(line))
		}
		rows = append(rows, keyHints(hint{"enter", "confirm"}, hint{"any other key", "cancels"}))
		return m.fit(rows)
	}
	if !m.Mounted {
		rows = append(rows, DefaultStyles.Warning.Render("Webhooks are not listening")+DefaultStyles.Faint.Render(" · enable webhooks globally in /extensions to accept deliveries"))
	}
	agent := DefaultStyles.Faint.Render("off") + DefaultStyles.Faint.Render(" · this session's agent can't touch webhooks")
	if m.AgentManagement {
		agent = DefaultStyles.Success.Render("on ") + DefaultStyles.Faint.Render(" · this session's agent can add, rotate and delete its own hooks")
	}
	rows = append(rows, ansi.Truncate(DefaultStyles.Muted.Render("agent access ")+agent, width, "…"), "")

	if len(m.Hooks) == 0 {
		rows = append(rows, DefaultStyles.Faint.Render("No webhooks yet. Add one to wake a session with a signed request."))
	}
	nameWidth := 4
	for _, hook := range m.Hooks {
		nameWidth = max(nameWidth, ansi.StringWidth(hook.Name))
	}
	// Hooks sit under the session they wake; the cursor line is kept in view.
	counts := map[string]int{}
	for _, hook := range m.Hooks {
		counts[hook.Session]++
	}
	var list []string
	cursorLine := 0
	for i, hook := range m.Hooks {
		if i == 0 || hook.Session != m.Hooks[i-1].Session {
			if i > 0 {
				list = append(list, "")
			}
			list = append(list, sectionRule(ansi.Truncate(sessionLabel(m.Sessions, hook.Session, m.SessionID), max(8, width-12), "…"), counts[hook.Session], width))
		}
		var label string
		if hook.Enabled {
			label = DefaultStyles.Success.Render("on ")
		} else {
			label = DefaultStyles.Faint.Render("off")
		}
		row := label + "  " + padRight(hook.Name, nameWidth+1) + DefaultStyles.Faint.Render(hook.URL)
		if hook.Queued > 0 {
			row += DefaultStyles.Decor.Render(" · ") + DefaultStyles.Warning.Render(fmt.Sprintf("%d queued", hook.Queued))
		}
		if i == m.Cursor {
			cursorLine = len(list)
		}
		list = append(list, listRow(i == m.Cursor, row, width))
	}
	rows = append(rows, scrolled(list, cursorLine, max(2, m.Height-17))...)

	switch {
	case m.Reveal != nil:
		rows = append(rows, "", ansi.Truncate(DefaultStyles.Bold.Render("signing secret for "+m.Reveal.Hook)+DefaultStyles.Faint.Render(" → "+sessionLabel(m.Sessions, m.Reveal.Session, m.SessionID)+" · shown only once; copy it now"), width, "…"))
		rows = append(rows, "  "+DefaultStyles.Prompt.Render(m.Reveal.Secret), "")
		rows = append(rows, keyHints(hint{"c", "copy"}, hint{"enter", "done"}))
	case m.Form != nil:
		rows = append(rows, "")
		rows = append(rows, m.Form.view(width)...)
		if m.Saving {
			rows = append(rows, DefaultStyles.Faint.Render("saving…"))
		}
	case m.Saving:
		rows = append(rows, "", DefaultStyles.Faint.Render("saving…"))
	default:
		if hook := m.selected(); hook != nil {
			rows = append(rows, "")
			rows = append(rows, m.detail(*hook, width)...)
		}
		browse := []hint{{"r", "refresh"}, {"esc", "back"}}
		keys := []hint{{"n", "add hook"}, {"a", "agent access"}}
		if len(m.Hooks) > 0 {
			browse = []hint{{"↑↓", "select"}, {"space", "on/off"}, {"y", "copy url"}, {"r", "refresh"}, {"esc", "back"}}
			keys = []hint{{"n", "add hook"}, {"enter", "edit"}, {"k", "new secret"}, {"d", "delete"}, {"a", "agent access"}}
		}
		rows = append(rows, "", keyHints(browse...), keyHints(keys...))
	}
	return m.fit(rows)
}

// detail explains the selected hook: where to send, how to sign, and what is
// waiting for the session.
func (m WebhooksPageModel) detail(hook webhookEntry, width int) []string {
	field := func(label, value string) string {
		return ansi.Truncate(DefaultStyles.Muted.Render(padRight(label, 11))+value, width, "…")
	}
	rows := []string{
		field("wakes", sessionLabel(m.Sessions, hook.Session, m.SessionID)),
		field("url", "POST "+cmp.Or(hook.Address, hook.URL)),
		field("signature", hook.Header+": "+hook.Prefix+DefaultStyles.Faint.Render("<hex HMAC-SHA256 of the body>")),
	}
	inbox := DefaultStyles.Faint.Render("empty")
	if hook.Queued > 0 {
		inbox = DefaultStyles.Warning.Render(fmt.Sprintf("%d waiting for the session", hook.Queued))
		if hook.Deferred != "" {
			inbox += DefaultStyles.Faint.Render(" · last attempt: " + hook.Deferred)
		}
	}
	if !hook.Enabled {
		inbox += DefaultStyles.Faint.Render(" · off, new deliveries answer 404")
	}
	return append(rows, field("inbox", inbox))
}
