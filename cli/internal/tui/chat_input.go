package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"slices"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

func (m *ChatModel) handleInput(msg tea.Msg) (tea.Cmd, bool) {
	if cmd, handled := m.handleTerminalClipboard(msg); handled {
		return cmd, true
	}
	var cmds []tea.Cmd
	switch msg := msg.(type) {
	case tea.KeyPressMsg:
		// The selector owns keys while open, before chat navigation or composer input.
		if len(m.effortOptions) > 0 {
			switch msg.String() {
			case "left", "up":
				m.effortSelected = max(0, m.effortSelected-1)
			case "right", "down":
				m.effortSelected = min(len(m.effortOptions)-1, m.effortSelected+1)
			case "enter", "esc":
				level := m.effortOptions[m.effortSelected]
				m.effortOptions = nil
				m.syncLayout()
				if msg.String() == "enter" {
					return func() tea.Msg { return ChatExecuteCommandMsg{Name: "/effort", Args: level} }, true
				}
			case "ctrl+c":
				m.Close()
				return func() tea.Msg { return ChatQuitMsg{} }, true
			}
			return nil, true
		}

		if msg.String() == "left" && m.TextArea.Value() == "" {
			return func() tea.Msg { return ChatBackToSessionsMsg{} }, true
		}

		if msg.String() == "ctrl+c" || (msg.String() == "ctrl+d" && m.TextArea.Focused() && m.TextArea.Value() == "") {
			m.Close()
			return func() tea.Msg { return ChatQuitMsg{} }, true
		}
		if msg.String() == "ctrl+n" {
			return func() tea.Msg { return ChatNewSessionMsg{} }, true
		}
		if msg.String() == "ctrl+o" {
			return func() tea.Msg { return ChatOpenAgentsMsg{} }, true
		}
		if msg.String() == "esc" && m.dragAnchor != nil {
			m.dragAnchor, m.dragDir = nil, 0
			return nil, true
		}

		inputVal := m.TextArea.Value()
		consumed := m.CommandMenu.OnKey(
			msg,
			inputVal,
			func(replacement string) {
				m.TextArea.SetValue(replacement)
			},
			func(commandName string) {
				m.handleSubmittedCommand(commandName, &cmds)
			},
		)
		if consumed {
			m.syncLayout()
			return tea.Batch(cmds...), true
		}

		switch msg.String() {
		case "esc":
			if m.isSending {
				m.interruptDeferred = true
				m.Stopping = true
				return nil, true
			}
			if m.Status.Running || len(m.pendingUsers) > 0 {
				m.Stopping = true
				cmds = append(cmds, m.interruptCmd())
				return tea.Batch(cmds...), true
			}
		case "ctrl+v":
			if isRemote() {
				return m.readTerminalClipboard(), true
			}
			return PasteClipboardImageCmd(m.SessionID, m.Generation), true
		case "backspace", "ctrl+h", "ctrl+w", "alt+backspace", "ctrl+backspace":
			if m.deleteMarker(true) {
				return nil, true
			}
		case "delete":
			if m.deleteMarker(false) {
				return nil, true
			}
		case "ctrl+g":
			return m.openEditorCmd(), true
		case "ctrl+l":
			if m.hostAuth != nil && m.hostAuth.here {
				return m.signInCmd(), true
			}
		case "pgup", "pgdown":
			delta := m.Viewport.Height()
			if msg.String() == "pgup" {
				delta = -delta
			}
			m.scrollBy(delta)
			return nil, true
		case "up":
			if m.TextArea.Line() == 0 && m.TextArea.LineInfo().RowOffset == 0 {
				m.scrollBy(-1)
				return nil, true
			}
		case "down":
			if m.TextArea.Line() >= m.TextArea.LineCount()-1 && m.TextArea.LineInfo().RowOffset >= m.TextArea.LineInfo().Height-1 {
				m.scrollBy(1)
				return nil, true
			}
		case "shift+up", "shift+down":
			m.jumpToYou(msg.String() == "shift+up")
			return nil, true
		case "ctrl+home", "ctrl+end":
			m.Follow = msg.String() == "ctrl+end"
			if !m.Follow {
				m.scrollOffset = 0
			}
			m.refreshViewportContent()
			return nil, true
		case "ctrl+j", "ctrl+k":
			if msg.String() == "ctrl+j" {
				m.Flags.Diffs = !m.Flags.Diffs
			} else {
				m.Flags.Compaction = !m.Flags.Compaction
			}
			m.rebuildSettledLines()
			m.refreshViewportContent()
			return nil, true
		case "ctrl+left":
			// Bubbles wordLeft never terminates when everything before the cursor
			// is whitespace. Move to the input start directly in that case.
			if m.wordBackwardAtStart() {
				var cmd tea.Cmd
				m.TextArea, cmd = m.TextArea.Update(tea.KeyPressMsg{Code: tea.KeyHome, Mod: tea.ModCtrl})
				return cmd, true
			}
		case "enter":
			trimmed := strings.TrimSpace(m.TextArea.Value())
			// a draft typed while connecting waits in the composer
			if m.connecting() && (!strings.HasPrefix(trimmed, "/") || !m.isRecognizedCommand(trimmed)) {
				return nil, true
			}
			if trimmed != "" {
				m.TextArea.Reset()
				m.syncLayout()
				m.submitInput(trimmed, &cmds)
				return tea.Batch(cmds...), true
			}
			return nil, true
		}
	case dragScrollMsg:
		cmd := m.dragScrolled(msg)
		return cmd, true
	case tea.MouseMsg:
		firstRow := 2 + m.Notices.ChromeRows()
		mouse := msg.Mouse()
		point := func() Point {
			screen := max(0, min(m.Viewport.Height()-1, mouse.Y-firstRow))
			return Point{Row: m.scrollOffset + screen, Col: max(0, min(m.Viewport.Width(), mouse.X-m.padding()))}
		}
		switch msg := msg.(type) {
		case tea.MouseReleaseMsg:
			if m.dragAnchor == nil {
				return nil, true
			}
			m.dragHead = point()
			sel := Selection{Anchor: *m.dragAnchor, Head: m.dragHead, Gutter: railWidth}
			m.dragAnchor, m.dragDir = nil, 0
			if sel.IsEmpty() {
				cmd := m.actAt(sel.Head.Row)
				return cmd, true
			}
			if text := SelectedText(m.frameLines, sel); text != "" {
				cmd := m.copied(text)
				return cmd, true
			}
		case tea.MouseMotionMsg:
			if m.dragAnchor != nil {
				m.dragHead = point()
				cmd := m.steerDragScroll(mouse.Y - firstRow)
				return cmd, true
			}
		case tea.MouseClickMsg:
			if msg.Button == tea.MouseLeft && mouse.Y >= firstRow && mouse.Y < firstRow+m.Viewport.Height() {
				pt := point()
				m.dragAnchor = &pt
				m.dragHead = pt
			}
		case tea.MouseWheelMsg:
			switch msg.Button {
			case tea.MouseWheelUp:
				m.scrollBy(-3)
			case tea.MouseWheelDown:
				m.scrollBy(3)
			}
			if m.dragAnchor != nil {
				m.dragHead = point()
			}
		}
		return nil, true
	case tea.PasteMsg:
		text := strings.ReplaceAll(msg.Content, "\r\n", "\n")
		if !collapses(text) {
			return nil, false
		}
		m.TextArea.InsertString(m.Pastes.add(text))
		m.syncLayout()
		return nil, true
	case ClipboardImagePastedMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return nil, true
		}
		switch {
		case msg.Err != nil:
			m.AddError(fmt.Sprintf("Could not paste the image: %v", msg.Err))
		case msg.Image == nil:
		case len(m.Images.referenced(m.TextArea.Value())) >= MaxPromptImages:
			m.AddError(fmt.Sprintf("A prompt can attach at most %d images.", MaxPromptImages))
		default:
			m.TextArea.InsertString(m.Images.add(pastedImage{*msg.Image, msg.thumb}))
			m.CopyStatus = msg.hint
			m.syncLayout()
			if msg.transmit != "" {
				return tea.Raw(msg.transmit), true
			}
		}
		return nil, true
	case ChatEditorFinishedMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return nil, true
		}
		if msg.Edited {
			m.TextArea.SetValue(strings.TrimRight(msg.Text, "\r\n"))
			m.syncLayout()
		}
		if msg.Err != nil {
			m.AddError("Could not finish editing the prompt: " + msg.Err.Error())
		}
		return nil, true
	default:
		return nil, false
	}
	return m.updateComposer(msg, cmds), true
}

