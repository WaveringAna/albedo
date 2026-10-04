package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"strings"
	"unicode"
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

// ParseCommandArguments reads the text typed after a command name. Words fill
// the declared arguments in order and the last argument takes the rest of the
// line; a JSON object names them instead.
func ParseCommandArguments(command SessionCommand, text string) (map[string]json.RawMessage, error) {
	text = strings.TrimSpace(text)
	if len(command.Arguments) > 1 && strings.HasPrefix(text, "{") {
		return namedCommandArguments(command, text)
	}
	result := map[string]json.RawMessage{}
	for index, argument := range command.Arguments {
		word := text
		if index < len(command.Arguments)-1 {
			word, text = cutWord(text)
		} else {
			text = ""
		}
		if word == "" && !argument.Required {
			continue
		}
		value, err := actionFieldValue(argument.field, word)
		if err != nil {
			return nil, err
		}
		result[argument.Name] = value
	}
	if text != "" {
		return nil, errors.New(command.Name + " takes no arguments")
	}
	return result, nil
}

func cutWord(text string) (string, string) {
	end := strings.IndexFunc(text, unicode.IsSpace)
	if end < 0 {
		return text, ""
	}
	return text[:end], strings.TrimSpace(text[end:])
}

func namedCommandArguments(command SessionCommand, text string) (map[string]json.RawMessage, error) {
	result := map[string]json.RawMessage{}
	if err := json.Unmarshal([]byte(text), &result); err != nil {
		return nil, errors.New("this command accepts words in argument order or a JSON object with its declared argument names")
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
