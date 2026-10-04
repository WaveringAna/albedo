package daemon

import (
	"context"
	"encoding/json"
	"io"
	"net/http"

	"albedo/cli/internal/daemon/protocol"
)

type SendResult struct {
	OperationID     string `json:"operationId"`
	OK              bool   `json:"ok"`
	Queued          bool   `json:"queued"`
	AcceptanceOrder int64
}

// SubmissionRequest keeps message text and continuation content distinct:
// an empty message has a Content pointer, while a continuation has none.
type SubmissionRequest struct {
	CatalogRevision  string
	CommandArguments json.RawMessage
	Content          *string
	Images           []ImageAttachment
	Pastes           []string
	Type             string
	ClientID         string
	SubmissionID     string
	Name             string
	Arguments        string
}

func Submit(ctx context.Context, conn *Connection, id string, payload SubmissionRequest) (SendResult, error) {
	handle, err := NewSubmission(id, payload)
	if err != nil {
		return SendResult{}, err
	}
	return SubmitOperation(ctx, conn, handle)
}

func SubmitOperation(ctx context.Context, conn *Connection, handle *OperationHandle) (SendResult, error) {
	return executeReceipt(ctx, conn, handle, []int{http.StatusAccepted}, func(body []byte, status int) (SendResult, error) {
		result, err := decodeSubmission(body, status)
		if err == nil && result.OperationID != handle.ID() {
			return result, fieldError("operationId")
		}
		return result, err
	}, func(ctx context.Context) (SendResult, bool, error) {
		receipt, err := ResolveOperation(ctx, conn, handle)
		if err != nil {
			return SendResult{}, false, err
		}
		result, err := submissionResult(receipt)
		return result, true, err
	})
}

func InterruptSession(ctx context.Context, conn *Connection, id string) (bool, error) {
	session, err := GetSession(ctx, conn, id)
	if err != nil {
		return false, err
	}
	return interruptCaptured(ctx, conn, id, session.wire.Status.RunID, session.wire.InputOrder)
}
func interruptCaptured(ctx context.Context, conn *Connection, id string, runID *string, inputOrder int64) (bool, error) {
	var result protocol.Interruption
	err := executeMutation(ctx, conn, operation{Name: "interrupt session", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewInterruptSessionRequestWithBody(base, id, "application/json", body)
	}, Body: protocol.InterruptRequest{RunID: runID, ThroughInputOrder: inputOrder}, Policy: noRecovery}, []int{200}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &result); err != nil {
			return err
		}
		switch result.State {
		case "requested", "already_ended":
			return nil
		}
		return fieldError("interruption state")
	})
	return result.State == "requested", err
}

func (c *ChatClient) PrepareTurn(content string, images []ImageAttachment, pastes []string, continuation bool) (*OperationHandle, error) {
	payload := SubmissionRequest{ClientID: c.clientID, Content: &content, Type: "user", Images: images, Pastes: pastes}
	if continuation {
		payload.Type, payload.Content = "continue", nil
	}
	return NewSubmission(c.agentID, payload)
}

func (c *ChatClient) SubmitOperation(ctx context.Context, handle *OperationHandle) (*SendResult, error) {
	result, err := SubmitOperation(ctx, c.conn, handle)
	if err != nil {
		return nil, err
	}
	return &result, nil
}

func (c *ChatClient) ResolveOperation(ctx context.Context, handle *OperationHandle) (InputReceipt, error) {
	return ResolveOperation(ctx, c.conn, handle)
}

func (c *ChatClient) Send(ctx context.Context, content string, images []ImageAttachment) (*SendResult, error) {
	handle, err := c.PrepareTurn(content, images, nil, false)
	if err != nil {
		return nil, err
	}
	return c.SubmitOperation(ctx, handle)
}

func (c *ChatClient) CancelSubmission(ctx context.Context, submissionID string) (string, error) {
	var result protocol.InputCancellation
	err := executeMutation(ctx, c.conn, operation{Name: "cancel input", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewCancelInputRequestWithBody(base, c.agentID, submissionID, "application/json", body)
	}, Body: struct{}{}, Policy: noRecovery}, []int{200}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &result); err != nil {
			return err
		}
		if result.Input.ID != submissionID {
			return fieldError("input identity")
		}
		return validInput(result.Input)
	})
	outcome := result.Result
	if outcome == "cancelled" {
		outcome = "cancelled_queued"
	}
	switch result.Result {
	case "cancelled", "interrupt_requested", "shared_running", "not_pending":
	default:
		if err == nil {
			err = fieldError("cancellation result")
		}
	}
	return outcome, err
}

func decodeSubmission(data []byte, _ int) (SendResult, error) {
	var input protocol.Input
	if err := decodeRequired(data, &input); err != nil {
		return SendResult{}, err
	}
	if err := validInput(input); err != nil {
		return SendResult{}, err
	}
	return submissionResult(InputReceipt(input))
}

func submissionResult(input InputReceipt) (SendResult, error) {
	if err := input.Rejection(); err != nil {
		return SendResult{}, err
	}
	return SendResult{OK: true, Queued: input.Pending(), OperationID: input.ID, AcceptanceOrder: input.InputOrder()}, nil
}

func (c *ChatClient) PrepareCommand(commandID string, arguments map[string]json.RawMessage) (*OperationHandle, error) {
	payload, err := json.Marshal(arguments)
	if err != nil {
		return nil, err
	}
	return NewSubmission(c.agentID, SubmissionRequest{ClientID: c.clientID, Type: "command", Name: commandID, CommandArguments: payload})
}
func (c *ChatClient) InterruptObserved(ctx context.Context, status AgentStatus) (bool, error) {
	return interruptCaptured(ctx, c.conn, c.agentID, status.RunID, status.InputOrder)
}
