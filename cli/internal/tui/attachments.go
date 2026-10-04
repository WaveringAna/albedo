package tui

import (
	"albedo/cli/internal/daemon"
	"regexp"
	"strconv"
	"strings"
)

const (
	// MaxPromptImages is how many images one prompt may attach.
	MaxPromptImages = 10
	// A paste longer than either collapses into a marker.
	collapseLines = 10
	collapseChars = 1000
)

var (
	imageMarker = regexp.MustCompile(`\[Image #(\d+)\]`)
	pasteMarker = regexp.MustCompile(`\[Paste #(\d+)(?:, [^\]\n]*)?\]`)
	// anyMarker is what one backspace or delete removes whole.
	anyMarker = regexp.MustCompile(`\[(?:Image|Paste) #\d+(?:, [^\]\n]*)?\]`)
)

// markerKind says how one kind of attachment is marked in the prompt.
type markerKind[T any] interface {
	pattern() *regexp.Regexp
	marker(n int, item T) string
}

// pastedImage is an image in the composer and, when the terminal shows
// them, its thumbnail.
type pastedImage struct {
	daemon.ImageAttachment
	thumb *thumbnail
}

// unseen wraps images restored from a sent prompt, whose thumbnails the
// terminal may no longer hold.
func unseen(images []daemon.ImageAttachment) []pastedImage {
	pasted := make([]pastedImage, len(images))
	for i, image := range images {
		pasted[i] = pastedImage{ImageAttachment: image}
	}
	return pasted
}

type imageKind struct{}

func (imageKind) pattern() *regexp.Regexp { return imageMarker }

func (imageKind) marker(n int, _ pastedImage) string {
	return "[Image #" + strconv.Itoa(n) + "]"
}

type pasteKind struct{}

func (pasteKind) pattern() *regexp.Regexp { return pasteMarker }

func (pasteKind) marker(n int, text string) string {
	if lines := strings.Count(text, "\n") + 1; lines > collapseLines {
		return "[Paste #" + strconv.Itoa(n) + ", +" + strconv.Itoa(lines) + " lines]"
	}
	return "[Paste #" + strconv.Itoa(n) + ", " + strconv.Itoa(len([]rune(text))) + " chars]"
}

// attachments holds what was pasted into the composer under the number its
// marker carries. Deleting a marker drops its item from the prompt.
type attachments[T any, K markerKind[T]] struct {
	byNumber map[int]T
	next     int
	kind     K
}

type (
	promptImages = attachments[pastedImage, imageKind]
	promptPastes = attachments[string, pasteKind]
)

// collapses reports whether pasted text is long enough to become a marker.
func collapses(text string) bool {
	return strings.Count(text, "\n") >= collapseLines || len([]rune(text)) > collapseChars
}

// add keeps item and returns the marker to insert at the cursor.
func (a *attachments[T, K]) add(item T) string {
	if a.byNumber == nil {
		a.byNumber = make(map[int]T)
	}
	a.next++
	a.byNumber[a.next] = item
	return a.kind.marker(a.next, item)
}

// restore replaces the items with ones numbered 1..n, as a resolved prompt
// marks them.
func (a *attachments[T, K]) restore(items []T) {
	a.byNumber, a.next = nil, 0
	for _, item := range items {
		a.add(item)
	}
}

// referenced returns the numbers of the items text still marks, in reading
// order, each once.
func (a attachments[T, K]) referenced(text string) []int {
	var numbers []int
	seen := make(map[int]bool)
	for _, match := range a.kind.pattern().FindAllStringSubmatch(text, -1) {
		n, _ := strconv.Atoi(match[1])
		if _, ok := a.byNumber[n]; ok && !seen[n] {
			seen[n] = true
			numbers = append(numbers, n)
		}
	}
	return numbers
}

// resolve numbers the marked items 1..n in reading order and returns the
// text with its markers renumbered to match, and the items in that order.
// Markers for numbers never pasted stay as typed.
func (a attachments[T, K]) resolve(text string) (string, []T) {
	numbers := a.referenced(text)
	renumbered := make(map[int]int, len(numbers))
	items := make([]T, len(numbers))
	for i, n := range numbers {
		renumbered[n] = i + 1
		items[i] = a.byNumber[n]
	}
	pattern := a.kind.pattern()
	text = pattern.ReplaceAllStringFunc(text, func(marker string) string {
		n, _ := strconv.Atoi(pattern.FindStringSubmatch(marker)[1])
		if to, ok := renumbered[n]; ok {
			return a.kind.marker(to, a.byNumber[n])
		}
		return marker
	})
	return text, items
}

// markerSpan returns the rune span of the marker in line that a backspace at
// col (backward) or a delete at col (forward) would cut into.
func markerSpan(line []rune, col int, backward bool) (int, int, bool) {
	text := string(line)
	for _, span := range anyMarker.FindAllStringIndex(text, -1) {
		start := len([]rune(text[:span[0]]))
		end := start + len([]rune(text[span[0]:span[1]]))
		if backward && start < col && col <= end || !backward && start <= col && col < end {
			return start, end, true
		}
	}
	return 0, 0, false
}
