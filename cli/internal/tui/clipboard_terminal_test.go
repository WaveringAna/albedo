// The daemon E2E cannot drive terminal clipboard replies. These tests catch
// chunk corruption, stale replies attaching to a new draft, and input-reader
// routing that would swallow OSC 5522 or insert its bytes into the composer.
package tui

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"image"
	"image/png"
	"io"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	uv "github.com/charmbracelet/ultraviolet"
)

func clipboardPacket(id, status, mime, payload string) string {
	metadata := "type=read:id=" + id + ":status=" + status
	if mime != "" {
		metadata += ":mime=" + base64.StdEncoding.EncodeToString([]byte(mime))
	}
	return "\x1b]5522;" + metadata + ";" + payload + "\x1b\\"
}

func clipboardPNG(t *testing.T) []byte {
	t.Helper()
	var out bytes.Buffer
	if err := png.Encode(&out, image.NewRGBA(image.Rect(0, 0, 2, 3))); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func clipboardApp(t *testing.T) *AppModel {
	t.Helper()
	t.Setenv("SSH_CONNECTION", "audit")
	t.Setenv("TERM", "xterm")
	t.Setenv("TERM_PROGRAM", "")
	t.Setenv("TMUX", "")
	t.Setenv("KITTY_WINDOW_ID", "")
	return &AppModel{
		ActiveSession: &daemon.Session{ID: "s"},
		Chat:          composer(t, 80, 25), State: AppStateChat,
	}
}

func deliverClipboardPacket(t *testing.T, app *AppModel, packet string) {
	t.Helper()
	var decoder uv.EventDecoder
	n, event := decoder.Decode([]byte(packet))
	if n != len(packet) {
		t.Fatalf("terminal decoder consumed %d of %d bytes", n, len(packet))
	}
	_, cmd := app.Update(event)
	if cmd != nil {
		msg := cmd()
		if _, ok := msg.(ClipboardImagePastedMsg); !ok {
			t.Fatalf("unexpected clipboard completion %T", msg)
		}
		app.Update(msg)
	}
}

func TestSSHClipboardPasteAcrossModal(t *testing.T) {
	app := clipboardApp(t)
	app.Chat.TextArea.SetValue("describe ")
	app.Update(tea.KeyPressMsg{Code: 'v', Mod: tea.ModCtrl})
	id := app.Chat.terminalClipboard.id
	if id == "" {
		t.Fatal("ctrl+v did not start a terminal clipboard read over SSH")
	}
	if _, cmd := app.Update(tea.KeyPressMsg{Code: 'v', Mod: tea.ModCtrl}); cmd != nil {
		t.Fatal("repeated ctrl+v started a second read")
	}
	app.State = AppStateModelPicker
	data := clipboardPNG(t)
	deliverClipboardPacket(t, app, clipboardPacket(id, "OK", "", ""))
	for _, chunk := range [][]byte{data[:13], data[13:]} {
		deliverClipboardPacket(t, app, clipboardPacket(id, "DATA", "image/png", base64.StdEncoding.EncodeToString(chunk)))
	}
	deliverClipboardPacket(t, app, clipboardPacket(id, "DONE", "", ""))
	images := app.Chat.Images.referenced(app.Chat.TextArea.Value())
	if len(images) != 1 || app.Chat.Images.byNumber[images[0]].Data != base64.StdEncoding.EncodeToString(data) {
		t.Fatalf("clipboard chunks did not attach intact: %v", images)
	}
	if !strings.HasPrefix(app.Chat.TextArea.Value(), "describe ") || app.Chat.terminalClipboard.id != "" {
		t.Fatal("paste lost the draft or left the read pending")
	}
	app.Chat, _ = app.Chat.Update(tea.PasteMsg{Content: "plain text"})
	if !strings.HasSuffix(app.Chat.TextArea.Value(), "plain text") {
		t.Fatal("normal text paste was intercepted")
	}
}

func TestSSHClipboardRejectsInvalidReplies(t *testing.T) {
	for _, scenario := range []string{
		"denied", "unsupported", "busy", "bad-base64", "chunk-limit", "image-limit",
		"data-before-ok", "duplicate-ok", "empty", "invalid-image", "timeout",
	} {
		t.Run(scenario, func(t *testing.T) {
			app := clipboardApp(t)
			app.Chat.TextArea.SetValue("keep this draft")
			app.Update(tea.KeyPressMsg{Code: 'v', Mod: tea.ModCtrl})
			id := app.Chat.terminalClipboard.id
			if scenario != "data-before-ok" {
				deliverClipboardPacket(t, app, clipboardPacket(id, "OK", "", ""))
			}
			switch scenario {
			case "denied", "unsupported", "busy":
				status := map[string]string{"denied": "EPERM", "unsupported": "ENOSYS", "busy": "EBUSY"}[scenario]
				deliverClipboardPacket(t, app, clipboardPacket(id, status, "", ""))
			case "bad-base64":
				deliverClipboardPacket(t, app, clipboardPacket(id, "DATA", "image/png", "YQ==\n"))
			case "chunk-limit":
				deliverClipboardPacket(t, app, clipboardPacket(id, "DATA", "image/png", base64.StdEncoding.EncodeToString(make([]byte, 4097))))
			case "image-limit":
				chunk := base64.StdEncoding.EncodeToString(make([]byte, 4096))
				for range MaxClipboardImageBytes/4096 + 1 {
					deliverClipboardPacket(t, app, clipboardPacket(id, "DATA", "image/png", chunk))
				}
			case "data-before-ok":
				deliverClipboardPacket(t, app, clipboardPacket(id, "DATA", "image/png", "YQ=="))
			case "duplicate-ok":
				deliverClipboardPacket(t, app, clipboardPacket(id, "OK", "", ""))
			case "invalid-image":
				deliverClipboardPacket(t, app, clipboardPacket(id, "DATA", "image/png", "YQ=="))
				deliverClipboardPacket(t, app, clipboardPacket(id, "DONE", "", ""))
			case "empty":
				deliverClipboardPacket(t, app, clipboardPacket(id, "DONE", "", ""))
			case "timeout":
				_, cmd := app.Update(terminalClipboardTimeoutMsg{app.Chat.SessionID, id, app.Chat.Generation})
				app.Update(cmd())
			}
			if !app.Chat.Notices.HasError() || app.Chat.terminalClipboard.id != "" {
				t.Fatal("failed paste did not report an error and release its buffer")
			}
			if app.Chat.TextArea.Value() != "keep this draft" || len(app.Chat.Images.referenced(app.Chat.TextArea.Value())) != 0 {
				t.Fatal("failed paste changed the draft")
			}
			// A delayed DONE must not attach data after failure or after retry.
			app.Update(tea.KeyPressMsg{Code: 'v', Mod: tea.ModCtrl})
			deliverClipboardPacket(t, app, clipboardPacket(id, "DONE", "", ""))
			if app.Chat.terminalClipboard.id == "" {
				t.Fatal("a stale response completed the new paste")
			}
		})
	}
}

func TestSSHClipboardIgnoresOtherSessionAndGeneration(t *testing.T) {
	app := clipboardApp(t)
	app.Update(tea.KeyPressMsg{Code: 'v', Mod: tea.ModCtrl})
	oldID := app.Chat.terminalClipboard.id
	oldGen := app.Chat.Generation
	app.Chat.Close()
	app.Chat = composer(t, 80, 25)
	app.Update(tea.KeyPressMsg{Code: 'v', Mod: tea.ModCtrl})
	id := app.Chat.terminalClipboard.id
	deliverClipboardPacket(t, app, clipboardPacket(oldID, "OK", "", ""))
	deliverClipboardPacket(t, app, clipboardPacket(oldID, "DATA", "image/png", strings.Repeat("A", 9000)))
	app.Update(terminalClipboardTimeoutMsg{"other", id, app.Chat.Generation})
	app.Update(terminalClipboardTimeoutMsg{"s", oldID, oldGen})
	if app.Chat.terminalClipboard.id != id || app.Chat.terminalClipboard.started || app.Chat.Notices.HasError() {
		t.Fatal("old session replies changed the new paste")
	}
}

// This model runs the real Bubble Tea reader/writer without starting daemon I/O.
type clipboardTerminalProbe struct{ app *AppModel }

func (m clipboardTerminalProbe) Init() tea.Cmd {
	return func() tea.Msg { return tea.KeyPressMsg{Code: 'v', Mod: tea.ModCtrl} }
}
func (m clipboardTerminalProbe) View() tea.View { return tea.NewView("") }
func (m clipboardTerminalProbe) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	_, cmd := m.app.Update(msg)
	if _, ok := msg.(ClipboardImagePastedMsg); ok {
		return m, tea.Quit
	}
	return m, cmd
}

