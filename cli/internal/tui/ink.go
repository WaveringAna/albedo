package tui

import (
	"fmt"
	"math"
	"os"
	"regexp"
	"strconv"

	"github.com/lucasb-eyer/go-colorful"
)

// ink is the transcript's brightness ramp. Each step is mixed from the
// terminal's own text and background colors to a contrast target, so the
// ramp keeps its spacing on any theme instead of trusting palette slots.
type ink struct {
	// code steps down from prose for inline and fenced code.
	code string
	// secondary is text read at a glance: tool rows, timings, notices.
	secondary string
	// decor is structure that is seen, not read: list markers, gutters.
	decor string
	// busy is albedo's rail color while it works in tools.
	busy string
	// codeBg tints the cells under inline code, so a span keeps prose
	// contrast and still reads as code.
	codeBg string
	// surface lifts a selected row off the background.
	surface string
	// added and removed are the diff row tints.
	added, removed string
	// brandFrom and brandTo are the ends of the brand gradient.
	brandFrom, brandTo string
	// bg is the terminal's background, which language colors adapt to.
	bg string
}

// APCA contrast targets (Lc) for each step: about 60 suits content text,
// 45 text read at a glance, and 15 to 30 marks that are not read.
// The code tint is a luminance step from the background, measured as a
// contrast ratio with the flare term so a black background gets a larger lift
// than a gray one. Dark themes tint toward the palette's blue, light themes
// step toward the text, since a blue wash on a light background reads as a
// marker highlight.
const (
	darkCodeBgRatio  = 1.3
	lightCodeBgRatio = 1.65
	surfaceRatio     = 1.25
	diffRatio        = 1.35
)

const (
	codeLc      = 64
	secondaryLc = 45
	decorLc     = 22
	busyLc      = 30
)

type rgb struct{ r, g, b float64 }

func (c rgb) hex() string {
	b := func(v float64) int { return int(math.Round(math.Max(0, math.Min(1, v)) * 255)) }
	return "#" + strconv.FormatInt(int64(1<<24|b(c.r)<<16|b(c.g)<<8|b(c.b)), 16)[1:]
}

func (c rgb) mix(to rgb, t float64) rgb {
	return rgb{c.r + (to.r-c.r)*t, c.g + (to.g-c.g)*t, c.b + (to.b-c.b)*t}
}

// apca is the magnitude of the APCA 0.0.98G lightness contrast of text on bg.
func apca(text, bg rgb) float64 {
	y := func(c rgb) float64 {
		v := 0.2126729*math.Pow(c.r, 2.4) + 0.7151522*math.Pow(c.g, 2.4) + 0.0721750*math.Pow(c.b, 2.4)
		if v < 0.022 {
			v += math.Pow(0.022-v, 1.414)
		}
		return v
	}
	yt, yb := y(text), y(bg)
	var s float64
	if yb > yt {
		s = (math.Pow(yb, 0.56) - math.Pow(yt, 0.57)) * 1.14
	} else {
		s = (math.Pow(yb, 0.65) - math.Pow(yt, 0.62)) * 1.14
	}
	if math.Abs(s) < 0.1 {
		return 0
	}
	return (math.Abs(s) - 0.027) * 100
}

// bisect narrows [0, 1] to the boundary where still stops holding, over 24
// halvings. Both mix searches are monotone in the fraction. It returns the
// last fraction where still holds and the first where it does not; callers
// pick the side that meets their target.
func bisect(still func(t float64) bool) (lo, hi float64) {
	lo, hi = 0.0, 1.0
	for range 24 {
		mid := (lo + hi) / 2
		if still(mid) {
			lo = mid
		} else {
			hi = mid
		}
	}
	return lo, hi
}

// toward mixes from into bg until it reaches the target contrast. A color
// already under the target stays as it is.
func toward(from, bg rgb, target float64) rgb {
	if apca(from, bg) <= target {
		return from
	}
	t, _ := bisect(func(t float64) bool { return apca(from.mix(bg, t), bg) > target })
	return from.mix(bg, t)
}

// luminance is relative luminance as the WCAG contrast ratio defines it.
func luminance(c rgb) float64 {
	lin := func(v float64) float64 {
		if v <= 0.04045 {
			return v / 12.92
		}
		return math.Pow((v+0.055)/1.055, 2.4)
	}
	return 0.2126*lin(c.r) + 0.7152*lin(c.g) + 0.0722*lin(c.b)
}

// ratio is the WCAG contrast ratio between two colors.
func ratio(a, b rgb) float64 {
	la, lb := luminance(a)+0.05, luminance(b)+0.05
	return max(la, lb) / min(la, lb)
}

// step mixes bg toward to until the two differ by the given contrast ratio,
// or reaches to when it cannot.
func step(bg, to rgb, target float64) rgb {
	if ratio(bg, to) <= target {
		return to
	}
	// hi is the first fraction that meets the ratio; lo only approaches it.
	_, t := bisect(func(t float64) bool { return ratio(bg, bg.mix(to, t)) < target })
	return bg.mix(to, t)
}

