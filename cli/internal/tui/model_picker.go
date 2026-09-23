package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strings"

	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
)

type ModelPickerSelectMsg struct {
	Model    string
	Provider string
}

type ModelPickerCancelMsg struct{}

type modelCatalogLoadedMsg struct {
	Provider string
	Models   []string
	Note     string
	Err      error
	Gen      int
}

type ModelPickerModel struct {
	Conn             *daemon.Connection
	Profiles         config.Profiles
	CurrentModel     string
	SessionProvider  string
	SelectedProvider string
	ChoosingProvider bool
	EnteringManual   bool
	LoadingModels    bool
	Saving           bool
	CatalogNote      string
	Error            string
	ModelPicker      PickerModel
	ProviderPicker   PickerModel
	ManualInput      textinput.Model
	Generation       int
	Width            int
	Height           int
	Styles           Styles
}

func NewModelPickerModel(conn *daemon.Connection, profiles config.Profiles, currentModel, currentProvider string) ModelPickerModel {
	provider := currentProvider
	if provider == "" {
		provider = profiles.Active
	}

	ti := textinput.New()
	ti.Cursor.SetMode(cursor.CursorStatic)
	ti.Placeholder = ""
	ti.Prompt = "model id: "

	m := ModelPickerModel{
		Conn:             conn,
		Profiles:         profiles,
		CurrentModel:     currentModel,
		SessionProvider:  provider,
		SelectedProvider: provider,
		LoadingModels:    true,
		ManualInput:      ti,
		Styles:           DefaultStyles,
	}

	m.buildModelPicker(nil)
	return m
}

func (m *ModelPickerModel) SetSize(width, height int) {
	m.Width = width
	m.Height = height
	m.ModelPicker.SetSize(width, height)
	m.ProviderPicker.SetSize(width, height)
	m.ManualInput.Width = max(1, width-10)
}

func (m ModelPickerModel) Init() tea.Cmd {
	return m.fetchModelsCmd(m.SelectedProvider, m.Generation)
}

func (m ModelPickerModel) fetchModelsCmd(provider string, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return modelCatalogLoadedMsg{
				Provider: provider,
				Models:   nil,
				Note:     "daemon connection unavailable; enter a model id manually",
				Gen:      gen,
			}
		}

		settings, ok := m.Profiles.Providers[provider]
		if !ok {
			return modelCatalogLoadedMsg{
				Provider: provider,
				Models:   nil,
				Note:     "provider settings missing; enter a model id manually or check /login",
				Gen:      gen,
			}
		}

		providerExtension := settings.Extension
		if providerExtension == "" {
			providerExtension = "openai"
		}
		endpoint := settings.BaseURL
		if providerExtension == "codex" {
			endpoint = ""
		}

		reqURL := fmt.Sprintf("/models/%s?endpoint=%s", providerExtension, url.QueryEscape(endpoint))
		names, err := daemon.Request[[]string](context.Background(), m.Conn, reqURL, nil)
		if err != nil {
			return modelCatalogLoadedMsg{
				Provider: provider,
				Models:   nil,
				Note:     "could not list models for this provider; enter a model id manually or check /login",
				Err:      err,
				Gen:      gen,
			}
		}

		var note string
		if len(names) == 0 {
			note = "no models listed; enter a model id manually"
		}

		return modelCatalogLoadedMsg{
			Provider: provider,
			Models:   names,
			Note:     note,
			Gen:      gen,
		}
	}
}

func (m *ModelPickerModel) buildProviderPicker() {
	var items []PickerItem
	var names []string
	for name := range m.Profiles.Providers {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		settings := m.Profiles.Providers[name]
		detail := settings.Protocol
		if name == m.SessionProvider {
			detail += " · current"
		}
		items = append(items, PickerItem{
			ID:     name,
			Label:  name,
			Detail: detail,
		})
	}

	m.ProviderPicker = NewPickerModel("session provider", items, true, m.SelectedProvider)
	m.ProviderPicker.SetSize(m.Width, m.Height)
}

func (m *ModelPickerModel) buildModelPicker(catalog []string) {
	initial := ""
	if m.SelectedProvider == m.SessionProvider {
		initial = m.CurrentModel
	}
	if initial == "" {
		if settings, ok := m.Profiles.Providers[m.SelectedProvider]; ok {
			initial = settings.Model
		}
	}

	seen := make(map[string]bool)
	var models []string
	if initial != "" {
		seen[initial] = true
		models = append(models, initial)
	}
	for _, name := range catalog {
		if !seen[name] && name != "" {
			seen[name] = true
			models = append(models, name)
		}
	}

	var items []PickerItem
	items = append(items, PickerItem{
		ID:     "provider",
		Label:  "change provider",
		Detail: m.SelectedProvider,
	})

	for _, model := range models {
		detail := ""
		if model == m.CurrentModel && m.SelectedProvider == m.SessionProvider {
			detail = "current"
		}
		items = append(items, PickerItem{
			ID:     "model:" + model,
			Label:  model,
			Detail: detail,
		})
	}

	items = append(items, PickerItem{
		ID:     "manual",
		Label:  "enter model id manually",
		Detail: "",
	})

	initialSel := "model:" + initial
	m.ModelPicker = NewPickerModel("session model", items, true, initialSel)
	m.ModelPicker.SetSize(m.Width, m.Height)
}