type clipboardTerminalWriter struct{ requests chan string }

func (w clipboardTerminalWriter) Write(p []byte) (int, error) {
	if start := strings.Index(string(p), "\x1b]5522;type=read:"); start >= 0 {
		packet, _, _ := strings.Cut(string(p[start:]), "\x1b\\")
		w.requests <- packet + "\x1b\\"
	}
	return len(p), nil
}

func TestSSHClipboardThroughBubbleTeaReader(t *testing.T) {
	app := clipboardApp(t)
	input, replies := io.Pipe()
	defer input.Close()
	defer replies.Close()
	requests := make(chan string, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	program := tea.NewProgram(clipboardTerminalProbe{app}, tea.WithInput(input),
		tea.WithOutput(clipboardTerminalWriter{requests}), tea.WithContext(ctx), tea.WithoutSignalHandler())
	done := make(chan error, 1)
	go func() { _, err := program.Run(); done <- err }()
	var request string
	select {
	case request = <-requests:
	case <-ctx.Done():
		t.Fatal("Bubble Tea never wrote the clipboard request")
	}
	metadata, payload, _ := strings.Cut(strings.TrimSuffix(strings.TrimPrefix(request, "\x1b]5522;"), "\x1b\\"), ";")
	id := strings.TrimPrefix(metadata, "type=read:id=")
	if payload != base64.StdEncoding.EncodeToString([]byte("image/png image/jpeg")) {
		t.Fatalf("unexpected clipboard request: %q", request)
	}
	data := clipboardPNG(t)
	response := clipboardPacket(id, "OK", "", "") +
		clipboardPacket(id, "DATA", "image/png", base64.StdEncoding.EncodeToString(data)) +
		clipboardPacket(id, "DONE", "", "")
	// Split even the escape sequence across writes, as an SSH stream can.
	for _, part := range []string{response[:1], response[1:19], response[19:]} {
		if _, err := fmt.Fprint(replies, part); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("Bubble Tea did not finish the image paste")
	}
	if len(app.Chat.Images.referenced(app.Chat.TextArea.Value())) != 1 || app.Chat.Notices.HasError() {
		t.Fatal("terminal reader failed to deliver the local image")
	}
}
