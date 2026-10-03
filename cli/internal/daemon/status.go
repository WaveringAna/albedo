package daemon

import "context"

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
	Running, Idle, KernelStale    bool
	KernelLink, KernelStep        string
	RunID                         *string
	InputOrder                    int64
	KernelJobs                    *int64
	KernelBuild, KernelInstanceID *string
}

func validateSessionStatus(status wireSessionStatus) error {
	switch status.Phase {
	case "idle", "preparing", "generating", "running", "interrupting", "compacting":
		return nil
	}
	return fieldError("status.phase")
}
func statusValue(status wireSessionStatus, kernel wireKernel) AgentStatus {
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
	return AgentStatus{Phase: &phase, Running: status.Phase != "idle", Idle: status.Phase == "idle", KernelStale: kernel.Stale, KernelLink: kernel.State, KernelStep: value(kernel.Stage), RunID: status.RunID, KernelJobs: kernel.LiveJobCount, KernelBuild: kernel.Build, KernelInstanceID: kernel.InstanceID}
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
