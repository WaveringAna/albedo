package daemon

import (
	"context"
	"io"
	"net/http"

	"albedo/cli/internal/daemon/protocol"
)

type AgentPhase string

const (
	PhaseResting     AgentPhase = "resting"
	PhaseInterrupted AgentPhase = "interrupted"
	PhasePreparing   AgentPhase = "preparing"
	PhaseReasoning   AgentPhase = "reasoning"
	PhaseTool        AgentPhase = "tool"
	PhaseModel       AgentPhase = "model"
	PhaseIdle        AgentPhase = "idle"
	PhaseCompacting  AgentPhase = "compacting"
)

type AgentStatus struct {
	Phase                         *AgentPhase
	RunID                         *string
	KernelJobs                    *int64
	KernelBuild, KernelInstanceID *string
	KernelLink, KernelStep        string
	RunningJobs                   []protocol.KernelJob
	InputOrder                    int64
	Running, Idle, KernelStale    bool
}

func validateSessionStatus(status protocol.SessionStatus) error {
	switch status.Phase {
	case "idle", "preparing", "generating", "running", "interrupting", "compacting":
		return nil
	}
	return fieldError("status.phase")
}
func statusValue(status protocol.SessionStatus, kernel protocol.Kernel) AgentStatus {
	phase := PhaseIdle
	switch status.Phase {
	case "preparing":
		phase = PhasePreparing
	case "generating":
		phase = PhaseModel
	case "running":
		phase = PhaseTool
	case "interrupting":
		phase = PhaseInterrupted
	case "compacting":
		phase = PhaseCompacting
	}
	result := AgentStatus{Phase: &phase, Running: status.Phase != "idle", Idle: status.Phase == "idle", RunID: status.RunID}
	result.ApplyKernel(kernel)
	return result
}

// ApplyKernel updates the facts a kernel event carries, leaving the turn's
// phase and identity as the status events set them.
func (status *AgentStatus) ApplyKernel(kernel protocol.Kernel) {
	status.KernelStale = kernel.Stale
	status.KernelLink = kernel.State
	status.KernelStep = value(kernel.Stage)
	status.KernelJobs = kernel.LiveJobCount
	status.RunningJobs = kernel.RunningJobs
	status.KernelBuild = kernel.Build
	status.KernelInstanceID = kernel.InstanceID
}
func (c *ChatClient) GetStatus(ctx context.Context) (*AgentStatus, error) {
	session, err := c.GetSession(ctx)
	if err != nil {
		return nil, err
	}
	status := session.Status
	status.InputOrder = session.wire.InputOrder
	return &status, nil
}

func (c *ChatClient) GetSession(ctx context.Context) (Session, error) {
	return GetSession(ctx, c.conn, c.agentID)
}

// GetSessionStatus reads the live facts alone: no configuration, no history,
// no composition. It is the safety read a watching client makes when pushed
// events have gone quiet, not a poll.
func (c *ChatClient) GetSessionStatus(ctx context.Context) (AgentStatus, []PageGlance, error) {
	var read protocol.SessionStatusRead
	err := executeRead(ctx, c.conn, operation{Name: "read session status", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetSessionRequest(base, c.agentID, &protocol.GetSessionParams{View: new("status")})
	}, Policy: readRecovery}, func(data []byte) error {
		if err := decodeRequired(data, &read); err != nil {
			return err
		}
		if read.ID != c.agentID {
			return fieldError("session ID")
		}
		return validateSessionStatus(read.Status)
	})
	if err != nil {
		return AgentStatus{}, nil, err
	}
	return statusValue(read.Status, read.Kernel), glancesValue(read.Glances), nil
}
