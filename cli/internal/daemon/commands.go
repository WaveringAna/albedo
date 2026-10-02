package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

type CommandResult struct {
	Model     *ModelSelection
	Effort    *EffortResult
	Page      *PageDocument
	Webhooks  *WebhookResult
	Message   string
	Result    json.RawMessage
	Submitted bool
}

func decodeCommand(data []byte, status int) (CommandResult, error) {
	var wire struct {
		Result    json.RawMessage `json:"result"`
		Submitted json.RawMessage `json:"submitted"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return CommandResult{}, err
	}
	if status == 200 {
		if wire.Result == nil {
			return CommandResult{}, fieldError("result")
		}
		if wire.Submitted != nil {
			return CommandResult{}, fieldError("submitted")
		}
		return CommandResult{Result: wire.Result}, nil
	}
	if wire.Result != nil {
		return CommandResult{}, fieldError("result")
	}
	var submitted bool
	if wire.Submitted == nil || json.Unmarshal(wire.Submitted, &submitted) != nil || !submitted {
		return CommandResult{}, fieldError("submitted")
	}
	return CommandResult{Submitted: true}, nil
}

func ExecuteCommand(ctx context.Context, conn *Connection, id string, body CommandRequest) (CommandResult, error) {
	return executeCommand(ctx, conn, id, body, false)
}

func executeCommand(ctx context.Context, conn *Connection, id string, body CommandRequest, page bool) (CommandResult, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var result CommandResult
	name := body.Name

	err := executeMutation(ctx, conn, operation{Name: "execute command " + name, Method: http.MethodPost, Path: sessionPath(id, "/commands"), Body: body, Policy: authRecovery}, []int{200, 202}, func(data []byte, status int) error {
		var err error
		result, err = decodeCommand(data, status)
		if err != nil {
			return err
		}
		if page || name == "/model" || name == "/effort" || name == "/webhooks" {
			if result.Submitted {
				return fieldError("result")
			}
			payload := result.Result
			switch {
			case page:
				result.Page, err = decodePageDocument(payload)
				return err
			case name == "/model":
				model, err := decodeModelSelection(payload)
				if err != nil {
					return err
				}
				result.Model = &model
				return nil
			case name == "/effort":
				result.Effort, err = decodeEffort(payload, body)
				return err
			case name == "/webhooks":
				result.Webhooks, err = decodeWebhookResult(payload, body)
				if err != nil {
					return err
				}
				result.Message = result.Webhooks.Message
				return nil
			}
		}
		if len(result.Result) > 0 && result.Result[0] == '{' {
			if fields, err := object(result.Result); err == nil {
				var message string
				if raw := fields["message"]; raw != nil && json.Unmarshal(raw, &message) == nil {
					result.Message = message
				}
			}
		}
		return nil
	})
	return result, err
}

func ListSessionCommands(ctx context.Context, conn *Connection, session string) ([]SessionCommand, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var result []SessionCommand
	if err := checkCapability(ctx, conn, "session_commands", "for the command menu"); err != nil {
		return result, err
	}
	err := executeRead(ctx, conn, operation{Name: "list session commands", Method: http.MethodGet, Path: sessionPath(session, "/commands"), Policy: readRecovery}, func(data []byte) error {
		var err error
		result, err = parseCommandCatalog(data)
		return err
	})
	return result, err
}

type CommandRequest struct {
	Name      string       `json:"name"`
	Arguments string       `json:"arguments,omitempty"`
	Args      *CommandArgs `json:"args,omitempty"`
}

type CommandArgs struct {
	Level    string `json:"level,omitempty"`
	Model    string `json:"model,omitempty"`
	Provider string `json:"provider,omitempty"`
	Effort   string `json:"effort,omitempty"`
	State    string `json:"state,omitempty"`
	Action   string `json:"action,omitempty"`
	Details  string `json:"details,omitempty"`
}
