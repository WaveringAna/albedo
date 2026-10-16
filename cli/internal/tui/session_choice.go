package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"slices"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// sessionChoice is a form's session picker: the sessions it offers in order,
// the one the screen was opened from, and the one chosen, which starts there.
// The form's field text filters the offer.
type sessionChoice struct {
	Sessions        []daemon.Session
	Current, Chosen string
}

// matches are the sessions query leaves, in order.
func (c sessionChoice) matches(query string) []daemon.Session {
	query = strings.ToLower(strings.TrimSpace(query))
	var out []daemon.Session
	for _, s := range c.Sessions {
		if query == "" || strings.Contains(strings.ToLower(sessionTitle(s)+" "+homePath(s.Workspace)+" "+s.ID), query) {
			out = append(out, s)
		}
	}
	return out
}

func (c sessionChoice) chosenIndex(matches []daemon.Session) int {
	return slices.IndexFunc(matches, func(s daemon.Session) bool { return s.ID == c.Chosen })
}

// step chooses the next (left: previous) match, wrapping around; it reports
// whether the key was for the picker.
func (c *sessionChoice) step(query, key string) bool {
	matches := c.matches(query)
	if (key != "left" && key != "right") || len(matches) == 0 {
		return false
	}
	i := c.chosenIndex(matches)
	if i < 0 {
		i = 0
	} else {
		by := 1
		if key == "left" {
			by = -1
		}
		i = (i + by + len(matches)) % len(matches)
	}
	c.Chosen = matches[i].ID
	return true
}

// follow keeps the choice among the matches after the query changed.
func (c *sessionChoice) follow(query string) {
	if matches := c.matches(query); len(matches) > 0 && c.chosenIndex(matches) < 0 {
		c.Chosen = matches[0].ID
	}
}

// label names the chosen session.
func (c sessionChoice) label() string { return sessionLabel(c.Sessions, c.Chosen, c.Current) }

// rows lists the matching sessions around the chosen one.
func (c sessionChoice) rows(query, indent string, width int) []string {
	matches := c.matches(query)
	if len(matches) == 0 {
		return []string{indent + DefaultStyles.Faint.Render("No sessions match. Try another search.")}
	}
	chosen := max(0, c.chosenIndex(matches))
	start := max(0, min(chosen-sessionChoices/2, len(matches)-sessionChoices))
	var rows []string
	w := width - len(indent)
	for i := start; i < min(len(matches), start+sessionChoices); i++ {
		label := sessionLabel(c.Sessions, matches[i].ID, c.Current)
		if i == chosen {
			rows = append(rows, indent+selectedLine(ansi.Truncate(selectBar()+" "+label, w, "…"), w))
		} else {
			rows = append(rows, indent+DefaultStyles.Faint.Render(ansi.Truncate("  "+label, w, "…")))
		}
	}
	if more := len(matches) - sessionChoices; more > 0 {
		rows = append(rows, indent+DefaultStyles.Faint.Render(fmt.Sprintf("  %d more · type to filter", more)))
	}
	return rows
}

// sessionChoices is how many matching sessions a picker shows at once.
const sessionChoices = 5
