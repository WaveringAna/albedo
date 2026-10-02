package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
)

var (
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
	Skill         bool              `json:"skill"`
	UserTurn      bool              `json:"userTurn"`
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

// parseCommandCatalog validates command catalog JSON from daemon.
func parseCommandCatalog(data []byte) ([]SessionCommand, error) {
	var entries []struct {
		Name          *string `json:"name"`
		Description   *string `json:"description"`
		Method        *string `json:"method"`
		ModelCallable *bool   `json:"modelCallable"`
		UserTurn      *bool   `json:"userTurn"`
		Skill         bool    `json:"skill"`
		Page          *bool   `json:"page"`
		Arguments     []struct {
			Name        *string         `json:"name"`
			Description *string         `json:"description"`
			Required    *bool           `json:"required"`
			Choices     json.RawMessage `json:"choices"`
		} `json:"arguments"`
	}
	if err := json.Unmarshal(data, &entries); err != nil {
		return nil, fmt.Errorf("decode command catalog: %w", err)
	}
	if entries == nil {
		return nil, errors.New("expected a command array")
	}
	commands := make([]SessionCommand, 0, len(entries))
	for _, entry := range entries {
		if entry.Name == nil || entry.Description == nil || entry.Method == nil || entry.ModelCallable == nil || entry.UserTurn == nil || entry.Arguments == nil {
			return nil, errors.New("incomplete command catalog entry")
		}
		cmd := SessionCommand{
			Name:          *entry.Name,
			Description:   *entry.Description,
			Method:        *entry.Method,
			ModelCallable: *entry.ModelCallable,
			UserTurn:      *entry.UserTurn,
			Skill:         entry.Skill,
			Page:          entry.Page,
			Arguments:     make([]CommandArgument, 0, len(entry.Arguments)),
		}
		for _, argument := range entry.Arguments {
			if argument.Name == nil || argument.Description == nil || argument.Required == nil {
				return nil, errors.New("incomplete command argument")
			}
			arg := CommandArgument{Name: *argument.Name, Description: *argument.Description, Required: *argument.Required}
			if argument.Choices != nil {
				var choices stringCollection
				if err := json.Unmarshal(argument.Choices, &choices); err != nil {
					return nil, err
				}
				if choices == nil {
					return nil, fieldError("choices")
				}
				arg.Choices = []string(choices)
			}
			cmd.Arguments = append(cmd.Arguments, arg)
		}
		if !isValidCommand(cmd) {
			return nil, errors.New("invalid command catalog entry")
		}
		commands = append(commands, cmd)
	}
	return commands, nil
}