// legible moves c's OKLCH lightness away from bg, up on a dark background
// and down on a light one, until its APCA contrast reaches target. Hue and
// chroma stay, so a language keeps its color on every theme.
func legible(c, bg rgb, target float64) rgb {
	if apca(c, bg) >= target {
		return c
	}
	l, chroma, hue := colorful.Color{R: c.r, G: c.g, B: c.b}.OkLch()
	end := 1.0
	if bgL, _, _ := (colorful.Color{R: bg.r, G: bg.g, B: bg.b}).OkLch(); bgL > 0.6 {
		end = 0
	}
	at := func(t float64) rgb {
		v := colorful.OkLch(l+(end-l)*t, chroma, hue).Clamped()
		return rgb{v.R, v.G, v.B}
	}
	_, t := bisect(func(t float64) bool { return apca(at(t), bg) < target })
	return at(t)
}

// termColors is what the terminal reported. A missing color is nil, and
// palette holds only the entries that were reported.
type termColors struct {
	fg, bg  *rgb
	palette map[int]rgb
}

// The palette entries the theme mixes from.
const (
	ansiRed     = 1
	ansiGreen   = 2
	ansiBlue    = 4
	ansiMagenta = 5
	ansiCyan    = 6
)

var queriedPalette = []int{ansiRed, ansiGreen, ansiBlue, ansiMagenta, ansiCyan}

// minTrustLc is the least contrast a reported text color may have with the
// reported background. Below it the reply describes something other than
// what is on screen, like a multiplexer that answers with black for colors
// it does not know, and the palette fallbacks are safer.
const minTrustLc = 60

func mixInk(c termColors) (ink, bool) {
	if c.fg == nil || c.bg == nil || apca(*c.fg, *c.bg) < minTrustLc {
		return ink{}, false
	}
	fg, bg := *c.fg, *c.bg
	out := ink{
		code:      toward(fg, bg, codeLc).hex(),
		secondary: toward(fg, bg, secondaryLc).hex(),
		decor:     toward(fg, bg, decorLc).hex(),
		surface:   step(bg, fg, surfaceRatio).hex(),
		bg:        bg.hex(),
	}
	blue, hasBlue := c.palette[ansiBlue]
	codeTarget, codeRatio := fg, darkCodeBgRatio
	if luminance(bg) > luminance(fg) {
		codeRatio = lightCodeBgRatio
	} else if hasBlue {
		codeTarget = blue
	}
	out.codeBg = step(bg, codeTarget, codeRatio).hex()
	if magenta, ok := c.palette[ansiMagenta]; ok && apca(magenta, bg) >= busyLc {
		out.busy = toward(magenta, bg, busyLc).hex()
	}
	if red, ok := c.palette[ansiRed]; ok {
		out.removed = step(bg, red, diffRatio).hex()
	}
	if green, ok := c.palette[ansiGreen]; ok {
		out.added = step(bg, green, diffRatio).hex()
	}
	// the brand runs from your color toward violet, halfway between the
	// palette's blue and magenta
	cyan, hasCyan := c.palette[ansiCyan]
	magenta, hasMagenta := c.palette[ansiMagenta]
	if hasCyan && hasBlue && hasMagenta {
		out.brandFrom, out.brandTo = cyan.hex(), blue.mix(magenta, 0.5).hex()
	}
	return out, true
}

var oscColor = regexp.MustCompile(`\x1b\](10|11|4;(\d+));rgb:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})`)

// parseColors reads OSC 10, 11 and 4 replies, whose channels carry one to
// four hex digits each.
func parseColors(reply string) termColors {
	c := termColors{palette: map[int]rgb{}}
	for _, m := range oscColor.FindAllStringSubmatch(reply, -1) {
		channel := func(h string) float64 {
			v, _ := strconv.ParseUint(h, 16, 16)
			return float64(v) / float64(uint64(1)<<(4*len(h))-1)
		}
		col := &rgb{channel(m[3]), channel(m[4]), channel(m[5])}
		switch m[1] {
		case "10":
			c.fg = col
		case "11":
			c.bg = col
		default:
			index, _ := strconv.Atoi(m[2])
			c.palette[index] = *col
		}
	}
	return c
}

var transcriptInk ink

// DetectInk asks the terminal for its colors and mixes the transcript's
// ramp from them. It must run before the TUI owns the terminal's input.
func DetectInk() {
	reply := queryColors()
	detected, ok := mixInk(parseColors(reply))
	if path := os.Getenv("ALBEDO_INK_DEBUG"); path != "" {
		_ = os.WriteFile(path, fmt.Appendf(nil, "reply %q\ntrusted %v\nink %+v\n", reply, ok, detected), 0o644)
	}
	if ok {
		useInk(detected)
	}
}