func (m *ChatModel) updateComposer(msg tea.Msg, cmds []tea.Cmd) tea.Cmd {
	oldRows := m.inputRows()
	var taCmd tea.Cmd
	m.TextArea, taCmd = m.TextArea.Update(msg)
	if m.inputRows() != oldRows {
		m.syncLayout()
	}
	cmds = append(cmds, taCmd)

	return tea.Batch(cmds...)
}

// deleteMarker removes the whole image or paste marker that a deletion at
// the cursor would cut into, reporting whether there was one.
func (m *ChatModel) deleteMarker(backward bool) bool {
	lines := strings.Split(m.TextArea.Value(), "\n")
	row := m.TextArea.Line()
	if row >= len(lines) {
		return false
	}
	start, end, ok := markerSpan([]rune(lines[row]), m.TextArea.Column(), backward)
	if !ok {
		return false
	}
	m.TextArea.SetCursorColumn(end)
	for range end - start {
		m.TextArea, _ = m.TextArea.Update(tea.KeyPressMsg{Code: tea.KeyBackspace})
	}
	m.syncLayout()
	return true
}

// wordBackwardAtStart reports whether the prompt has no word before its cursor.
// The textarea's word-backward handler loops indefinitely in this case.
func (m ChatModel) wordBackwardAtStart() bool {
	lines := strings.Split(m.TextArea.Value(), "\n")
	row := m.TextArea.Line()
	if row < 0 || row >= len(lines) {
		return false
	}
	if slices.ContainsFunc(lines[:row], func(line string) bool { return strings.TrimSpace(line) != "" }) {
		return false
	}
	col := m.TextArea.LineInfo().StartColumn + m.TextArea.LineInfo().ColumnOffset
	current := []rune(lines[row])
	col = max(0, min(col, len(current)))
	return strings.TrimSpace(string(current[:col])) == ""
}

