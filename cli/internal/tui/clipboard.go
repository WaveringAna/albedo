package tui

import (
	"albedo/cli/internal/daemon"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/atotto/clipboard"
)

const (
	MaxClipboardImageBytes = 5 * 1024 * 1024
	MaxClipboardImageEdge  = 16384
)

func execClipboardCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	defer stdout.Close()
	if err = cmd.Start(); err != nil {
		return nil, err
	}
	// Killing the command does not close stdout held open by a descendant.
	stopClosingStdout := context.AfterFunc(ctx, func() { _ = stdout.Close() })
	defer stopClosingStdout()

	// The extra byte detects oversized output without buffering the rest.
	limited := io.LimitReader(stdout, MaxClipboardImageBytes+1)
	buf, err := io.ReadAll(limited)
	if err != nil || len(buf) > MaxClipboardImageBytes {
		// Once reading stops, a child still writing to the pipe could block Wait.
		_ = cmd.Process.Kill()
	}
	waitErr := cmd.Wait()

	if len(buf) > MaxClipboardImageBytes {
		return nil, fmt.Errorf("clipboard image exceeds %d byte limit", MaxClipboardImageBytes)
	}
	if ctx.Err() != nil {
		return buf, ctx.Err()
	}
	if err != nil {
		return buf, err
	}
	return buf, waitErr
}

// CopyText puts text on the clipboard of the machine albedo runs on and asks
// the terminal to put it on its own with OSC 52. Those differ when you reach
// albedo over ssh or attach to its session from another device, and only the
// terminal's is the one you paste from; a terminal without OSC 52 still has
// the local copy.
func CopyText(text string) tea.Cmd {
	return tea.Batch(tea.SetClipboard(text), func() tea.Msg {
		_ = clipboard.WriteAll(text)
		return nil
	})
}

func isRemote() bool {
	return os.Getenv("SSH_CONNECTION") != "" || os.Getenv("SSH_CLIENT") != "" || os.Getenv("MOSH_CONNECTION") != ""
}

func ClipboardHasImage() bool {
	if isRemote() {
		return false
	}

	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	switch runtime.GOOS {
	case "darwin":
		if _, err := exec.LookPath("pngpaste"); err == nil {
			if out, err := execClipboardCommand(ctx, "pngpaste", "-b"); err == nil && len(out) == 0 {
				return true
			}
		}
		out, err := execClipboardCommand(ctx, "osascript", "-e", "clipboard info")
		if err != nil {
			return false
		}
		s := string(out)
		return strings.Contains(s, "«class PNGf»") || strings.Contains(s, "JPEG picture") || strings.Contains(s, "TIFF picture")

	case "linux":
		// Wayland first: under a compositor both may be set.
		probes := []struct {
			env, tool string
			args      []string
		}{
			{"WAYLAND_DISPLAY", "wl-paste", []string{"--list-types"}},
			{"DISPLAY", "xclip", []string{"-selection", "clipboard", "-t", "TARGETS", "-o"}},
		}
		for _, probe := range probes {
			if os.Getenv(probe.env) == "" {
				continue
			}
			if _, err := exec.LookPath(probe.tool); err != nil {
				continue
			}
			out, err := execClipboardCommand(ctx, probe.tool, probe.args...)
			if err == nil && strings.Contains(string(out), "image/") {
				return true
			}
		}
		return false
	}

	return false
}

func parseAppleScriptHex(out []byte) ([]byte, error) {
	s, ok1 := strings.CutPrefix(strings.TrimSpace(string(out)), "«data ")
	s, ok2 := strings.CutSuffix(s, "»")
	if !ok1 || !ok2 {
		return nil, errors.New("not an AppleScript hex payload")
	}
	fields := strings.Fields(s)
	if len(fields) == 0 {
		return nil, errors.New("empty AppleScript data")
	}
	// Skip the 4-char ostype code (e.g. PNGf, JPEG)
	if len(fields[0]) <= 4 {
		return nil, errors.New("missing hex payload in AppleScript data")
	}
	return hex.DecodeString(fields[0][4:])
}

