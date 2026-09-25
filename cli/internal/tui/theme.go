package tui

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// The theme is the only place colors are chosen. Screens compose these
// styles and components, so the transcript, the session screen, and the
// pickers cannot drift into their own palettes.
//
// Tokens come in three kinds:
//   - ink, a brightness ramp mixed from the terminal's own colors: prose
//     keeps the terminal foreground, then Muted, Faint and Decor step down
//   - identity: You and Agent, and Busy for albedo working in tools
//   - state: Error, Warning and Success
//
// Without reported terminal colors every token falls back to a palette slot.
type Styles struct {
	// Muted is text worth reading that steps back from prose: keys,
	// metadata, section labels.
	Muted lipgloss.Style
	// Faint is text read at a glance: tool rows, timings, hints.
	Faint lipgloss.Style
	// Decor is structure seen, not read: rules, separators, markers.
	Decor lipgloss.Style
	Bold  lipgloss.Style

	You   lipgloss.Style
	Agent lipgloss.Style
	Busy  lipgloss.Style

	Error   lipgloss.Style
	Warning lipgloss.Style
	Success lipgloss.Style

	// Prompt marks where you type.
	Prompt lipgloss.Style
	// Selected is the surface under a selected row: a tint where the
	// terminal reported its colors, reverse video where it did not.
	Selected lipgloss.Style
	// Cursor is the text cursor and a drag selection.
	Cursor lipgloss.Style
}

var DefaultStyles = Styles{
	Muted:    lipgloss.NewStyle().Foreground(lipgloss.Color("7")),
	Faint:    lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
	Decor:    lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
	Bold:     lipgloss.NewStyle().Bold(true),
	You:      lipgloss.NewStyle().Foreground(lipgloss.Color("6")),
	Agent:    lipgloss.NewStyle().Foreground(lipgloss.Color("5")),
	Busy:     lipgloss.NewStyle().Foreground(lipgloss.Color("5")).Faint(true),
	Error:    lipgloss.NewStyle().Foreground(lipgloss.Color("1")),
	Warning:  lipgloss.NewStyle().Foreground(lipgloss.Color("3")),
	Success:  lipgloss.NewStyle().Foreground(lipgloss.Color("2")),
	Prompt:   lipgloss.NewStyle().Foreground(lipgloss.Color("6")),
	Selected: lipgloss.NewStyle().Reverse(true),
	Cursor:   lipgloss.NewStyle().Reverse(true),
}

func useInk(detected ink) {
	transcriptInk = detected
	fg := func(hex string) lipgloss.Style { return lipgloss.NewStyle().Foreground(lipgloss.Color(hex)) }
	DefaultStyles.Muted = fg(detected.code)
	DefaultStyles.Faint = fg(detected.secondary)
	DefaultStyles.Decor = fg(detected.decor)
	if detected.busy != "" {
		DefaultStyles.Busy = fg(detected.busy)
	}
	DefaultStyles.Selected = lipgloss.NewStyle().Background(lipgloss.Color(detected.surface))
}

const (
	ansiReset  = "\x1b[0m"
	ansiBold   = "\x1b[1m"
	ansiItalic = "\x1b[3m"
	ansiGray   = "\x1b[90m"
)

// sgr is a foreground color as an escape sequence for the active color
// profile, or fallback when the ramp is unknown.
func sgr(hex, fallback string) string { return sgrLayer(hex, fallback, false) }

func sgrLayer(hex, fallback string, background bool) string {
	if hex == "" {
		return fallback
	}
	seq := lipgloss.ColorProfile().Color(hex).Sequence(background)
	if seq == "" {
		return ""
	}
	return "\x1b[" + seq + "m"
}

// codeInk steps code down from prose so a reply that decorates every
// identifier stays quiet.
func codeInk() string { return sgr(transcriptInk.code, "\x1b[37m") }

// faintInk is the Faint token as a raw sequence, for markdown's own spans.
func faintInk() string { return sgr(transcriptInk.secondary, ansiGray) }

// decorInk is the Decor token as a raw sequence.
func decorInk() string { return sgr(transcriptInk.decor, ansiGray) }

// inlineCodeInk sets inline code on a tint in the prose color, where the
// terminal reported its colors. Without them it falls back to the code ink.
func inlineCodeInk() string {
	if bg := sgrLayer(transcriptInk.codeBg, "", true); bg != "" {
		return bg
	}
	return codeInk()
}

// Diff rows sit on tints mixed toward the palette's red and green. The
// fallbacks are dark tints, the only case without reported colors.
func diffPanel() string   { return sgrLayer(transcriptInk.surface, "\x1b[48;2;37;40;50m", true) }
func diffAdded() string   { return sgrLayer(transcriptInk.added, "\x1b[48;2;24;53;39m", true) }
func diffRemoved() string { return sgrLayer(transcriptInk.removed, "\x1b[48;2;59;35;40m", true) }

