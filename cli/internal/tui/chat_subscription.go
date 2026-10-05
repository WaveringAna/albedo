package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"time"

	tea "charm.land/bubbletea/v2"
)

func (m ChatModel) animating() bool {
	return m.isSending || m.pendingSendCount() > 0 || m.Stopping || m.latestProgress() != nil || m.Status.Running && !m.Status.Idle || m.reaching() != "" || m.backgroundJobCount() > 0
}

func (m *ChatModel) startAnimation() tea.Cmd {
	if m.streamStopped || m.animationActive || !m.animating() {
		return nil
	}
	m.animationActive = true
	return m.progressTickCmd()
}

func (m ChatModel) progressTickCmd() tea.Cmd {
	id, generation := m.SessionID, m.Generation
	return tea.Tick(faceInterval, func(time.Time) tea.Msg { return ChatProgressTickMsg{SessionID: id, Generation: generation} })
}

func (m ChatModel) waitForNextEvent() tea.Cmd {
	sessID, gen, ch, ctx := m.SessionID, m.Generation, m.eventChan, m.streamCtx
	return func() tea.Msg {
		select {
		case evt, ok := <-ch:
			if !ok {
				return ChatStreamClosedMsg{SessionID: sessID, Generation: gen}
			}
			if evt.Event != nil {
				return ChatStreamEventMsg{SessionID: sessID, Generation: gen, Event: *evt.Event}
			}
			return ChatStreamResultMsg{SessionID: sessID, Generation: gen, Err: evt.Err, Recovering: evt.Recovering}
		case <-ctx.Done():
			return ChatStreamClosedMsg{SessionID: sessID, Generation: gen}
		}
	}
}

func (m ChatModel) startStreamSubscription() tea.Cmd {
	client, ctx, ch := m.client, m.streamCtx, m.eventChan
	go func() {
		defer close(ch)
		defer client.ResetStream()
		deliver := func(value streamDelivery) bool {
			select {
			case ch <- value:
				return true
			case <-ctx.Done():
				return false
			}
		}
		recovered := false
		delay := 500 * time.Millisecond
		for ctx.Err() == nil {
			err := client.StreamWithProgress(ctx, olderPageRows, func(evt daemon.StreamEvent) error {
				if !deliver(streamDelivery{Event: &evt}) {
					return ctx.Err()
				}
				return nil
			}, func() { delay = 500 * time.Millisecond })
			if ctx.Err() != nil {
				return
			}
			if failure, ok := errors.AsType[*daemon.StreamError](err); ok {
				switch failure.Kind {
				case daemon.StreamProtocol:
					if recovered {
						deliver(streamDelivery{Err: err})
						return
					}
					recovered = true
					if !deliver(streamDelivery{Err: err, Recovering: true}) {
						return
					}
					client.ResetStream()
				case daemon.StreamTerminal:
					deliver(streamDelivery{Err: err})
					return
				}
			}
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
			delay = min(delay*2, 5*time.Second)
		}
	}()
	return m.waitForNextEvent()
}

func (m ChatModel) clearCopyStatusCmd() tea.Cmd {
	id, generation, revision := m.SessionID, m.Generation, m.copyStatusRevision
	return tea.Tick(3*time.Second, func(time.Time) tea.Msg {
		return ChatClearCopyStatusMsg{SessionID: id, Generation: generation, Revision: revision}
	})
}

func (m ChatModel) statusCmd() tea.Cmd {
	client, ctx, id, generation, revision := m.client, m.streamCtx, m.SessionID, m.Generation, m.statusRevision
	return func() tea.Msg {
		captured, err := client.GetSession(ctx)
		return ChatStatusMsg{SessionID: id, Generation: generation, Revision: revision, Status: &captured.Status, Glances: captured.Glances, Err: err}
	}
}

// windowCmd reads the context window when usage names a model whose window
// has not been read yet.
func (m ChatModel) windowCmd() tea.Cmd {
	if m.Usage == nil || m.windowModel != nil && *m.windowModel == m.Usage.Model {
		return nil
	}
	client, ctx, id, generation, model := m.client, m.streamCtx, m.SessionID, m.Generation, m.Usage.Model
	return func() tea.Msg {
		tokens, err := client.ContextWindow(ctx)
		return ChatWindowMsg{SessionID: id, Generation: generation, Model: model, Tokens: tokens, Err: err}
	}
}

// cacheFadeCmd wakes the footer when the cached count reaches its next step.
func (m ChatModel) cacheFadeCmd() tea.Cmd {
	if m.Usage == nil {
		return nil
	}
	now := time.Now().UnixMilli()
	for _, step := range m.Usage.CacheFade {
		if step.At > now {
			id, generation, usage := m.SessionID, m.Generation, m.Usage
			return tea.Tick(time.Duration(step.At-now)*time.Millisecond, func(time.Time) tea.Msg {
				return ChatCacheFadeMsg{SessionID: id, Generation: generation, Usage: usage}
			})
		}
	}
	return nil
}

// hostHomeCmd asks a remote workspace's host where its home is, once per
// workspace, after the kernel attached: the probe has answered by then.
func (m *ChatModel) hostHomeCmd() tea.Cmd {
	host, _ := daemon.SplitLocation(m.Workspace)
	if host == "" || m.hostAsked == m.Workspace || m.Status.KernelLink != "attached" {
		return nil
	}
	m.hostAsked = m.Workspace
	client, ctx, id, generation, workspace := m.client, m.streamCtx, m.SessionID, m.Generation, m.Workspace
	return func() tea.Msg {
		status, err := client.Host(ctx, host)
		return ChatHostMsg{SessionID: id, Generation: generation, Workspace: workspace, Status: status, Err: err}
	}
}

// statusPollCmd schedules the next status read: often while anything is live,
// rarely while the session rests. Only the newest scheduled poll fires, so a
// status read started elsewhere never adds a second polling loop.
func (m *ChatModel) statusPollCmd() tea.Cmd {
	m.statusPoll++
	m.statusPollResting = !m.animating() && m.Status.KernelLink != "booting" && m.Status.KernelLink != "reattaching"
	every := 750 * time.Millisecond
	if m.statusPollResting {
		every = 5 * time.Second
	}
	id, generation, poll := m.SessionID, m.Generation, m.statusPoll
	return tea.Tick(every, func(time.Time) tea.Msg { return ChatStatusPollMsg{SessionID: id, Generation: generation, Poll: poll} })
}

func (m ChatModel) Init() tea.Cmd {
	commands := []tea.Cmd{m.startStreamSubscription(), m.statusCmd()}
	for _, pending := range m.pendingUsers {
		if pending.Handle != nil && !pending.Expired {
			commands = append(commands, m.queryOperationCmd(pending.Handle))
		}
	}
	for _, pending := range m.pendingContinuations {
		if !pending.Expired {
			commands = append(commands, m.queryOperationCmd(pending.Handle))
		}
	}
	return tea.Batch(commands...)
}
