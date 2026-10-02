package presentation

import (
	"fmt"
	"regexp"
	"time"
)

var sanitizerRegex = regexp.MustCompile(`[\p{Cc}\x{202a}-\x{202e}\x{2066}-\x{2069}]`)

// SessionText replaces control characters and direction overrides in session metadata.
func SessionText(text string) string { return sanitizerRegex.ReplaceAllString(text, " ") }

func AssistantAge(timestamp *int64, now time.Time) string {
	if timestamp == nil {
		return "time unknown"
	}
	elapsedSeconds := max(0, now.Unix()-*timestamp)
	if elapsedSeconds < 60 {
		return "just now"
	}
	if elapsedSeconds < 3600 {
		return fmt.Sprintf("%dm ago", elapsedSeconds/60)
	}
	if elapsedSeconds < 86400 {
		return fmt.Sprintf("%dh ago", elapsedSeconds/3600)
	}
	return fmt.Sprintf("%dd ago", elapsedSeconds/86400)
}
