// Which terminals get thumbnails depends on the environment and, under tmux,
// on the attached client and a tmux option; the e2e suite runs in neither, so
// a wrong branch here would only show as missing or garbled thumbnails.
package tui

import "testing"

func TestDetectGraphics(t *testing.T) {
	for _, test := range []struct {
		name        string
		env         map[string]string
		client      string
		passthrough string
		want        graphics
	}{
		{name: "kitty", env: map[string]string{"TERM": "xterm-kitty"}, want: graphics{supported: true}},
		{name: "ghostty", env: map[string]string{"TERM_PROGRAM": "ghostty"}, want: graphics{supported: true}},
		{name: "plain terminal", env: map[string]string{"TERM": "xterm-256color"}},
		{name: "tmux in kitty", env: map[string]string{"TMUX": "/tmp/tmux", "TERM": "tmux-256color"}, client: "xterm-kitty", passthrough: "on", want: graphics{supported: true, wrapped: true}},
		{name: "tmux without passthrough", env: map[string]string{"TMUX": "/tmp/tmux", "KITTY_WINDOW_ID": "1"}, client: "xterm-ghostty", passthrough: "off", want: graphics{hint: "image thumbnails need tmux's allow-passthrough: set -g allow-passthrough on"}},
		{name: "tmux in a plain terminal", env: map[string]string{"TMUX": "/tmp/tmux", "KITTY_WINDOW_ID": "1"}, client: "xterm-256color", passthrough: "on"},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := detectGraphics(func(key string) string { return test.env[key] }, func(args ...string) string {
				if args[0] == "display-message" {
					return test.client
				}
				return test.passthrough
			})
			if got != test.want {
				t.Fatalf("got %+v, want %+v", got, test.want)
			}
		})
	}
}

func TestThumbnailCellsKeepTheAspectInsideTheArea(t *testing.T) {
	for _, test := range []struct{ width, height, cols, rows int }{
		{1200, 400, 12, 2}, // wide: full width, few rows
		{800, 800, 8, 4},   // square: twice as many columns as rows
		{100, 1000, 1, 4},  // tall: one column
		{4000, 10, 12, 1},
	} {
		if cols, rows := thumbnailCells(test.width, test.height); cols != test.cols || rows != test.rows {
			t.Errorf("%dx%d: got %dx%d cells, want %dx%d", test.width, test.height, cols, rows, test.cols, test.rows)
		}
	}
}
