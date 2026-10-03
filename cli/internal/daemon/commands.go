package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
)

type CommandResult struct {
	Effort    *EffortResult
	Page      *PageDocument
	Message   string
	Result    json.RawMessage
	Submitted bool
}

func ListSessionCommands(ctx context.Context, conn *Connection, session string) ([]SessionCommand, error) {
	catalog, err := readCapabilityCatalog(ctx, conn, session, false)
	if err != nil {
		return nil, err
	}
	return catalog.Commands, nil
}

// InvokeDeclaredCommand follows the catalog's HTTP operation or admits its typed input.
func InvokeDeclaredCommand(ctx context.Context, conn *Connection, snapshot Session, command SessionCommand, arguments map[string]json.RawMessage) (CommandResult, error) {
	if command.Delivery == "input" {
		encoded, err := json.Marshal(arguments)
		if err != nil {
			return CommandResult{}, err
		}
		request := SubmissionRequest{Type: "command", Name: command.CommandID, CommandArguments: encoded}
		handle, err := NewSubmission(snapshot.ID, request)
		if err != nil {
			return CommandResult{}, err
		}
		_, err = SubmitOperation(ctx, conn, handle)
		return CommandResult{Submitted: err == nil}, err
	}
	if command.Operation.PathTemplate == "" {
		return CommandResult{}, errors.New("the command has no declared HTTP operation")
	}
	data, err := executeBoundOperation(ctx, conn, command.Operation, nil, arguments, &snapshot)
	if err != nil {
		return CommandResult{}, err
	}
	if command.Delivery == "read" {
		page, err := readResultPage(data, command.Name, command.Description)
		if err != nil {
			return CommandResult{}, err
		}
		page.Session = &snapshot
		page.read = &pageRead{Name: command.Name, Description: command.Description, Operation: command.Operation, Form: maps.Clone(arguments)}
		return CommandResult{Result: data, Page: page}, nil
	}
	return extensionResult(data), nil
}

func ParseCommandArguments(command SessionCommand, text string) (map[string]json.RawMessage, error) {
	result := map[string]json.RawMessage{}
	if len(command.Arguments) == 1 {
		argument := command.Arguments[0]
		if text != "" || argument.Required {
			value, err := actionFieldValue(argument.field, text)
			if err != nil {
				return nil, err
			}
			result[argument.Name] = value
		}
		return result, nil
	}
	if text != "" {
		if err := json.Unmarshal([]byte(text), &result); err != nil {
			return nil, errors.New("this command accepts a JSON object with its declared argument names")
		}
	}
	for _, field := range command.Arguments {
		raw, ok := result[field.Name]
		if ok {
			if err := validateFormValue(field.field, raw); err != nil {
				return nil, err
			}
		}
		if !ok && field.Required {
			return nil, errors.New("missing command argument: " + field.Name)
		}
	}
	for name := range result {
		known := false
		for _, field := range command.Arguments {
			known = known || field.Name == name
		}
		if !known {
			return nil, errors.New("unknown command argument: " + name)
		}
	}
	return result, nil
}
