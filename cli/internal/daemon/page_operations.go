package daemon

import (
	"context"
	"errors"
	"strings"
)

type PageActionRequest struct {
	Command string
	Action  PageAction
	Row     *PageRow
	Value   string
}

func LoadPage(ctx context.Context, conn *Connection, session, command string) (*PageDocument, error) {
	result, err := executeCommand(ctx, conn, session, CommandRequest{Name: command, Args: &CommandArgs{}}, true)
	return result.Page, err
}

func ExecutePageAction(ctx context.Context, conn *Connection, session string, request PageActionRequest) (CommandResult, error) {
	if request.Action.Row && (request.Row == nil || request.Row.ID == "") {
		return CommandResult{}, errors.New("page action requires a selected row")
	}
	if request.Command == "" || request.Action.Run == "" {
		return CommandResult{}, errors.New("page action requires a command and action")
	}
	value := request.Value
	if request.Action.Input == "value" {
		value = request.Action.Value
	}
	var details []string
	if request.Action.Row && request.Row != nil {
		details = append(details, request.Row.ID)
	}
	if value != "" {
		details = append(details, value)
	}
	return executeCommand(ctx, conn, session, CommandRequest{Name: request.Command, Args: &CommandArgs{Action: request.Action.Run, Details: strings.Join(details, " ")}}, false)
}
