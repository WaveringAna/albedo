package tui

import (
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
)

func TestEscapeStoppingCompactionReconcilesWhenIdle(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 30)

	phaseCompacting := daemon.PhaseCompacting
	m.Status.Running, m.Status.Idle, m.Status.Phase = true, false, &phaseCompacting

	// Press esc to stop compaction
	var cmd tea.Cmd
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if cmd == nil {
		t.Fatal("expected interrupt command on esc")
	}
	if !m.Stopping {
		t.Fatal("expected Stopping to be true after pressing esc")
	}
	if !strings.Contains(m.statusLine(), "stopping…") {
		t.Fatalf("expected statusLine to show stopping…, got %q", m.statusLine())
	}

	// Daemon finishes interrupting compaction and emits status idle
	phaseIdle := daemon.PhaseIdle
	m.handleStreamEvent(daemon.StreamEvent{
		Type: "status",
		Status: &daemon.AgentStatus{
			Running: false,
			Idle:    true,
			Phase:   &phaseIdle,
		},
	})

	if m.Stopping {
		t.Fatal("expected Stopping to be false after status became idle")
	}
	if !m.Stopped {
		t.Fatal("expected Stopped to be true after stopping was reconciled")
	}
	if strings.Contains(m.statusLine(), "stopping…") {
		t.Fatalf("statusLine still shows stopping… after idle: %q", m.statusLine())
	}
	if m.animating() {
		t.Fatal("expected animating to be false after stopping completed and session is idle")
	}
}

func TestEscapeStoppingPendingUsersReconcilesWhenSettled(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 30)
	m.Status.Running, m.Status.Idle = false, true
	m.pendingUsers = []PendingUserTurn{
		{OperationID: "op-1", Text: "queued message", At: time.Now().UnixMilli()},
	}

	// Press esc to cancel queued input
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if !m.Stopping {
		t.Fatal("expected Stopping to be true after pressing esc with pending users")
	}

	// Status event arrives while input is still pending: Stopping remains true
	phaseIdle := daemon.PhaseIdle
	m.handleStreamEvent(daemon.StreamEvent{
		Type: "status",
		Status: &daemon.AgentStatus{
			Running: false,
			Idle:    true,
			Phase:   &phaseIdle,
		},
	})
	if !m.Stopping {
		t.Fatal("expected Stopping to stay true while pendingUsers still contains items")
	}

	// Receipt settles the input turn
	cancelled := "cancelled"
	m.handleStreamEvent(daemon.StreamEvent{
		Type: "input",
		Receipt: &daemon.InputReceipt{
			ID:       "op-1",
			Delivery: &cancelled,
		},
	})

	if m.Stopping {
		t.Fatal("expected Stopping to be false once pending input is settled")
	}
	if !m.Stopped {
		t.Fatal("expected Stopped to be true after pending input is settled")
	}
	if m.animating() {
		t.Fatal("expected animating to be false")
	}
}

func TestChatStatusPollReconcilesStopping(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 30)
	m.Stopping = true
	m.Status.Running, m.Status.Idle = true, false

	phaseIdle := daemon.PhaseIdle
	status := daemon.AgentStatus{
		Running: false,
		Idle:    true,
		Phase:   &phaseIdle,
	}
	m, _ = m.Update(ChatStatusMsg{
		SessionID:  m.SessionID,
		Generation: m.Generation,
		Revision:   m.statusRevision,
		Status:     &status,
	})

	if m.Stopping {
		t.Fatal("expected Stopping to be false after ChatStatusMsg reported idle")
	}
	if !m.Stopped {
		t.Fatal("expected Stopped to be true")
	}
}