// keepBackground turns full resets into foreground and attribute resets, so
// a styled span inside a tinted row keeps the row's background.
func keepBackground(s string) string {
	return strings.ReplaceAll(s, ansiReset, "\x1b[39;22;23m")
}

// gradient is the brand ramp at t in [0, 1], or nil when the terminal did
// not report the colors it is mixed from.
func gradient(t float64) lipgloss.TerminalColor {
	from, to := parseHex(transcriptInk.brandFrom), parseHex(transcriptInk.brandTo)
	if from == nil || to == nil {
		return nil
	}
	return lipgloss.Color(from.mix(*to, min(1, max(0, t))).hex())
}

func parseHex(hex string) *rgb {
	var r, g, b int
	if _, err := fmt.Sscanf(hex, "#%02x%02x%02x", &r, &g, &b); err != nil {
		return nil
	}
	return &rgb{float64(r) / 255, float64(g) / 255, float64(b) / 255}
}

// gradientText sweeps the brand ramp across s. Without it s takes the agent
// color.
func gradientText(s string, bold bool) string {
	if gradient(0) == nil {
		return DefaultStyles.Agent.Bold(bold).Render(s)
	}
	runes := []rune(s)
	var b strings.Builder
	for i, r := range runes {
		t := float64(i) / float64(max(1, len(runes)-1))
		b.WriteString(lipgloss.NewStyle().Foreground(gradient(t)).Bold(bold).Render(string(r)))
	}
	return b.String()
}

// brandInk colors a mark along the brand ramp, or in the agent color.
func brandInk(t float64) lipgloss.Style {
	if c := gradient(t); c != nil {
		return lipgloss.NewStyle().Foreground(c)
	}
	return DefaultStyles.Agent
}

func brand(name string) string { return gradientText("✦ "+name, true) }

// titleRule heads a screen: left, a rule that fades from the brand's end
// into Decor, then right.
func titleRule(width int, left, right string) string {
	if right != "" {
		right = " " + right
	}
	n := width - ansi.StringWidth(left) - ansi.StringWidth(right) - 1
	if n < 3 {
		return left
	}
	var rule strings.Builder
	from, to := parseHex(transcriptInk.brandTo), parseHex(transcriptInk.decor)
	for i := range n {
		t := float64(i) / float64(n)
		if from != nil && to != nil && t < 0.35 {
			rule.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color(from.mix(*to, t/0.35).hex())).Render("─"))
			continue
		}
		rule.WriteString(DefaultStyles.Decor.Render("─"))
	}
	return left + " " + rule.String() + right
}

// located is the brand at a place: "✦ albedo on ~/path".
func located(name, place string) string {
	if place == "" {
		return brand(name)
	}
	return brand(name) + DefaultStyles.Faint.Render(" on ") + DefaultStyles.Muted.Render(place)
}

// hint is a key and what it does.
type hint struct{ key, does string }

// keyHints lists keys in Muted and what they do in Faint. A hint without a
// key is a plain note.
func keyHints(hints ...hint) string {
	parts := make([]string, 0, len(hints))
	for _, h := range hints {
		var part string
		switch {
		case h.key == "":
			part = DefaultStyles.Faint.Render(h.does)
		case h.does == "":
			part = DefaultStyles.Muted.Render(h.key)
		default:
			part = DefaultStyles.Muted.Render(h.key) + " " + DefaultStyles.Faint.Render(h.does)
		}
		parts = append(parts, part)
	}
	return strings.Join(parts, DefaultStyles.Decor.Render(" · "))
}

// sectionRule heads a group in a list: " ─ label count ────".
func sectionRule(label string, count, width int) string {
	head := " " + label + " "
	tail := fmt.Sprintf("%d ", count)
	rule := strings.Repeat("─", max(0, width-2-ansi.StringWidth(head+tail)))
	return DefaultStyles.Decor.Render(" ─") + DefaultStyles.Muted.Bold(true).Render(head) + DefaultStyles.Decor.Render(tail+rule)
}

// promptMark is where you type.
const promptMark = "› "
const promptMarkWidth = 2

func promptLead() string { return DefaultStyles.Prompt.Render(promptMark) }

// selectBar marks the selected row.
func selectBar() string { return DefaultStyles.Agent.Render("▌") }

// selectedLine lays the selection surface under a styled line, reopening it
// after every reset inside the line, and fills it out to width.
func selectedLine(line string, width int) string {
	marked := DefaultStyles.Selected.Render("\x00")
	open := marked[:strings.IndexByte(marked, 0)]
	if pad := width - ansi.StringWidth(line); pad > 0 {
		line += strings.Repeat(" ", pad)
	}
	return open + strings.ReplaceAll(line, ansiReset, ansiReset+open) + ansiReset
}

// homePath shortens a path under your home directory to start with ~.
func homePath(p string) string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		if p == home {
			return "~"
		}
		if strings.HasPrefix(p, home+string(filepath.Separator)) {
			return "~" + p[len(home):]
		}
	}
	return p
}
