package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

type SendResult struct {
	OperationID string `json:"operationId"`
	OK          bool   `json:"ok"`
	Queued      bool   `json:"queued"`
}

// Content is a pointer so an empty user message and absent continuation content
// retain their distinct wire representations.
type SubmissionRequest struct {
	Content      *string          `json:"content,omitempty"`
	Image        *ImageAttachment `json:"image,omitempty"`
	Type         string           `json:"type,omitempty"`
	ClientID     string           `json:"clientId,omitempty"`
	SubmissionID string           `json:"submissionId,omitempty"`
	Name         string           `json:"name,omitempty"`
	Arguments    string           `json:"arguments,omitempty"`
}

func Submit(ctx context.Context, conn *Connection, id string, payload SubmissionRequest) (SendResult, error) {
	handle, err := NewSubmission(id, payload)
	if err != nil {
		return SendResult{}, err
	}
	return SubmitOperation(ctx, conn, handle)
}

func SubmitOperation(ctx context.Context, conn *Connection, handle *OperationHandle) (SendResult, error) {
	var result SendResult
	err := executeReceipt(ctx, conn, handle, []int{http.StatusAccepted}, func(body []byte, status int) error {
		var err error
		result, err = decodeSubmission(body, status)
		if err == nil && result.OperationID != handle.ID() {
			return fieldError("operationId")
		}
		return err
	})
	return result, err
}

func InterruptSession(ctx context.Context, conn *Connection, id string) (bool, error) {
	var interrupted bool
	err := executeMutation(ctx, conn, operation{Name: "interrupt session", Method: http.MethodPost, Path: sessionPath(id, "/interrupt"), Body: map[string]any{}, Policy: authRecovery}, []int{http.StatusOK}, func(body []byte, status int) error {
		var err error
		interrupted, err = decodeInterruption(body, status)
		return err
	})
	return interrupted, err
}

func (c *ChatClient) PrepareTurn(content string, image *ImageAttachment, continuation bool) (*OperationHandle, error) {
	payload := SubmissionRequest{ClientID: c.clientID, Content: &content, Type: "user", Image: image}
	if continuation {
		payload.Type, payload.Content = "continue", nil
	}
	return NewSubmission(c.agentID, payload)
}

func (c *ChatClient) PrepareSkill(name, args string) (*OperationHandle, error) {
	return NewSubmission(c.agentID, SubmissionRequest{ClientID: c.clientID, Type: "skill", Name: name, Arguments: args})
}

func (c *ChatClient) SubmitOperation(ctx context.Context, handle *OperationHandle) (*SendResult, error) {
	result, err := SubmitOperation(ctx, c.conn, handle)
	if err != nil {
		return nil, err
	}
	return &result, nil
}

func (c *ChatClient) ResolveOperation(ctx context.Context, handle *OperationHandle) (OperationReceipt, error) {
	return ResolveOperation(ctx, c.conn, handle)
}

func (c *ChatClient) Send(ctx context.Context, content string, image *ImageAttachment) (*SendResult, error) {
	handle, err := c.PrepareTurn(content, image, false)
	if err != nil {
		return nil, err
	}
	return c.SubmitOperation(ctx, handle)
}

func (c *ChatClient) Continue(ctx context.Context) (*SendResult, error) {
	handle, err := c.PrepareTurn("", nil, true)
	if err != nil {
		return nil, err
	}
	return c.SubmitOperation(ctx, handle)
}

func (c *ChatClient) SendSubmission(ctx context.Context, content, submissionID string) (*SendResult, error) {
	handle, err := NewSubmission(c.agentID, SubmissionRequest{Content: &content, ClientID: c.clientID, SubmissionID: submissionID})
	if err != nil {
		return nil, err
	}
	return c.SubmitOperation(ctx, handle)
}

func (c *ChatClient) CancelSubmission(ctx context.Context, submissionID string) (string, error) {
	var outcome string
	err := executeMutation(ctx, c.conn, operation{Name: "cancel submission", Method: http.MethodPost, Path: sessionPath(c.agentID, "/cancel-submission"), Body: struct {
		SubmissionID string `json:"submissionId"`
	}{submissionID}, Policy: noRecovery}, []int{http.StatusOK}, func(data []byte, _ int) error {
		fields, err := object(data)
		if err != nil {
			return err
		}
		if err = required(fields, "outcome", &outcome); err != nil {
			return err
		}
		switch outcome {
		case "cancelled_queued", "interrupt_requested", "shared_running", "not_pending":
			return nil
		default:
			return fieldError("outcome")
		}
	})
	if err != nil {
		return "", err
	}
	return outcome, nil
}

func (c *ChatClient) Interrupt(ctx context.Context) (bool, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	return InterruptSession(reqCtx, c.conn, c.agentID)
}

func decodeSubmission(data []byte, _ int) (SendResult, error) {
	var wire struct {
		OK          *bool  `json:"ok"`
		Queued      *bool  `json:"queued"`
		OperationID string `json:"operationId"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return SendResult{}, err
	}
	if wire.OK == nil || !*wire.OK {
		return SendResult{}, fieldError("ok")
	}
	if wire.Queued == nil {
		return SendResult{}, fieldError("queued")
	}
	if wire.OperationID == "" {
		return SendResult{}, fieldError("operationId")
	}
	return SendResult{OK: *wire.OK, Queued: *wire.Queued, OperationID: wire.OperationID}, nil
}

func decodeInterruption(data []byte, _ int) (bool, error) {
	var wire struct {
		Interrupted *bool `json:"interrupted"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return false, err
	}
	if wire.Interrupted == nil {
		return false, fieldError("interrupted")
	}
	return *wire.Interrupted, nil
}
