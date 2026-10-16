package tui

import (
	"albedo/cli/internal/daemon"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// configFieldValue is the form's one field.
const configFieldValue = "value"

// configForm edits one declared setting: the value it takes, with what the
// kind accepts and the default that applies while nothing is saved. The
// daemon stays the authority on what a whole section accepts, so a value the
// form cannot tell is wrong is still sent and its refusal shown.
type configForm struct {
	form
	// Section is the name of the section the setting belongs to.
	Section string
	Setting daemon.ExtensionSetting
}

func newConfigForm(section string, setting daemon.ExtensionSetting) *configForm {
	f := &configForm{Section: section, Setting: setting, form: newForm([]string{configFieldValue})}
	f.Inputs[configFieldValue].SetValue(setting.Saved.String())
	f.focus(configFieldValue)
	return f
}

// update handles one key or paste; submit reports that the form should be
// saved.
func (f *configForm) update(msg tea.Msg) (submit bool, cmd tea.Cmd) {
	if submit, handled := f.key(msg, []string{configFieldValue}, 0); handled {
		return submit, nil
	}
	input := f.Inputs[configFieldValue]
	next, cmd := input.Update(msg)
	*input = next
	return false, cmd
}

// value is the field's text without surrounding space.
func (f *configForm) value() string { return f.form.value(configFieldValue) }

// problem is what the typed text does not satisfy, or empty when the form
// cannot tell better. Text counts its bytes because that is what the daemon
// limits.
func (f *configForm) problem() string {
	text := f.value()
	if f.Setting.Kind == daemon.SettingText {
		switch {
		case text == "":
			return "enter a value"
		case len(text) > daemon.SettingTextLimit:
			return fmt.Sprintf("at most %d bytes; this is %d", daemon.SettingTextLimit, len(text))
		}
		return ""
	}
	number, err := strconv.ParseInt(text, 10, 64)
	if err == nil && (f.withinRange(number) || f.Setting.Kind == daemon.SettingLimit && number == daemon.SettingNoLimit) {
		return ""
	}
	return "enter " + configRule(f.Setting)
}

func (f *configForm) withinRange(number int64) bool {
	if f.Setting.Minimum != nil && number < *f.Setting.Minimum {
		return false
	}
	return f.Setting.Maximum == nil || number <= *f.Setting.Maximum
}

// encoded is the value to save: the text itself for a text setting, a whole
// number for an integer or limit one. It refuses what the form can already
// tell is wrong, so a typo never reaches the daemon.
func (f *configForm) encoded() (json.RawMessage, error) {
	if problem := f.problem(); problem != "" {
		return nil, errors.New(problem)
	}
	if f.Setting.Kind == daemon.SettingText {
		return json.Marshal(f.value())
	}
	number, _ := strconv.ParseInt(f.value(), 10, 64)
	return json.Marshal(number)
}

// view is the form's rows; footer is its keys, shown in the screen's footer.
func (f *configForm) view(width int) []string {
	// The label column is fixed and the value takes what is left, so a long
	// declared label is cut here instead of pushing the row past the frame.
	const labelWidth = 16
	f.fit(width - labelWidth - 3)
	rows := []string{DefaultStyles.Bold.Render("edit " + f.Section + " · " + f.Setting.Key)}
	label := ansi.Truncate(f.Setting.Label, labelWidth-1, "…")
	rows = append(rows, formRow(true, label, labelWidth, f.Inputs[configFieldValue].View(), width))
	return append(rows, DefaultStyles.Faint.Render(configContext(f.Setting)))
}

// configContext is the line under the value field: what applies while nothing
// is saved, and what the kind accepts.
func configContext(setting daemon.ExtensionSetting) string {
	return "default " + configDefault(setting) + " · " + configRule(setting)
}

// configRule says what the setting accepts, as the end of a sentence.
func configRule(setting daemon.ExtensionSetting) string {
	if setting.Kind == daemon.SettingText {
		return fmt.Sprintf("text of at most %d bytes", daemon.SettingTextLimit)
	}
	rule := "a whole number"
	if setting.Minimum != nil && setting.Maximum != nil {
		rule = fmt.Sprintf("a whole number from %d to %d", *setting.Minimum, *setting.Maximum)
	}
	if setting.Kind == daemon.SettingLimit {
		rule += fmt.Sprintf(", or %d for no limit", daemon.SettingNoLimit)
	}
	return rule
}

// configValue renders a set value as a reader sees it: a limit's no-limit
// value reads as unlimited.
func configValue(setting daemon.ExtensionSetting, value daemon.SettingValue) string {
	if setting.Kind == daemon.SettingLimit && value.Number != nil && *value.Number == daemon.SettingNoLimit {
		return "unlimited"
	}
	return value.String()
}

// configDefault names what applies while nothing is saved; the description
// says what leaving an unset setting alone means.
func configDefault(setting daemon.ExtensionSetting) string {
	if !setting.Default.Set() {
		return "unset"
	}
	return configValue(setting, setting.Default)
}

// configSaved names the saved value, or that there is none.
func configSaved(setting daemon.ExtensionSetting) string {
	if !setting.Saved.Set() {
		return "not saved"
	}
	return configValue(setting, setting.Saved)
}
