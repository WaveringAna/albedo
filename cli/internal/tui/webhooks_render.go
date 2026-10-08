package tui

import (
	"cmp"
	"fmt"
)

// View draws the list beside the highlighted hook's detail. The form and the
// secret shown once take the list's place, and a question takes the footer.
func (m WebhooksPageModel) View() string {
	lv := m.listView
	lv.Empty = "No webhooks yet. Add one to wake a session with a signed request."
	switch {
	case m.Loading:
		lv.Empty = "loading webhooks…"
	case !m.Loaded:
		lv.Empty = "webhooks did not load"
	}
	frame := lv.frame(brand("albedo")+" "+DefaultStyles.Muted.Render("/webhooks"), DefaultStyles.Faint.Render("all sessions"), m.footer(max(1, m.Width)))
	switch {
	case m.Reveal != nil:
		frame.filter, frame.pane, frame.list = "", nil, m.revealRows
	case m.Form != nil:
		frame.filter, frame.pane, frame.list = "", nil, m.formRows
	}
	return frame.view(m.Width, m.Height)
}

// footer is the keys for what is open and one status: a failure, a notice,
// work in flight, or what the hooks are doing.
func (m WebhooksPageModel) footer(width int) string {
	switch {
	case m.Reveal != nil:
		status, urgent := m.status()
		return footerLine(width, []hint{{"ctrl+l", "copy"}, {"enter", "done"}}, status, urgent)
	case m.Form != nil:
		return m.formFooter(width)
	case m.confirm.asking():
		return m.confirm.footer(width, m.Error)
	}
	status, urgent := m.status()
	return footerLine(width, m.browseHints(), status, urgent)
}

// status is the footer's state beside the keys. An urgent status takes a row
// of its own when the keys do not leave room for it.
func (m WebhooksPageModel) status() (string, bool) {
	switch {
	case m.Error != "":
		return DefaultStyles.Error.Render(m.Error), true
	case m.Saving:
		return DefaultStyles.Busy.Render("saving…"), true
	case m.Loading:
		return DefaultStyles.Faint.Render("loading…"), false
	case m.Notice != "":
		return DefaultStyles.Warning.Render(m.Notice), true
	case !m.Mounted:
		return DefaultStyles.Warning.Render("Webhooks are not listening · enable them in /extensions"), true
	}
	return "", false
}

// browseHints keeps the main hook action and session agent access visible first.
func (m WebhooksPageModel) browseHints() []hint {
	if !m.Loaded {
		return []hint{{"ctrl+r", "retry"}, {"esc", "back"}}
	}
	_, selected := m.current()
	var hints []hint
	if selected {
		hints = append(hints, hint{"enter", "on/off"})
	}
	hints = append(hints, hint{"ctrl+t", "agent access " + onOff(m.AgentManagement)}, hint{"ctrl+o", "add hook"})
	if selected {
		hints = append(hints, hint{"ctrl+e", "edit"}, hint{"ctrl+d", "delete"}, hint{"ctrl+g", "new secret"}, hint{"ctrl+l", "copy url"})
	}
	return append(hints, hint{"ctrl+r", "refresh"}, hint{"esc", "back"})
}

// formFooter is the form's keys, with a failure or the save in flight above them.
func (m WebhooksPageModel) formFooter(width int) string {
	line := m.Form.footer(width)
	switch {
	case m.Error != "":
		return footerLine(width, nil, DefaultStyles.Error.Render(m.Error), true) + "\n" + line
	case m.Saving:
		return footerLine(width, nil, DefaultStyles.Busy.Render("saving…"), true) + "\n" + line
	}
	return line
}

// formRows is the form in the list's place, scrolled to keep its focused field in view.
func (m WebhooksPageModel) formRows(width, height int) []string {
	return scrolled(m.Form.view(width), 1+m.Form.Focus, height)
}

// revealRows is the generated secret, shown once, in the list's place. Its
// session and warning sit on rows of their own so a narrow terminal keeps them.
func (m WebhooksPageModel) revealRows(_, _ int) []string {
	r := m.Reveal
	return []string{
		DefaultStyles.Bold.Render("signing secret for " + r.Hook),
		DefaultStyles.Faint.Render("→ " + sessionLabel(m.Sessions, r.Session, m.SessionID)),
		DefaultStyles.Warning.Render("shown only once; copy it now"),
		"",
		"  " + DefaultStyles.Prompt.Render(r.Secret),
	}
}

// entry is how a hook reads in the list: its state in front, its URL under
// its name, and the deliveries waiting for its session at the edge.
func (m WebhooksPageModel) entry(hook webhookEntry) listEntry {
	lead, tag := DefaultStyles.Faint.Render("off"), ""
	if hook.Enabled {
		lead = DefaultStyles.Success.Render("on")
	}
	if hook.Queued > 0 {
		tag = DefaultStyles.Warning.Render(fmt.Sprintf("%d queued", hook.Queued))
	}
	section := sessionLabel(m.Sessions, hook.Session, m.SessionID)
	return listEntry{
		key:     hook.ID,
		section: section,
		lead:    lead,
		name:    hook.Name,
		desc:    hook.URL,
		tag:     tag,
		search:  []string{section},
		detail:  func(width int) []string { return m.details(hook, width) },
	}
}

// details is the pane: the state, where deliveries go, how they are signed,
// and what is waiting for the session.
func (m WebhooksPageModel) details(hook webhookEntry, width int) []string {
	state := "off · new deliveries answer 404"
	if hook.Enabled {
		state = "on · accepting signed deliveries"
	}
	lines := paneTitle(hook.Name, state, width)
	lines = append(lines, factRows("wakes", sessionLabel(m.Sessions, hook.Session, m.SessionID), width)...)
	lines = append(lines, factRows("url", "POST "+cmp.Or(hook.Address, hook.URL), width)...)
	lines = append(lines, factRows("signature", hook.Header+": "+hook.Prefix+"<hex HMAC-SHA256 of the body>", width)...)
	lines = append(lines, factRows("secret", "stored · ctrl+g makes a new one", width)...)
	inbox := "empty"
	if hook.Queued > 0 {
		inbox = fmt.Sprintf("%d waiting for the session", hook.Queued)
		if hook.Deferred != "" {
			inbox += " · last attempt: " + hook.Deferred
		}
	}
	return append(lines, factRows("inbox", inbox, width)...)
}

// scrolled is the window of rows lines that keeps line at in view.
func scrolled(lines []string, at, rows int) []string {
	start := max(0, at-rows+1)
	return lines[start:min(len(lines), start+rows)]
}
