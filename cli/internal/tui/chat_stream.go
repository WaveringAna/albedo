package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"math/rand/v2"
	"slices"
)

// clearAction drops the live action row; the next action starts a new one.
func (m *ChatModel) clearAction() {
	m.settledToolLabel = ""
	m.progressByCallID = nil
	m.progressOrder = nil
	m.ThoughtProgressText = ""
}

func (m ChatModel) latestProgress() *daemon.ToolProgress {
	if len(m.progressOrder) == 0 {
		return nil
	}
	return m.progressByCallID[m.progressOrder[len(m.progressOrder)-1]]
}

// Prose and thoughts occupy the action slot without discarding live calls.
func (m ChatModel) toolLabel() string {
	if m.transcript.activeKind != StreamKindNone || m.ThoughtProgressText != "" {
		return ""
	}
	if progress := m.latestProgress(); progress != nil {
		return m.liveActionLabel(progress)
	}
	return m.settledToolLabel
}

func (m ChatModel) liveActionLabel(progress *daemon.ToolProgress) string {
	if progress.Name == "python" && progress.Phase == "running" {
		if command := m.runningJobCommand(); command != "" {
			return "running " + command
		}
	}
	return actionLabel(progress, nil)
}

// runningJobCommand is the first live job's command, folded onto one row.
// It names any job, even inside its grace, because the action row shows the
// work a running cell is doing, not background work.
func (m ChatModel) runningJobCommand() string {
	for _, job := range m.Status.RunningJobs {
		if command := oneLine(job.Command); command != "" {
			return command
		}
	}
	return ""
}

// agedJobCommand is the idle status line's example: the first job past its
// grace, matching the count it sits beside.
func (m ChatModel) agedJobCommand() string {
	for _, job := range m.agedJobs() {
		if command := oneLine(job.Command); command != "" {
			return command
		}
	}
	return ""
}

func (m *ChatModel) rememberProgress(progress *daemon.ToolProgress) {
	if m.progressByCallID == nil {
		m.progressByCallID = make(map[string]*daemon.ToolProgress)
	}
	if _, exists := m.progressByCallID[progress.CallID]; exists {
		m.progressOrder = slices.DeleteFunc(m.progressOrder, func(callID string) bool { return callID == progress.CallID })
	}
	m.progressByCallID[progress.CallID] = progress
	m.progressOrder = append(m.progressOrder, progress.CallID)
	m.settledToolLabel = ""
}

func (m *ChatModel) forgetProgress(callID string) *daemon.ToolProgress {
	progress := m.progressByCallID[callID]
	delete(m.progressByCallID, callID)
	m.progressOrder = slices.DeleteFunc(m.progressOrder, func(candidate string) bool { return candidate == callID })
	return progress
}

