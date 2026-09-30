package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

var (
	commandTokenPattern = regexp.MustCompile(`^/[^\s]+`)
	commandExactPattern = regexp.MustCompile(`^/[^\s]+$`)
	methodPattern       = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
)

type CommandArgument struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Choices     []string `json:"choices,omitempty"`
	Required    bool     `json:"required"`
}

type SessionCommand struct {
	Page          *bool             `json:"page,omitempty"`
	Name          string            `json:"name"`
	Description   string            `json:"description"`
	Method        string            `json:"method"`
	Arguments     []CommandArgument `json:"arguments"`
	ModelCallable bool              `json:"modelCallable"`
	UserTurn      bool              `json:"userTurn"`
}

type CommandMenuItem struct {
	Name        string
	Description string
}

// CommandMenuItems flattens command catalog into runnable menu entries.
func CommandMenuItems(catalog []SessionCommand) []CommandMenuItem {
	var items []CommandMenuItem
	for _, cmd := range catalog {
		if len(cmd.Arguments) > 0 && cmd.Arguments[0].Required && len(cmd.Arguments[0].Choices) > 0 {
			for _, choice := range cmd.Arguments[0].Choices {
				items = append(items, CommandMenuItem{
					Name:        fmt.Sprintf("%s %s", cmd.Name, choice),
					Description: cmd.Arguments[0].Description,
				})
			}
		} else {
			items = append(items, CommandMenuItem{
				Name:        cmd.Name,
				Description: cmd.Description,
			})
		}
	}
	return items
}

func isValidCommand(cmd SessionCommand) bool {
	if !commandExactPattern.MatchString(cmd.Name) {
		return false
	}
	if !methodPattern.MatchString(cmd.Method) {
		return false
	}
	for _, arg := range cmd.Arguments {
		if arg.Name == "" || arg.Description == "" {
			return false
		}
	}
	return true
}

// ParseCommandCatalog validates command catalog JSON from daemon.
func ParseCommandCatalog(data []byte) ([]SessionCommand, error) {
	var rawList []json.RawMessage
	if err := json.Unmarshal(data, &rawList); err != nil {
		return nil, fmt.Errorf("decode command catalog: %w", err)
	}

	commands := make([]SessionCommand, 0, len(rawList))
	for _, raw := range rawList {
		var cmd SessionCommand
		if err := json.Unmarshal(raw, &cmd); err != nil || !isValidCommand(cmd) {
			continue
		}
		commands = append(commands, cmd)
	}

	if len(rawList) > 0 && len(commands) == 0 {
		return nil, errors.New("cannot read command details returned by Albedo")
	}

	return commands, nil
}

// ParseCommandInvocation extracts matched command and arguments from user input.
func ParseCommandInvocation(value string, catalog []SessionCommand) (name, args string, ok bool) {
	loc := commandTokenPattern.FindStringIndex(value)
	if loc == nil {
		return "", "", false
	}
	token := value[loc[0]:loc[1]]
	var matched *SessionCommand
	for i := range catalog {
		if catalog[i].Name == token {
			matched = &catalog[i]
			break
		}
	}
	if matched == nil {
		return "", "", false
	}

	rest := strings.TrimPrefix(value[loc[1]:], " ")
	return matched.Name, rest, true
}
