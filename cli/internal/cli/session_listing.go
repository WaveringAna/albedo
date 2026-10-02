package cli

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/presentation"
	"fmt"
	"strings"
	"text/tabwriter"
	"time"
)

func sessionListing(sessions []daemon.Session, now time.Time) string {
	if len(sessions) == 0 {
		return "no sessions"
	}

	var listing strings.Builder
	writer := tabwriter.NewWriter(&listing, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "ID\tTITLE\tWORKSPACE\tLAST ASSISTANT")
	for _, session := range sessions {
		title := presentation.SessionText(session.Title)
		title = strings.TrimSpace(title)
		if title == "" {
			title = "session name unavailable"
		}
		shortID := session.ID
		if len(shortID) > 8 {
			shortID = shortID[:8]
		}
		workspace := presentation.SessionText(strings.TrimSpace(session.Workspace))
		if workspace == "" {
			workspace = "—"
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", shortID, title, workspace, presentation.AssistantAge(session.LastAssistantAt, now))
	}
	_ = writer.Flush()
	return strings.TrimRight(listing.String(), "\n")
}