func (m *ChatModel) isRecognizedCommand(input string) bool {
	trimmed := strings.TrimSpace(input)
	if !strings.HasPrefix(trimmed, "/") {
		return false
	}
	fields := strings.Fields(trimmed)
	token, typed := fields[0], len(fields) > 1
	switch token {
	case "/a", "/agents", "/sessions", "/q", "/quit", "/exit", "/new", "/model", "/extensions",
		"/plugins", "/tree", "/context", "/t", "/thinking", "/v", "/verbose",
		"/status", "/login", "/mouse", "/skills", "/instructions", "/mcp", "/cd", "/effort", "/compact", "/kernel", "/reload",
		"/work", "/paperclips":
		return true
	}
	// Text after a command that declares no arguments is a prompt that
	// happens to start with the command's name.
	return slices.ContainsFunc(m.CommandMenu.Catalog, func(cmd daemon.SessionCommand) bool {
		return cmd.Name == token && (!typed || len(cmd.Arguments) > 0)
	})
}

func (m *ChatModel) submitInput(input string, cmds *[]tea.Cmd) {
	if strings.HasPrefix(input, "/") && m.isRecognizedCommand(input) {
		m.handleSubmittedCommand(input, cmds)
		return
	}

	if m.pendingSendCount() >= MaxPendingUsers {
		m.AddError("Too many messages are waiting. Wait for the current reply to finish before sending another message.")
		m.refreshViewportContent()
		return
	}

	m.ClearNotices()
	m.TurnFailed = false
	m.Stopped = false

	continuation := input == "."
	var images []daemon.ImageAttachment
	var pastes []string
	if !continuation {
		var pasted []pastedImage
		input, pasted = m.Images.resolve(input)
		for _, image := range pasted {
			images = append(images, image.ImageAttachment)
		}
		input, pastes = m.Pastes.resolve(input)
	}
	handle, err := m.client.PrepareTurn(input, images, pastes, continuation)
	if err != nil {
		m.AddError(err.Error())
		return
	}
	cmd := m.sendCmd(handle, input, images, pastes, continuation)
	if continuation {
		if m.pendingContinuations == nil {
			m.pendingContinuations = make(map[string]pendingOperation)
		}
		m.pendingContinuations[handle.ID()] = pendingOperation{Handle: handle}
	}
	if !continuation {
		m.Images.restore(nil)
		m.Pastes.restore(nil)
		m.pendingUsers = append(m.pendingUsers, PendingUserTurn{Text: input, Images: images, Pastes: pastes, At: time.Now().UnixMilli(), Handle: handle, OperationID: handle.ID()})
	}
	m.isSending, m.sentHere, m.Follow = true, true, true
	m.reseedMood()
	m.refreshViewportContent()
	*cmds = append(*cmds, cmd, m.startAnimation())
}