func (m *ChatModel) handleStreamEvent(evt daemon.StreamEvent) {
	defer m.reseedMood()
	if evt.EntryID != "" {
		if index := m.History.Find(evt.EntryID); index >= 0 {
			entry := m.History.Entries()[index]
			switch evt.Type {
			case daemon.EventUser:
				entry.Speaker, entry.Source = inputSpeaker(evt), evt.Source
				entry.MailKind, entry.SenderSessionID = evt.MailKind, evt.SenderSessionID
				entry.Text = evt.Text
			case daemon.EventMessage, daemon.EventThinking:
				entry.Text = evt.Text
				entry.ElapsedMs = evt.ElapsedMs
			case daemon.EventNote:
				entry.Text = evt.Text
			case daemon.EventTool:
				entry.ToolArgs, entry.ToolResult, entry.ToolTrace = evt.ToolArgs, evt.ToolResult, evt.ToolTrace
			case daemon.EventCompacted:
				entry.Text = evt.Summary
			}
			if evt.Timestamp != nil {
				entry.Timestamp = *evt.Timestamp
			}
			entry.Seq = evt.Position
			entry.facts = nil
			if Compact(entry, m.Flags) {
				facts := factsOf(entry)
				entry.facts = &facts
			}
			m.History.Replace(entry)
			m.burstEpoch++
			m.rebuildSettledLines()
			return
		}
	}
	retireAll := evt.Type == daemon.EventRetry || evt.Type == daemon.EventError || evt.Type == daemon.EventInterrupted || evt.Type == daemon.EventTurnCompleted && evt.Source != ""
	if len(evt.ReplacesLiveIDs) > 0 || retireAll || evt.ReplacesAllLive {
		if m.History.retireLive(evt.ReplacesLiveIDs, retireAll || evt.ReplacesAllLive) {
			m.burstEpoch++
			m.rebuildSettledLines()
		}
		if retireAll {
			m.transcript.resetStream()
		}
	}
	if evt.Replayed {
		// Replayed events do not describe current activity; preserve live status.
		defer func(live daemon.AgentStatus) { m.Status = live }(m.Status)
	}
	watchedThought := !m.transcript.thinkingSince.IsZero()
	entries := m.transcript.apply(evt, m.AgentName)
	for _, entry := range entries {
		m.appendSettledEntry(entry)
	}

	switch evt.Type {
	case daemon.EventReset:
		if evt.Snapshot != nil {
			m.Status = evt.Snapshot.Status
			m.Glances = evt.Snapshot.Glances
			if m.sidebarWidth() != m.layoutSidebar {
				m.SetSize(m.Width, m.Height)
			} else {
				m.syncViewportHeight()
			}
		}
		m.History.Clear()
		m.burstEpoch++
		m.settledLines = nil
		m.settledLinesBytes, m.droppedSettledLines = 0, 0
		m.clearAction()
		m.Usage = nil
		m.ClearNotices()
		m.TurnFailed, m.Stopping, m.Stopped = false, false, false
		m.Follow, m.scrollOffset = true, 0
		m.olderBefore, m.olderMore, m.loadingOlder = evt.Before, evt.More, false
	case "status":
		if evt.Status != nil {
			m.Status.Phase = evt.Status.Phase
			m.Status.Running = evt.Status.Running
			m.Status.Idle = evt.Status.Idle
			m.Status.RunID = evt.Status.RunID
		}
	case "input", daemon.EventTurnMembership:
		if evt.Receipt != nil {
			m.applyInputReceipt(*evt.Receipt)
		}
	case daemon.EventCommitted:
		m.History.Stamp(evt.Seq)
	case daemon.EventRetry:
		m.clearAction()
	case daemon.EventUser:
		m.Stopped, m.TurnFailed = false, false
		m.clearAction()
		if !evt.Replayed {
			m.ClearNotices()
		}
		if evt.OperationID != "" {
			if i := slices.IndexFunc(m.pendingUsers, func(p PendingUserTurn) bool { return p.OperationID == evt.OperationID }); i >= 0 {
				m.pendingUsers = slices.Delete(m.pendingUsers, i, i+1)
			}
		}
	case daemon.EventText, daemon.EventThinking:
		if evt.Text != "" {
			m.settledToolLabel, m.ThoughtProgressText = "", ""
			m.Status.Running, m.Status.Idle, m.Status.Phase = true, false, &phaseReasoning
			// A thought flushed at the buffer cap keeps its last compact line
			// until the next delta, just like an explicitly settled thought.
			if evt.Type == daemon.EventThinking && m.transcript.activeText == "" && !m.transcript.thinkingSince.IsZero() {
				for _, entry := range entries {
					if entry.Kind == EntryThinking {
						m.ThoughtProgressText = cmp.Or(thinkingLine(entry.Text), "thinking")
					}
				}
			}
		}
	case daemon.EventToolProgress:
		if evt.Replayed {
			break // A progress snapshot is not an action happening now.
		}
		if evt.Progress == nil {
			m.clearAction()
			break
		}
		m.ThoughtProgressText = ""
		m.Status.Running, m.Status.Idle, m.Status.Phase = true, false, &phaseTool
		m.rememberProgress(evt.Progress)
	case daemon.EventTool:
		m.ThoughtProgressText = ""
		m.Status.Running, m.Status.Idle = true, false
		if !evt.Replayed {
			progress := m.forgetProgress(evt.ProgressCallID)
			for i := len(entries) - 1; i >= 0; i-- {
				if entries[i].Kind == EntryTool {
					m.settledToolLabel = actionLabel(progress, &entries[i])
					break
				}
			}
		}
	case daemon.EventMessage, daemon.EventTurnCompleted:
		m.clearAction()
		if evt.Type == daemon.EventTurnCompleted {
			m.Stopping = false
			if evt.Source == "interrupted" {
				m.Stopped = true
			}
			if evt.Source == "failed" {
				m.TurnFailed = true
			}
		}
	case daemon.EventError:
		m.TurnFailed = true
		m.clearAction()
		m.Status.Running, m.Status.Idle, m.Status.Phase = false, true, &phaseResting
	case daemon.EventUsage:
		m.Usage = evt.Usage
		if watchedThought {
			for _, entry := range entries {
				if entry.Kind == EntryThinking {
					m.ThoughtProgressText = cmp.Or(thinkingLine(entry.Text), "thinking")
				}
			}
		}
	case daemon.EventInterrupted:
		m.Stopping, m.Stopped, m.TurnFailed = false, true, false
		m.clearAction()
		m.Status.Running, m.Status.Idle, m.Status.Phase = false, true, &phaseResting
	}
}

// stretch is one run of a phase: a thinking or replying spell, or one tool
// call, which keeps a single animation from start to end.
type stretch struct {
	mood mood
	call string
}

// reseedMood draws a new animation when a new stretch starts, at random, so
// the same one may well come up twice.
func (m *ChatModel) reseedMood() {
	now := stretch{mood: m.phaseMood()}
	if progress := m.latestProgress(); progress != nil {
		now.call = progress.CallID
	}
	if now != m.stretch {
		m.stretch, m.moodSeed = now, rand.Int64()
	}
}