func validateModelID(m string) error {
	m = strings.TrimSpace(m)
	if m == "" || jsLength(m) > 512 {
		return errors.New("enter a model id of 1–512 characters")
	}
	for _, r := range m {
		if r < 0x20 || r == 0x7f {
			return errors.New("enter a model id of 1–512 characters")
		}
	}
	return nil
}

func (m ModelPickerModel) Update(msg tea.Msg) (ModelPickerModel, tea.Cmd) {
	if m.Saving {
		if _, ok := msg.(tea.KeyMsg); ok {
			return m, nil
		}
	}
	switch msg := msg.(type) {
	case modelCatalogLoadedMsg:
		if msg.Gen != m.Generation || msg.Provider != m.SelectedProvider {
			return m, nil
		}
		m.LoadingModels = false
		m.CatalogNote = msg.Note
		m.buildModelPicker(msg.Models)
		return m, m.ModelPicker.Init()

	case tea.KeyMsg:
		if m.EnteringManual {
			switch msg.Type {
			case tea.KeyEsc, tea.KeyCtrlC, tea.KeyCtrlD:
				return m, func() tea.Msg { return ModelPickerCancelMsg{} }
			case tea.KeyEnter:
				val := strings.TrimSpace(m.ManualInput.Value())
				if err := validateModelID(val); err != nil {
					m.Error = err.Error()
					return m, nil
				}
				m.Error = ""
				return m, func() tea.Msg {
					return ModelPickerSelectMsg{
						Model:    val,
						Provider: m.SelectedProvider,
					}
				}
			}
			var cmd tea.Cmd
			m.ManualInput, cmd = m.ManualInput.Update(msg)
			return m, cmd
		}

		if msg.Type == tea.KeyCtrlC || msg.Type == tea.KeyCtrlD {
			return m, func() tea.Msg { return ModelPickerCancelMsg{} }
		}

	case PickerSelectMsg:
		if m.ChoosingProvider {
			m.SelectedProvider = msg.ID
			m.ChoosingProvider = false
			m.LoadingModels = true
			m.CatalogNote = ""
			m.buildModelPicker(nil)
			m.Error = ""
			m.Generation++
			return m, m.fetchModelsCmd(m.SelectedProvider, m.Generation)
		}

		switch {
		case msg.ID == "provider":
			m.ChoosingProvider = true
			m.buildProviderPicker()
			return m, m.ProviderPicker.Init()

		case msg.ID == "manual":
			m.EnteringManual = true
			m.ManualInput.Reset()
			initial := ""
			if m.SelectedProvider == m.SessionProvider {
				initial = m.CurrentModel
			}
			if initial == "" {
				if settings, ok := m.Profiles.Providers[m.SelectedProvider]; ok {
					initial = settings.Model
				}
			}
			m.ManualInput.SetValue(initial)
			m.ManualInput.Focus()
			m.Error = ""
			return m, textinput.Blink

		case strings.HasPrefix(msg.ID, "model:"):
			modelName := strings.TrimPrefix(msg.ID, "model:")
			if err := validateModelID(modelName); err != nil {
				m.Error = err.Error()
				return m, nil
			}
			m.Error = ""
			return m, func() tea.Msg {
				return ModelPickerSelectMsg{
					Model:    modelName,
					Provider: m.SelectedProvider,
				}
			}
		}

	case PickerCancelMsg:
		if m.ChoosingProvider {
			m.ChoosingProvider = false
			return m, nil
		}
		return m, func() tea.Msg { return ModelPickerCancelMsg{} }
	}

	var cmd tea.Cmd
	if m.ChoosingProvider {
		m.ProviderPicker, cmd = m.ProviderPicker.Update(msg)
	} else if !m.EnteringManual {
		m.ModelPicker, cmd = m.ModelPicker.Update(msg)
	}
	return m, cmd
}

func (m ModelPickerModel) View() string {
	var b strings.Builder

	titleProvider := m.SelectedProvider
	if titleProvider == "" {
		titleProvider = "session provider"
	}
	b.WriteString(fmt.Sprintf("albedo /model · %s", titleProvider))
	b.WriteString("\n")
	b.WriteString(m.Styles.Dim.Render(inkWrap("changes this idle session and the default for new sessions", m.Width)))
	b.WriteByte('\n')

	if m.Error != "" {
		b.WriteString(inkRed.Render(m.Error))
		b.WriteByte('\n')
	}

	if m.Saving {
		b.WriteString(m.Styles.Dim.Render("switching model…"))
		return b.String()
	}

	if m.ChoosingProvider {
		b.WriteString(m.ProviderPicker.View())
		return b.String()
	}

	if m.EnteringManual {
		b.WriteString(m.ManualInput.View())
		b.WriteByte('\n')
		b.WriteString(m.Styles.Dim.Render("enter choose · esc cancel"))
		return b.String()
	}

	if m.LoadingModels {
		b.WriteString(m.Styles.Dim.Render("loading models…"))
		b.WriteByte('\n')
	}

	if m.CatalogNote != "" {
		b.WriteString(m.Styles.Dim.Render(inkWrap(m.CatalogNote, m.Width)))
		b.WriteByte('\n')
	}

	b.WriteString(m.ModelPicker.View())
	return b.String()
}
