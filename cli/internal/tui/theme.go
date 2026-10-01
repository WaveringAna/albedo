package tui

import (
	"cmp"
	"fmt"
	"hash/fnv"
	"image/color"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// Styles defines the shared terminal palette. Screens compose these
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
	// Effort tiers form a cool-to-warm scale; max is violet.
	EffortLow    lipgloss.Style
	EffortMedium lipgloss.Style
	EffortHigh   lipgloss.Style
	EffortXHigh  lipgloss.Style
	EffortMax    lipgloss.Style
	// Cursor is the text cursor and a drag selection.
	Cursor lipgloss.Style
}

var DefaultStyles = Styles{
	Muted:        lipgloss.NewStyle().Foreground(lipgloss.Color("7")),
	Faint:        lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
	Decor:        lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
	Bold:         lipgloss.NewStyle().Bold(true),
	You:          lipgloss.NewStyle().Foreground(lipgloss.Color("6")),
	Agent:        lipgloss.NewStyle().Foreground(lipgloss.Color("5")),
	Busy:         lipgloss.NewStyle().Foreground(lipgloss.Color("5")).Faint(true),
	Error:        lipgloss.NewStyle().Foreground(lipgloss.Color("1")),
	Warning:      lipgloss.NewStyle().Foreground(lipgloss.Color("3")),
	Success:      lipgloss.NewStyle().Foreground(lipgloss.Color("2")),
	Prompt:       lipgloss.NewStyle().Foreground(lipgloss.Color("6")),
	Selected:     lipgloss.NewStyle().Reverse(true),
	EffortLow:    lipgloss.NewStyle().Foreground(lipgloss.Color("#8DCFF5")),
	EffortMedium: lipgloss.NewStyle().Foreground(lipgloss.Color("#78CFC3")),
	EffortHigh:   lipgloss.NewStyle().Foreground(lipgloss.Color("#F3AD68")),
	EffortXHigh:  lipgloss.NewStyle().Foreground(lipgloss.Color("#F27979")),
	EffortMax:    lipgloss.NewStyle().Foreground(lipgloss.Color("#C39AF5")),
	Cursor:       lipgloss.NewStyle().Reverse(true),
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

// newTextInput is a text input in the theme: plain text and prompt whether
// focused or not, and a reverse-video cursor that holds still, so an idle
// input never wakes the program to blink.
func newTextInput() textinput.Model {
	ti := textinput.New()
	s := ti.Styles()
	s.Focused.Prompt, s.Focused.Text = lipgloss.NewStyle(), lipgloss.NewStyle()
	s.Blurred = s.Focused
	s.Cursor = textinput.CursorStyle{Shape: tea.CursorBlock}
	ti.SetStyles(s)
	return ti
}

const (
	ansiReset  = "\x1b[0m"
	ansiItalic = "\x1b[3m"
	ansiGray   = "\x1b[90m"
)

// sgr is a foreground color as an escape sequence, or fallback when the
// ramp is unknown. Bubble Tea downsamples it to the terminal's profile.
func sgr(hex, fallback string) string { return sgrLayer(hex, fallback, false) }

func sgrLayer(hex, fallback string, background bool) string {
	if parseHex(hex) == nil {
		return fallback
	}
	if background {
		return ansi.NewStyle().BackgroundColor(lipgloss.Color(hex)).String()
	}
	return ansi.NewStyle().ForegroundColor(lipgloss.Color(hex)).String()
}

// codeInk steps code down from prose so a reply that decorates every
// identifier stays quiet.
func codeInk() string { return sgr(transcriptInk.code, "\x1b[37m") }

// faintInk is the Faint token as a raw sequence, for markdown's own spans.
func faintInk() string { return sgr(transcriptInk.secondary, ansiGray) }

// decorInk is the Decor token as a raw sequence.
func decorInk() string { return sgr(transcriptInk.decor, ansiGray) }

// Diff rows sit on tints mixed toward the palette's red and green. The
// fallbacks are dark tints, the only case without reported colors.
func diffPanel() string   { return sgrLayer(transcriptInk.surface, "\x1b[48;2;37;40;50m", true) }
func diffAdded() string   { return sgrLayer(transcriptInk.added, "\x1b[48;2;24;53;39m", true) }
func diffRemoved() string { return sgrLayer(transcriptInk.removed, "\x1b[48;2;59;35;40m", true) }

// keepBackground turns full resets into foreground and attribute resets, so
// a styled span inside a tinted row keeps the row's background. Lip Gloss
// spells a full reset "ESC[m"; the raw ink spells it "ESC[0m".
func keepBackground(s string) string {
	return strings.NewReplacer(ansiReset, "\x1b[39;22;23m", "\x1b[m", "\x1b[39;22;23m").Replace(s)
}

// gradient is the brand ramp at t in [0, 1], or nil when the terminal did
// not report the colors it is mixed from.
func gradient(t float64) color.Color {
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
	return ramp(rampKey{text: s, bold: bold}, func() string {
		runes := []rune(s)
		var b strings.Builder
		st := lipgloss.NewStyle().Bold(bold)
		for i, r := range runes {
			t := float64(i) / float64(max(1, len(runes)-1))
			b.WriteString(st.Foreground(gradient(t)).Render(string(r)))
		}
		return b.String()
	})
}

// rampKey names a rendering of the brand ramp: text swept by it, or a rule
// of rule cells fading from it.
type rampKey struct {
	text string
	bold bool
	rule int
}

// ramps keeps renderings of the brand ramp. They change only with the
// detected ink, and every frame's header asks for the same few again.
var ramps struct {
	byKey map[rampKey]string
	ink   ink
	sync.Mutex
}

func ramp(key rampKey, render func() string) string {
	ramps.Lock()
	defer ramps.Unlock()
	if ramps.byKey == nil || ramps.ink != transcriptInk || len(ramps.byKey) > 256 {
		ramps.ink, ramps.byKey = transcriptInk, map[rampKey]string{}
	}
	s, ok := ramps.byKey[key]
	if !ok {
		s = render()
		ramps.byKey[key] = s
	}
	return s
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
// into Decor, then right. Without room for one rule cell it is left alone.
func titleRule(width int, left, right string) string {
	if right != "" {
		right = " " + right
	}
	n := width - ansi.StringWidth(left) - ansi.StringWidth(right) - 1
	if n < 1 {
		return left
	}
	return left + " " + ramp(rampKey{rule: n}, func() string { return fadeRule(n) }) + right
}

// fadeRule is n rule cells fading from the brand's end into Decor.
func fadeRule(n int) string {
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
	return rule.String()
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
	parts := make([]string, len(hints))
	for i, h := range hints {
		switch {
		case h.key == "":
			parts[i] = DefaultStyles.Faint.Render(h.does)
		case h.does == "":
			parts[i] = DefaultStyles.Muted.Render(h.key)
		default:
			parts[i] = DefaultStyles.Muted.Render(h.key) + " " + DefaultStyles.Faint.Render(h.does)
		}
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
	return open + strings.NewReplacer(ansiReset, ansiReset+open, "\x1b[m", "\x1b[m"+open).Replace(line) + ansiReset
}

// homePath shortens a path under your home directory to start with ~.
func homePath(p string) string {
	home, _ := os.UserHomeDir()
	return underHome(p, home)
}

// pathFolds shortens a path by folding its middle into "…" one more segment
// at a time, keeping its root and its name: ~/a/b/c, ~/…/b/c, ~/…/c.
func pathFolds(p string) []string {
	sep := string(filepath.Separator)
	parts := strings.Split(p, sep)
	folds := []string{p}
	for keep := len(parts) - 2; keep >= 1; keep-- {
		folds = append(folds, strings.Join(append([]string{parts[0], "…"}, parts[len(parts)-keep:]...), sep))
	}
	return folds
}

// underHome shortens p under home to start with ~.
func underHome(p, home string) string {
	rest, ok := strings.CutPrefix(p, home)
	if home == "" || !ok || rest != "" && rest[0] != filepath.Separator {
		return p
	}
	return "~" + rest
}

// languageHues are our own colors for common languages, by linguist name.
// Each starts from linguist's hue, softened to a pastel and nudged so
// languages that often share a repository stay apart.
var languageHues = map[string]string{
	"Go":         "#6fd1c4",
	"Nix":        "#b9a6f5",
	"TypeScript": "#80aaf9",
	"Gleam":      "#f28fb8",
	"Erlang":     "#ef7a85",
	"Python":     "#f0c674",
	"Markdown":   "#b6e37a",
	"Rust":       "#f5a97f",
	"JavaScript": "#e9e48a",
	"Shell":      "#8fdc9a",
	"C":          "#a3b4c8",
	"Elixir":     "#d4a0d8",
	"Java":       "#dcb68a",
}

// languageLc is the contrast a language's color keeps with the background:
// file names are read, so about what content text gets.
const languageLc = 60

// languageStyle colors a language: our hue for it, else linguist's, adapted
// to the terminal. A language with neither steps back like other metadata.
func languageStyle(name, linguist string) lipgloss.Style {
	c := parseHex(cmp.Or(languageHues[name], linguist))
	if c == nil {
		return DefaultStyles.Muted
	}
	if bg := parseHex(transcriptInk.bg); bg != nil {
		*c = legible(*c, *bg, languageLc)
	}
	return lipgloss.NewStyle().Foreground(lipgloss.Color(c.hex()))
}

// identityHues tell things apart that have no meaning of their own to show:
// agents in the orchestrator view, hosts beside their paths.
var identityHues = []string{"#e08cf5", "#6fd1c4", "#f28fb8", "#f0c674", "#b6e37a", "#b9a6f5", "#80aaf9", "#f5a97f"}

// hostStyle colors a host label the same way every time, legible on the
// terminal's background like a language's color.
func hostStyle(host string) lipgloss.Style {
	h := fnv.New32a()
	h.Write([]byte(host))
	c := parseHex(identityHues[h.Sum32()%uint32(len(identityHues))])
	if bg := parseHex(transcriptInk.bg); bg != nil {
		*c = legible(*c, *bg, languageLc)
	}
	return lipgloss.NewStyle().Foreground(lipgloss.Color(c.hex()))
}

// agentPalette colors the orchestrator view. Each agent keeps one identity
// hue wherever it appears; structure and quiet text follow the terminal's
// own ink like every other screen.
type agentPalette struct {
	hues                        []rgb
	you, mail, faint, decor, hi rgb
}

func agentColors() agentPalette {
	hex := func(val, fallback string) rgb {
		if c := parseHex(val); c != nil {
			return *c
		}
		return *parseHex(fallback)
	}
	hues := make([]rgb, len(identityHues))
	for i, h := range identityHues {
		hues[i] = *parseHex(h)
	}
	return agentPalette{
		hues:  hues,
		you:   *parseHex("#7fd8e6"),
		mail:  *parseHex("#f0c674"),
		faint: hex(transcriptInk.secondary, "#6a6378"),
		decor: hex(transcriptInk.decor, "#3a3448"),
		hi:    *parseHex("#ffffff"),
	}
}
