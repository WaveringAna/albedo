package daemon

import (
	"encoding/json"
	"slices"
	"strings"
)

type CommandArgument struct {
	Name, Description, Type string
	Choices                 []string
	Required                bool
	field                   wireFormField
}
type SessionCommand struct {
	Page                                               *bool
	Name, Description, Method, ID, Delivery, CommandID string
	Arguments                                          []CommandArgument
	ModelCallable, UserTurn                            bool
	Operation                                          wireActionOperation
}

func decodeSessionCommand(raw json.RawMessage) (SessionCommand, error) {
	var discriminator struct {
		Delivery string `json:"delivery"`
	}
	if err := decodeRequired(raw, &discriminator, "delivery"); err != nil {
		return SessionCommand{}, err
	}
	var command wireHTTPCommand
	var commandID string
	if discriminator.Delivery == "input" {
		var input wireInputCommand
		if err := decodeRequired(raw, &input, "id", "slash_name", "description", "arguments", "caller_permissions", "delivery", "command_id"); err != nil {
			return SessionCommand{}, err
		}
		command = wireHTTPCommand{ID: input.ID, SlashName: input.SlashName, Description: input.Description, Arguments: input.Arguments, CallerPermissions: input.CallerPermissions, Delivery: input.Delivery}
		commandID = input.CommandID
	} else if err := decodeRequired(raw, &command, "id", "slash_name", "description", "arguments", "caller_permissions", "delivery", "operation"); err != nil {
		return SessionCommand{}, err
	}
	if command.ID == "" || !strings.HasPrefix(command.SlashName, "/") || command.Arguments == nil {
		return SessionCommand{}, fieldError("command")
	}
	result := SessionCommand{ID: command.ID, Name: command.SlashName, Description: command.Description, Delivery: command.Delivery, ModelCallable: slices.Contains(command.CallerPermissions, "model"), Operation: command.Operation}
	if command.Delivery == "input" {
		if commandID == "" {
			return SessionCommand{}, fieldError("command ID")
		}
		result.CommandID = commandID
		result.Method = "PUT"
		result.UserTurn = true
	} else if command.Delivery != "read" && command.Delivery != "mutation" {
		return SessionCommand{}, fieldError("command delivery")
	}
	if !result.UserTurn {
		result.Method = command.Operation.Method
	}
	page := command.Delivery == "read" && len(command.Arguments) == 0 && (strings.HasPrefix(command.Operation.PathTemplate, "/extensions/") || command.SlashName == "/ttl" || command.SlashName == "/quota" || command.SlashName == "/requests")
	result.Page = &page
	for _, field := range command.Arguments {
		argument := CommandArgument{Name: field.Name, Description: field.Description, Required: field.Required, Type: field.Type, field: field}
		for _, choice := range field.Choices {
			argument.Choices = append(argument.Choices, choice.Label)
		}
		result.Arguments = append(result.Arguments, argument)
	}
	return result, nil
}
