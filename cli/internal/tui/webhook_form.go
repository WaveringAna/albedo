package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// webhookForm adds a hook or edits one on a single screen: the session it
// wakes, its name, signing secret, and the header and prefix its sender signs
// with. The session and name are fixed once the hook exists.
type webhookForm struct {
	form
	// Editing is the hook being edited; nil for a new hook.
	Editing         *webhookEntry
	Current, Chosen string
	// Sessions are offered in order; Chosen starts at Current, the session
	// the screen was opened from.
	Sessions []daemon.Session
}

var hookFields = []string{hookFieldSession, hookFieldName, hookFieldSecret, hookFieldHeader, hookFieldPrefix}

func newWebhookForm(editing *webhookEntry, sessions []daemon.Session, current string) *webhookForm {
	f := &webhookForm{form: newForm(hookFields, hookFieldSecret), Sessions: sessions, Current: current, Chosen: current}
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

// matches are the sessions the picker's filter leaves, in order.
func (f *webhookForm) matches() []daemon.Session {
	query := strings.ToLower(strings.TrimSpace(f.Inputs[hookFieldSession].Value()))
	var out []daemon.Session
	for _, s := range f.Sessions {
		if query == "" || strings.Contains(strings.ToLower(sessionTitle(s)+" "+homePath(s.Workspace)+" "+s.ID), query) {
			out = append(out, s)
		}
	}
	return out
}

func (f *webhookForm) chosenIndex(matches []daemon.Session) int {
	return slices.IndexFunc(matches, func(s daemon.Session) bool { return s.ID == f.Chosen })
}

// update handles one key or paste; submit reports that the form should be saved.
func (f *webhookForm) update(msg tea.Msg) (submit bool, cmd tea.Cmd) {
	firstField := 0
	if f.Editing != nil {
		firstField = 2
	}
	if submit, handled := f.key(msg, hookFields, firstField); handled {
		return submit, nil
	}
	if key, ok := msg.(tea.KeyPressMsg); ok {
		if f.current() == hookFieldSession && (key.String() == "left" || key.String() == "right") {
			if matches := f.matches(); len(matches) > 0 {
				i := f.chosenIndex(matches)
				if i < 0 {
					i = 0
				} else {
					step := 1
					if key.String() == "left" {
						step = -1
					}
					i = (i + step + len(matches)) % len(matches)
				}
				f.Chosen = matches[i].ID
				return false, nil
			}
		}
	}
	input := f.Inputs[f.current()]
	next, cmd := input.Update(msg)
	*input = next
	if f.current() == hookFieldSession {
		if matches := f.matches(); len(matches) > 0 && f.chosenIndex(matches) < 0 {
			f.Chosen = matches[0].ID
		}
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
		return nil, "", errors.New("use 1–64 letters, digits, underscores, or hyphens for the webhook name")
	case secret != "" && (len(secret) < 16 || len(secret) > 4096):
		if f.Editing != nil {
			return nil, "", errors.New("use 16–4096 bytes for the secret, or leave it blank to keep the existing secret")
		}
		return nil, "", errors.New("use 16–4096 bytes for the secret, or leave it blank to generate one")
	case !hookHeader.MatchString(header):
		return nil, "", errors.New("use 1–64 letters, digits, or hyphens for the signature header")
	case len(prefix) > 32 || strings.ContainsAny(prefix, "\r\n"):
		return nil, "", errors.New("use at most 32 bytes without newlines for the signature prefix")
	}
	if f.Editing == nil {
		steps := []daemon.WebhookRequest{{Action: daemon.WebhookCreate, SessionID: f.Chosen, Name: name, Secret: secret, Header: header, Prefix: prefix}}
		return steps, "added " + name + " · wakes " + sessionLabel(f.Sessions, f.Chosen, f.Current), nil
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
			value = DefaultStyles.Faint.Render(sessionLabel(f.Sessions, f.Chosen, f.Current))
		case key == hookFieldSession && i != f.Focus:
			value = sessionLabel(f.Sessions, f.Chosen, f.Current)
		case key == hookFieldName && f.Editing != nil:
			value = DefaultStyles.Faint.Render(f.Editing.Name)
		}
		rows = append(rows, formRow(i == f.Focus, key, 11, value, width))
		if key == hookFieldSession && i == f.Focus {
			rows = append(rows, f.pickerRows(indent, width)...)
		}
	}
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
	return append(rows, "", formFooter(note, width, own...))
}

// pickerRows lists the matching sessions around the chosen one.
func (f *webhookForm) pickerRows(indent string, width int) []string {
	matches := f.matches()
	if len(matches) == 0 {
		return []string{indent + DefaultStyles.Faint.Render("No sessions match. Try another search.")}
	}
	chosen := max(0, f.chosenIndex(matches))
	start := max(0, min(chosen-sessionChoices/2, len(matches)-sessionChoices))
	var rows []string
	w := width - len(indent)
	for i := start; i < min(len(matches), start+sessionChoices); i++ {
		label := sessionLabel(f.Sessions, matches[i].ID, f.Current)
		if i == chosen {
			rows = append(rows, indent+selectedLine(ansi.Truncate(selectBar()+" "+label, w, "…"), w))
		} else {
			rows = append(rows, indent+DefaultStyles.Faint.Render(ansi.Truncate("  "+label, w, "…")))
		}
	}
	if more := len(matches) - sessionChoices; more > 0 {
		rows = append(rows, indent+DefaultStyles.Faint.Render(fmt.Sprintf("  %d more · type to filter", more)))
	}
	return rows
}

const (
	hookFieldSession = "session"
	hookFieldName    = "name"
	hookFieldSecret  = "secret"
	hookFieldHeader  = "header"
	hookFieldPrefix  = "prefix"
)

// sessionChoices is how many matching sessions the picker shows at once.
const sessionChoices = 5

var (
	hookName   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	hookHeader = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)
)
