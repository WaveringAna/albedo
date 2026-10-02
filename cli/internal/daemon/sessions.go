package daemon

import (
	"fmt"
	"regexp"
	"strings"
	"text/tabwriter"
	"time"
)

var sanitizerRegex = regexp.MustCompile(`[\p{Cc}\x{202a}-\x{202e}\x{2066}-\x{2069}]`)

// SessionText replaces control characters and direction overrides in session metadata.
func SessionText(s string) string { return sanitizerRegex.ReplaceAllString(s, " ") }

type Session struct {
	ID              string `json:"id"`
	Title           string `json:"title,omitempty"`
	LastAssistantAt *int64 `json:"last_assistant_at,omitempty"`
	Workspace       string `json:"workspace"`
	Model           string `json:"model"`
	Effort          string `json:"effort,omitempty"`
	Protocol        string `json:"protocol"`
	Provider        string `json:"provider"`
}

func AssistantAge(timestamp *int64, now time.Time) string {
	if timestamp == nil {
		return "time unknown"
	}
	sec := max(0, now.Unix()-*timestamp)
	if sec < 60 {
		return "just now"
	}
	if sec < 3600 {
		return fmt.Sprintf("%dm ago", sec/60)
	}
	if sec < 86400 {
		return fmt.Sprintf("%dh ago", sec/3600)
	}
	return fmt.Sprintf("%dd ago", sec/86400)
}

func SessionListing(sessions []Session, now time.Time) string {
	if len(sessions) == 0 {
		return "no sessions"
	}

	var listing strings.Builder
	writer := tabwriter.NewWriter(&listing, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "ID\tTITLE\tWORKSPACE\tLAST ASSISTANT")
	for _, s := range sessions {
		title := SessionText(s.Title)
		title = strings.TrimSpace(title)
		if title == "" {
			title = "session name unavailable"
		}
		shortID := s.ID
		if len(shortID) > 8 {
			shortID = shortID[:8]
		}
		workspace := SessionText(strings.TrimSpace(s.Workspace))
		if workspace == "" {
			workspace = "—"
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", shortID, title, workspace, AssistantAge(s.LastAssistantAt, now))
	}
	_ = writer.Flush()
	return strings.TrimRight(listing.String(), "\n")
}
