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

type CommandExecutor func(ctx context.Context, name string, args ...string) ([]byte, error)

func defaultExec(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	// Bounded read: read up to MaxClipboardImageBytes + 1 so we never buffer unbounded subprocess output
	limited := io.LimitReader(stdout, MaxClipboardImageBytes+1)
	buf, err := io.ReadAll(limited)
	_ = cmd.Wait()

	if len(buf) > MaxClipboardImageBytes {
		return nil, fmt.Errorf("clipboard image exceeds %d byte limit", MaxClipboardImageBytes)
	}
	return buf, err
}

var CurrentExecutor CommandExecutor = defaultExec

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

func ReadClipboardText() (string, error) {
	return clipboard.ReadAll()
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
			out, err := CurrentExecutor(ctx, "pngpaste", "-b")
			if err == nil && len(out) == 0 {
				return true
			}
		}
		out, err := CurrentExecutor(ctx, "osascript", "-e", "clipboard info")
		if err == nil {
			s := string(out)
			if strings.Contains(s, "«class PNGf»") || strings.Contains(s, "JPEG picture") || strings.Contains(s, "TIFF picture") {
				return true
			}
		}
		return false

	case "linux":
		if os.Getenv("WAYLAND_DISPLAY") != "" {
			if _, err := exec.LookPath("wl-paste"); err == nil {
				out, err := CurrentExecutor(ctx, "wl-paste", "--list-types")
				if err == nil && strings.Contains(string(out), "image/") {
					return true
				}
			}
		}
		if os.Getenv("DISPLAY") != "" {
			if _, err := exec.LookPath("xclip"); err == nil {
				out, err := CurrentExecutor(ctx, "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o")
				if err == nil && strings.Contains(string(out), "image/") {
					return true
				}
			}
		}
		return false
	}

	return false
}

func parseAppleScriptHex(out []byte) ([]byte, error) {
	s := strings.TrimSpace(string(out))
	if !strings.HasPrefix(s, "«data ") || !strings.HasSuffix(s, "»") {
		return nil, errors.New("not an AppleScript hex payload")
	}
	content := strings.TrimSuffix(strings.TrimPrefix(s, "«data "), "»")
	parts := strings.Fields(content)
	if len(parts) == 0 {
		return nil, errors.New("empty AppleScript data")
	}
	hexPart := parts[0]
	// Skip the 4-char ostype code (e.g. PNGf, JPEG)
	if len(hexPart) <= 4 {
		return nil, errors.New("missing hex payload in AppleScript data")
	}
	rawHex := hexPart[4:]
	return hex.DecodeString(rawHex)
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
			data, err = CurrentExecutor(ctx, "pngpaste", "-")
		} else {
			script := "get the clipboard as «class PNGf»"
			rawOut, errCmd := CurrentExecutor(ctx, "osascript", "-e", script)
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
			data, err = CurrentExecutor(ctx, "wl-paste", "-t", "image/png")
		} else if os.Getenv("DISPLAY") != "" {
			data, err = CurrentExecutor(ctx, "xclip", "-selection", "clipboard", "-t", "image/png", "-o")
		} else {
			return nil, errors.New("no display or clipboard tool available")
		}

	default:
		return nil, fmt.Errorf("unsupported platform for clipboard images: %s", runtime.GOOS)
	}

	if err != nil {
		return nil, fmt.Errorf("failed to read clipboard image: %w", err)
	}

	if len(data) == 0 {
		return nil, errors.New("clipboard contains no image data")
	}

	if len(data) > MaxClipboardImageBytes {
		return nil, fmt.Errorf("clipboard image too large: %d bytes (max %d)", len(data), MaxClipboardImageBytes)
	}

	// Strictly validate config - rejects truncated or 0-dimension images
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("invalid or truncated image: %w", err)
	}
	if cfg.Width <= 0 || cfg.Height <= 0 {
		return nil, errors.New("invalid image dimensions: zero or negative")
	}
	if cfg.Width > MaxClipboardImageEdge || cfg.Height > MaxClipboardImageEdge {
		return nil, fmt.Errorf("image dimensions too large: %dx%d (max edge %d)", cfg.Width, cfg.Height, MaxClipboardImageEdge)
	}

	var mime daemon.ImageMimeType
	switch format {
	case "jpeg", "jpg":
		mime = daemon.ImageJPEG
	case "webp":
		mime = daemon.ImageWEBP
	default:
		mime = daemon.ImagePNG
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
	SessionID  string
	Generation int64
	Image      *daemon.ImageAttachment
	Err        error
}

func PasteClipboardImageCmd(sessionID string, gen int64) tea.Cmd {
	return func() tea.Msg {
		if !ClipboardHasImage() {
			return ClipboardImagePastedMsg{
				SessionID:  sessionID,
				Generation: gen,
				Err:        errors.New("no image in clipboard"),
			}
		}
		img, err := ReadClipboardImage()
		return ClipboardImagePastedMsg{
			SessionID:  sessionID,
			Generation: gen,
			Image:      img,
			Err:        err,
		}
	}
}
