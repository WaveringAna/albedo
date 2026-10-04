package tui

import (
	"albedo/cli/internal/daemon"
	"bytes"
	"context"
	"encoding/base64"
	"image"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/ansi/kitty"
)

// A chip's thumbnail area, in cells. Cells are taken to be twice as tall as
// they are wide.
const (
	thumbCols = 12
	thumbRows = 4
	// thumbPixels bounds the longer edge of what is sent to the terminal.
	thumbPixels = 240
)

// thumbnail is an image the terminal holds under id, shown in cols x rows
// cells by writing its Unicode placeholders.
type thumbnail struct {
	id, cols, rows int
}

// graphics is how kitty images reach this terminal: supported when it shows
// them through Unicode placeholders, wrapped when tmux sits in between.
type graphics struct {
	supported, wrapped bool
	// hint explains why a terminal that could show thumbnails does not.
	hint string
}

var terminalGraphics = sync.OnceValue(func() graphics {
	return detectGraphics(os.Getenv, func(args ...string) string {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		out, _ := exec.CommandContext(ctx, "tmux", args...).Output()
		return strings.TrimSpace(string(out))
	})
})

// detectGraphics reads the terminal from the environment, and through tmux
// the terminal of the client attached to it.
func detectGraphics(getenv func(string) string, tmux func(args ...string) string) graphics {
	if getenv("TMUX") == "" {
		return graphics{supported: placeholderTerminal(getenv("TERM"), getenv("TERM_PROGRAM")) || getenv("KITTY_WINDOW_ID") != ""}
	}
	if !placeholderTerminal(tmux("display-message", "-p", "#{client_termname}"), "") {
		return graphics{}
	}
	switch tmux("show-options", "-gv", "allow-passthrough") {
	case "on", "all":
		return graphics{supported: true, wrapped: true}
	}
	return graphics{hint: "image thumbnails need tmux's allow-passthrough: set -g allow-passthrough on"}
}

// placeholderTerminal reports a terminal known to draw kitty images through
// Unicode placeholders.
func placeholderTerminal(term, program string) bool {
	return strings.Contains(term, "kitty") || strings.Contains(term, "ghostty") || program == "ghostty"
}

// thumbnailIDs numbers transmitted images 16..255: the id travels as a
// placeholder's 256-colour foreground, and the renderer may rewrite the first
// sixteen as basic colours. A reused id replaces a long-gone image.
var thumbnailIDs atomic.Uint32

// transmitThumbnail decodes image, scales it down, and returns the escape
// sequence that hands it to the terminal, with where it will be shown. It
// returns false for a terminal without placeholders or an image it cannot
// decode (WebP).
func transmitThumbnail(g graphics, attachment daemon.ImageAttachment) (thumbnail, string, bool) {
	if !g.supported {
		return thumbnail{}, "", false
	}
	data, err := base64.StdEncoding.DecodeString(attachment.Data)
	if err != nil {
		return thumbnail{}, "", false
	}
	decoded, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return thumbnail{}, "", false
	}
	cols, rows := thumbnailCells(decoded.Bounds().Dx(), decoded.Bounds().Dy())
	thumb := thumbnail{id: 16 + int(thumbnailIDs.Add(1)-1)%240, cols: cols, rows: rows}
	options := &kitty.Options{
		Action: kitty.TransmitAndPut, Transmission: kitty.Direct, Format: kitty.PNG, Quiet: 2,
		ID: thumb.id, VirtualPlacement: true, Columns: cols, Rows: rows, Chunk: true,
	}
	if g.wrapped {
		options.ChunkFormatter = ansi.TmuxPassthrough
	}
	var seq strings.Builder
	if err := kitty.EncodeGraphics(&seq, shrink(decoded, thumbPixels), options); err != nil {
		return thumbnail{}, "", false
	}
	return thumb, seq.String(), true
}

// thumbnailCells fits a width x height pixel image into the thumbnail area.
func thumbnailCells(width, height int) (int, int) {
	if width <= 0 || height <= 0 {
		return thumbCols, thumbRows
	}
	// a cell is about twice as tall as wide: rows = cols * height / width / 2
	rows := max(1, (thumbCols*height+width)/(2*width))
	if rows <= thumbRows {
		return thumbCols, rows
	}
	return max(1, min(thumbCols, (2*thumbRows*width+height/2)/height)), thumbRows
}

// shrink scales img so its longer edge is at most edge pixels, sampling the
// nearest source pixel.
func shrink(img image.Image, edge int) image.Image {
	bounds := img.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	if width <= edge && height <= edge {
		return img
	}
	scaledW, scaledH := edge, max(1, height*edge/width)
	if height > width {
		scaledW, scaledH = max(1, width*edge/height), edge
	}
	out := image.NewRGBA(image.Rect(0, 0, scaledW, scaledH))
	for y := range scaledH {
		for x := range scaledW {
			out.Set(x, y, img.At(bounds.Min.X+x*width/scaledW, bounds.Min.Y+y*height/scaledH))
		}
	}
	return out
}

// placeholderRows are the cells that draw thumb: each one the placeholder
// character with its row and column as diacritics. Their foreground names
// the image rather than a colour, so it comes from the id, not the theme.
func placeholderRows(thumb thumbnail) []string {
	image := ansi.Style{}.ForegroundColor(ansi.IndexedColor(thumb.id)).String()
	reset := ansi.Style{}.DefaultForegroundColor().String()
	rows := make([]string, thumb.rows)
	for r := range rows {
		var row strings.Builder
		row.WriteString(image)
		for c := range thumb.cols {
			row.WriteRune(kitty.Placeholder)
			row.WriteRune(kitty.Diacritic(r))
			row.WriteRune(kitty.Diacritic(c))
		}
		row.WriteString(reset)
		rows[r] = row.String()
	}
	return rows
}
