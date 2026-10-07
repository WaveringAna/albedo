package tui

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	uv "github.com/charmbracelet/ultraviolet"
	"github.com/charmbracelet/x/ansi"
)

// OSC 5522 replies travel through Bubble Tea's reader, never a second TTY reader.
// https://sw.kovidgoyal.net/kitty/clipboard/
type terminalClipboardRead struct {
	id       string
	mime     string
	data     []byte
	received int
	started  bool
}

type terminalClipboardTimeoutMsg struct {
	SessionID  string
	ID         string
	Generation int64
}

func (m *ChatModel) readTerminalClipboard() tea.Cmd {
	if m.terminalClipboard.id != "" {
		return nil
	}
	id := fmt.Sprintf("albedo-%d", nextPageGeneration())
	m.terminalClipboard = terminalClipboardRead{id: id}
	request := "\x1b]5522;type=read:id=" + id + ";" +
		base64.StdEncoding.EncodeToString([]byte("image/png image/jpeg")) + "\x1b\\"
	if os.Getenv("TMUX") != "" {
		request = ansi.TmuxPassthrough(request)
	}
	timeout := terminalClipboardTimeoutMsg{m.SessionID, id, m.Generation}
	return tea.Batch(tea.Raw(request), tea.Tick(30*time.Second, func(time.Time) tea.Msg { return timeout }))
}

func (m *ChatModel) handleTerminalClipboard(msg tea.Msg) (tea.Cmd, bool) {
	switch msg := msg.(type) {
	case terminalClipboardTimeoutMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation || msg.ID != m.terminalClipboard.id {
			return nil, true
		}
		err := errors.New("image paste timed out; use a terminal with OSC 5522 support (such as kitty) " +
			"and allow clipboard reads; in tmux, set -g allow-passthrough on")
		return m.finishTerminalClipboard(err), true
	case uv.UnknownOscEvent:
		packet, ok := strings.CutPrefix(string(msg), "\x1b]5522;")
		if !ok {
			return nil, false
		}
		packet = strings.TrimSuffix(strings.TrimSuffix(packet, "\x1b\\"), "\a")
		metadata, payload, _ := strings.Cut(packet, ";")
		if len(metadata) > 1024 {
			return nil, true
		}
		fields := map[string]string{}
		for field := range strings.SplitSeq(metadata, ":") {
			key, value, ok := strings.Cut(field, "=")
			if ok {
				fields[key] = value
			}
		}
		r := &m.terminalClipboard
		if r.id == "" || fields["id"] != r.id || fields["type"] != "read" {
			return nil, true
		}
		if len(packet) > 8192 {
			return m.finishTerminalClipboard(errors.New("oversized terminal clipboard response")), true
		}
		done, err := r.accept(fields, payload)
		if done {
			return m.finishTerminalClipboard(err), true
		}
		return nil, true
	}
	return nil, false
}

func (r *terminalClipboardRead) accept(fields map[string]string, payload string) (bool, error) {
	switch fields["status"] {
	case "OK":
		if r.started {
			return true, errors.New("duplicate clipboard response")
		}
		r.started = true
	case "DATA":
		if !r.started {
			return true, errors.New("clipboard data arrived before its acknowledgement")
		}
		mime, err := decodeClipboardChunk(fields["mime"], 64)
		if err != nil || (string(mime) != "image/png" && string(mime) != "image/jpeg") {
			return true, errors.New("unexpected clipboard image type")
		}
		data, err := decodeClipboardChunk(payload, 4096)
		if err != nil {
			return true, err
		}
		if r.received+len(data) > MaxClipboardImageBytes {
			return true, fmt.Errorf("clipboard image exceeds %d byte limit", MaxClipboardImageBytes)
		}
		r.received += len(data)
		if r.mime == "" {
			r.mime = string(mime)
		}
		if r.mime == string(mime) {
			r.data = append(r.data, data...)
		}
	case "DONE":
		if !r.started {
			return true, errors.New("clipboard response ended before its acknowledgement")
		}
		return true, nil
	case "EPERM":
		return true, errors.New("clipboard access denied; allow the clipboard read in your terminal and try again")
	case "ENOSYS":
		return true, errors.New("the terminal does not support image clipboard reads")
	case "EBUSY":
		return true, errors.New("the terminal clipboard is busy; try again")
	default:
		return true, errors.New("invalid terminal clipboard response")
	}
	return false, nil
}

func decodeClipboardChunk(encoded string, limit int) ([]byte, error) {
	if len(encoded) > base64.StdEncoding.EncodedLen(limit) || strings.ContainsAny(encoded, "\r\n") {
		return nil, errors.New("invalid or oversized clipboard chunk")
	}
	data, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || len(data) > limit {
		return nil, errors.New("invalid or oversized clipboard chunk")
	}
	return data, nil
}

func (m *ChatModel) finishTerminalClipboard(err error) tea.Cmd {
	data := m.terminalClipboard.data
	m.terminalClipboard = terminalClipboardRead{}
	sessionID, gen := m.SessionID, m.Generation
	return func() tea.Msg {
		if err != nil {
			return clipboardImagePasted(sessionID, gen, nil, err)
		}
		if len(data) == 0 {
			return clipboardImagePasted(sessionID, gen, nil, errors.New("the local clipboard has no PNG or JPEG image"))
		}
		img, err := clipboardImage(data)
		return clipboardImagePasted(sessionID, gen, img, err)
	}
}