func (m *ChatModel) handleSubmittedCommand(input string, cmds *[]tea.Cmd) {
	m.TextArea.Reset()
	m.syncLayout()
	trimmed := strings.TrimSpace(input)
	emit := func(msg tea.Msg) { *cmds = append(*cmds, func() tea.Msg { return msg }) }

	name, args, _ := strings.Cut(trimmed, " ")
	commandIndex := slices.IndexFunc(m.CommandMenu.Catalog, func(command daemon.SessionCommand) bool {
		return command.Name == name && command.Delivery == "input"
	})
	if commandIndex >= 0 {
		command := m.CommandMenu.Catalog[commandIndex]
		if m.pendingSendCount() >= MaxPendingUsers {
			m.AddError("Too many messages are waiting.")
			return
		}
		var handle *daemon.OperationHandle
		var err error
		arguments, err := daemon.ParseCommandArguments(command, args)
		if err == nil {
			handle, err = m.client.PrepareCommand(command.CommandID, arguments)
		}
		if err != nil {
			m.TextArea.SetValue(input)
			m.AddError(err.Error())
			return
		}
		m.pendingUsers = append(m.pendingUsers, PendingUserTurn{Text: trimmed, At: time.Now().UnixMilli(), Handle: handle, OperationID: handle.ID()})
		m.isSending, m.sentHere, m.Follow = true, true, true
		m.TurnFailed, m.Stopped = false, false
		*cmds = append(*cmds, m.sendCmd(handle, trimmed, nil, nil, false), m.startAnimation())
		m.refreshViewportContent()
		return
	}

	switch trimmed {
	case "/agents":
		emit(ChatOpenAgentsMsg{})
	case "/a", "/sessions":
		emit(ChatBackToSessionsMsg{})
	case "/q", "/quit", "/exit":
		m.Close()
		emit(ChatQuitMsg{})
	case "/new":
		emit(ChatNewSessionMsg{})
	case "/model":
		emit(ChatOpenModelPickerMsg{})
	case "/extensions", "/plugins":
		emit(ChatOpenExtensionPickerMsg{})
	case "/tree":
		emit(ChatOpenTreePickerMsg{})
	case "/context":
		emit(ChatOpenContextInspectorMsg{})
	case "/ttl", "/quota", "/requests":
		emit(ChatOpenPageMsg{Command: trimmed})
	case "/webhooks":
		emit(ChatOpenWebhooksPageMsg{})
	case "/skills", "/instructions", "/mcp":
		emit(ChatOpenCapabilityPageMsg{Kind: trimmed[1:]})
	case "/t", "/thinking", "/v", "/verbose":
		if trimmed == "/t" || trimmed == "/thinking" {
			m.Flags.Thinking = !m.Flags.Thinking
		} else {
			m.Flags.Tools = !m.Flags.Tools
		}
		m.rebuildSettledLines()
		m.refreshViewportContent()
	case "/status":
		statusText := fmt.Sprintf("session: %s\nworkspace: %s\nmodel: %s", m.SessionID, m.Workspace, m.Model)
		if m.Effort != "" {
			statusText += "\neffort: " + m.Effort
		}
		if m.Usage != nil {
			statusText += "\ntokens: " + formatUsage(m.Usage)
		}
		m.appendSettledEntry(HistoryEntry{Kind: EntryNote, Text: statusText})
		m.refreshViewportContent()
	default:
		switch {
		case strings.HasPrefix(trimmed, "/model "):
			emit(ChatExecuteCommandMsg{Name: "/model", Args: strings.TrimSpace(trimmed[7:])})
		case strings.HasPrefix(trimmed, "/login"):
			emit(ChatOpenLoginMsg{Name: strings.TrimSpace(strings.TrimPrefix(trimmed, "/login"))})
		default:
			for _, cmd := range m.CommandMenu.Catalog {
				if cmd.Name == trimmed && cmd.Page != nil && *cmd.Page {
					emit(ChatOpenPageMsg{Command: trimmed})
					return
				}
			}
			cmdName, cmdArgs, _ := strings.Cut(trimmed, " ")
			emit(ChatExecuteCommandMsg{Name: cmdName, Args: cmdArgs})
		}
	}
}
