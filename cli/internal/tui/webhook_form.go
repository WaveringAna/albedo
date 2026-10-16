package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"regexp"
	"strings"

	tea "charm.land/bubbletea/v2"
)

// webhookForm adds a hook or edits one on a single screen: the session it
// wakes, its name, signing secret, and the header and prefix its sender signs
// with. The session and name are fixed once the hook exists.
type webhookForm struct {
	form
	// Editing is the hook being edited; nil for a new hook.
	Editing *webhookEntry
	sessionChoice
}

var hookFields = []string{hookFieldSession, hookFieldName, hookFieldSecret, hookFieldHeader, hookFieldPrefix}

func newWebhookForm(editing *webhookEntry, sessions []daemon.Session, current string) *webhookForm {
	f := &webhookForm{form: newForm(hookFields, hookFieldSecret), sessionChoice: sessionChoice{Sessions: sessions, Current: current, Chosen: current}}
	f.Inputs[hookFieldSession].Placeholder = "type to filter"
	f.Inputs[hookFieldName].Placeholder = "github-deploys"
	f.Inputs[hookFieldHeader].SetValue(defaultSignatureHeader)
	f.Inputs[hookFieldPrefix].SetValue(defaultSignaturePrefix)
	f.Inputs[hookFieldSecret].Placeholder = "leave blank to generate one"
	f.Focus = 1 // the session already defaults to this one
	if editing != nil {
		hook := *editing
		f.Editing, f.Chosen, f.Focus = &hook, hook.Session, 2
		f.Inputs[hookFieldName].SetValue(hook.Name)
		f.Inputs[hookFieldHeader].SetValue(hook.Header)
		f.Inputs[hookFieldPrefix].SetValue(hook.Prefix)
		f.Inputs[hookFieldSecret].Placeholder = "stored · leave blank to keep it"
	}
	f.focus(f.current())
	return f
}

func (f *webhookForm) current() string { return hookFields[f.Focus] }

// update handles one key or paste; submit reports that the form should be saved.
func (f *webhookForm) update(msg tea.Msg) (submit bool, cmd tea.Cmd) {
	firstField := 0
	if f.Editing != nil {
		firstField = 2
	}
	if submit, handled := f.key(msg, hookFields, firstField); handled {
		return submit, nil
	}
	query := f.Inputs[hookFieldSession].Value()
	if key, ok := msg.(tea.KeyPressMsg); ok && f.current() == hookFieldSession && f.step(query, key.String()) {
		return false, nil
	}
	input := f.Inputs[f.current()]
	next, cmd := input.Update(msg)
	*input = next
	if f.current() == hookFieldSession {
		f.follow(input.Value())
	}
	return false, cmd
}

// steps validates the form before preparing its webhook mutations.
func (f *webhookForm) steps() ([]daemon.WebhookRequest, string, error) {
	name, secret, header, prefix := f.value(hookFieldName), f.value(hookFieldSecret), f.value(hookFieldHeader), f.value(hookFieldPrefix)
	switch {
	case f.Editing == nil && f.Chosen == "":
		return nil, "", errors.New("choose the session this webhook will wake")
	case f.Editing == nil && !hookName.MatchString(name):
		return nil, "", errors.New("name: 1–64 letters, digits, _ or -")
	case secret != "" && (len(secret) < 16 || len(secret) > 4096):
		if f.Editing != nil {
			return nil, "", errors.New("secret: 16–4096 bytes, or blank to keep it")
		}
		return nil, "", errors.New("secret: 16–4096 bytes, or blank to generate")
	case !hookHeader.MatchString(header):
		return nil, "", errors.New("header: 1–64 letters, digits or -")
	case len(prefix) > 32 || strings.ContainsAny(prefix, "\r\n"):
		return nil, "", errors.New("prefix: at most 32 bytes, no newlines")
	}
	if f.Editing == nil {
		steps := []daemon.WebhookRequest{{Action: daemon.WebhookCreate, SessionID: f.Chosen, Name: name, Secret: secret, Header: header, Prefix: prefix}}
		return steps, "added " + name + " · wakes " + f.label(), nil
	}
	var steps []daemon.WebhookRequest
	if !strings.EqualFold(header, f.Editing.Header) || prefix != f.Editing.Prefix {
		steps = append(steps, daemon.WebhookRequest{Action: daemon.WebhookSignature, HookID: f.Editing.ID, Header: header, Prefix: prefix})
	}
	if secret != "" {
		steps = append(steps, daemon.WebhookRequest{Action: daemon.WebhookRotate, HookID: f.Editing.ID, Secret: secret})
	}
	return steps, "saved " + f.Editing.Name, nil
}

// view is the form's rows; its keys are the footer.
func (f *webhookForm) view(width int) []string {
	title := "add webhook"
	if f.Editing != nil {
		title = "edit " + f.Editing.Name
	}
	f.fit(width - 14)
	rows := []string{DefaultStyles.Bold.Render(title)}
	indent := strings.Repeat(" ", 13)
	for i, key := range hookFields {
		value := f.Inputs[key].View()
		switch {
		case key == hookFieldSession && f.Editing != nil:
			value = DefaultStyles.Faint.Render(f.label())
		case key == hookFieldSession && i != f.Focus:
			value = f.label()
		case key == hookFieldName && f.Editing != nil:
			value = DefaultStyles.Faint.Render(f.Editing.Name)
		}
		rows = append(rows, formRow(i == f.Focus, key, 11, value, width))
		if key == hookFieldSession && i == f.Focus {
			rows = append(rows, f.rows(f.Inputs[hookFieldSession].Value(), indent, width)...)
		}
	}
	return rows
}

// footer explains the focused field and offers the keys every form shares.
func (f *webhookForm) footer(width int) string {
	var own []hint
	var note string
	switch f.current() {
	case hookFieldSession:
		note, own = "which session deliveries wake", []hint{{"←→", "choose"}}
	case hookFieldName:
		note = "letters, digits, _ or -"
	case hookFieldSecret:
		note = "16+ bytes from the sender, or blank to generate one"
		if f.Editing != nil {
			note = "enter a new secret to replace the stored one"
		}
	case hookFieldHeader:
		note = "the header the sender signs with · GitHub uses x-hub-signature-256"
	case hookFieldPrefix:
		note = "text before the hex digest · blank for none"
	}
	keys := append(own, hint{"esc", "cancel"}, hint{"ctrl+s", "save"}, hint{"enter", "next"}, hint{"tab/↑↓", "move"})
	return footerLine(width, keys, DefaultStyles.Faint.Render(note), false)
}

const (
	hookFieldSession = "session"
	hookFieldName    = "name"
	hookFieldSecret  = "secret"
	hookFieldHeader  = "header"
	hookFieldPrefix  = "prefix"
)

var (
	hookName   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	hookHeader = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)
)