func ReadClipboardImage() (*daemon.ImageAttachment, error) {
	if isRemote() {
		return nil, errors.New("remote clipboard image unsupported")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	var data []byte
	var err error

	switch runtime.GOOS {
	case "darwin":
		if _, errPath := exec.LookPath("pngpaste"); errPath == nil {
			data, err = execClipboardCommand(ctx, "pngpaste", "-")
		} else {
			rawOut, errCmd := execClipboardCommand(ctx, "osascript", "-e", "get the clipboard as «class PNGf»")
			if errCmd != nil {
				return nil, errCmd
			}
			if len(rawOut) > MaxClipboardImageBytes {
				return nil, fmt.Errorf("clipboard image too large: %d bytes (max %d)", len(rawOut), MaxClipboardImageBytes)
			}
			data, err = parseAppleScriptHex(rawOut)
		}

	case "linux":
		if os.Getenv("WAYLAND_DISPLAY") != "" {
			data, err = execClipboardCommand(ctx, "wl-paste", "-t", "image/png")
		} else if os.Getenv("DISPLAY") != "" {
			data, err = execClipboardCommand(ctx, "xclip", "-selection", "clipboard", "-t", "image/png", "-o")
		} else {
			return nil, errors.New("no display or clipboard tool available")
		}

	default:
		return nil, fmt.Errorf("clipboard images are not supported on %s", runtime.GOOS)
	}

	if err != nil {
		return nil, fmt.Errorf("could not read clipboard image: %w", err)
	}

	return clipboardImage(data)
}

func clipboardImage(data []byte) (*daemon.ImageAttachment, error) {
	if len(data) == 0 {
		return nil, errors.New("clipboard contains no image data")
	}

	if len(data) > MaxClipboardImageBytes {
		return nil, fmt.Errorf("clipboard image too large: %d bytes (max %d)", len(data), MaxClipboardImageBytes)
	}

	// Strictly validate config - rejects truncated or 0-dimension images
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("clipboard image is invalid or incomplete: %w", err)
	}
	if cfg.Width <= 0 || cfg.Height <= 0 {
		return nil, errors.New("invalid image dimensions: zero or negative")
	}
	if cfg.Width > MaxClipboardImageEdge || cfg.Height > MaxClipboardImageEdge {
		return nil, fmt.Errorf("image dimensions too large: %dx%d (max edge %d)", cfg.Width, cfg.Height, MaxClipboardImageEdge)
	}

	mime := daemon.ImagePNG
	switch format {
	case "jpeg", "jpg":
		mime = daemon.ImageJPEG
	case "webp":
		mime = daemon.ImageWEBP
	}

	encoded := base64.StdEncoding.EncodeToString(data)
	return &daemon.ImageAttachment{
		ImageMetadata: daemon.ImageMetadata{
			MimeType: mime,
			Width:    cfg.Width,
			Height:   cfg.Height,
			Bytes:    len(data),
		},
		Data: encoded,
	}, nil
}

type ClipboardImagePastedMsg struct {
	Err        error
	Image      *daemon.ImageAttachment
	SessionID  string
	Generation int64
	// thumb is set once transmit has handed the image to the terminal.
	thumb    *thumbnail
	transmit string
	// hint says why the terminal shows no thumbnail when a setting would fix it.
	hint string
}

func PasteClipboardImageCmd(sessionID string, gen int64) tea.Cmd {
	return func() tea.Msg {
		if !ClipboardHasImage() {
			return ClipboardImagePastedMsg{SessionID: sessionID, Generation: gen}
		}
		img, err := ReadClipboardImage()
		return clipboardImagePasted(sessionID, gen, img, err)
	}
}

func clipboardImagePasted(sessionID string, gen int64, img *daemon.ImageAttachment, err error) ClipboardImagePastedMsg {
	msg := ClipboardImagePastedMsg{SessionID: sessionID, Generation: gen, Image: img, Err: err}
	if img != nil {
		g := terminalGraphics()
		if thumb, transmit, ok := transmitThumbnail(g, *img); ok {
			msg.thumb, msg.transmit = &thumb, transmit
		}
		msg.hint = g.hint
	}
	return msg
}
