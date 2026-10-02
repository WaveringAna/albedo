package daemon

import (
	"context"
	"net/http"
)

type AgentPhase string

const (
	PhaseResting     AgentPhase = "resting"
	PhaseInterrupted AgentPhase = "interrupted"
	PhasePreparing   AgentPhase = "preparing"
	// PhaseReasoning describes streamed text before the next UI status poll.
	PhaseReasoning  AgentPhase = "reasoning"
	PhaseTool       AgentPhase = "tool"
	PhaseStarting   AgentPhase = "starting"
	PhaseBackground AgentPhase = "background"
	PhaseModel      AgentPhase = "model"
	PhaseIdle       AgentPhase = "idle"
	PhaseCompacting AgentPhase = "compacting"
)

var validAgentPhases = map[AgentPhase]bool{
	PhaseResting:     true,
	PhaseInterrupted: true,
	PhasePreparing:   true,
	PhaseTool:        true,
	PhaseStarting:    true,
	PhaseBackground:  true,
	PhaseModel:       true,
	PhaseIdle:        true,
	PhaseCompacting:  true,
}

type AgentStatus struct {
	Phase   *AgentPhase `json:"phase,omitempty"`
	Running bool        `json:"running"`
	Idle    bool        `json:"idle"`
}

// ContextWindow reads the model's context window from the session's last
// prepared request. It is nil when neither a catalog nor the configuration
// knows it, or when no request has been prepared yet.
func (c *ChatClient) GetStatus(ctx context.Context) (*AgentStatus, error) {
	var result AgentStatus
	err := executeRead(ctx, c.conn, operation{Name: "read status", Method: http.MethodGet, Path: sessionPath(c.agentID, "/status"), Policy: readRecovery}, func(data []byte) error {
		fields, err := object(data)
		if err != nil {
			return err
		}
		if err = required(fields, "running", &result.Running); err != nil {
			return err
		}
		if err = required(fields, "idle", &result.Idle); err != nil {
			return err
		}
		var phase AgentPhase
		if err = required(fields, "phase", &phase); err != nil {
			return err
		}
		if !validAgentPhases[phase] {
			return fieldError("phase")
		}
		if result.Running == result.Idle {
			return fieldError("idle")
		}
		result.Phase = &phase
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}
