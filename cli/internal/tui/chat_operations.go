package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

// Moved takes the session's new folder, then sends again the turn a
// missing folder refused.
func (m *ChatModel) Moved(moved daemon.Session, retry *WorkspaceRetry) tea.Cmd {
	workspace, from := moved.Workspace, m.Workspace
	m.dropSignIn() // the offer was for the old folder's host
	// a hint from an earlier move names a folder this one did not leave
	m.Notices = slices.DeleteFunc(m.Notices, func(n Notice) bool { return strings.HasPrefix(n.Message, linkHintText) })
	m.Notices.AddNotice(linkHint(from, workspace, retry))
	m.syncViewportHeight()
	m.Workspace, m.Host, m.hostHome = workspace, sessionHost(moved), ""
	m.Renderer.Workspace = workspace
	m.rebuildSettledLines() // settled rows name paths from the old workspace
	m.refreshViewportContent()
	return m.resend(retry)
}

const linkHintText = "to share memory and work with the folder you left: /link add "

// linkHint offers linking the folder a session just left with the one it
// moved to, as a command to paste. The folder is named as stored, so the
// link lands on the key the left folder's memory and work items use. A
// session that moved because its folder went missing has nothing to link.
func linkHint(from, to string, retry *WorkspaceRetry) string {
	if from == "" || from == to || retry != nil {
		return ""
	}
	return linkHintText + from
}

// resend sends again a turn the daemon refused, once what refused it is fixed.
func (m *ChatModel) resend(retry *WorkspaceRetry) tea.Cmd {
	if retry == nil {
		return nil
	}
	if retry.Image != nil && m.AttachedImage == nil {
		m.AttachedImage = retry.Image
	}
	m.TextArea.Reset()
	m.syncLayout()
	var cmds []tea.Cmd
	prompt := retry.Prompt
	if retry.Continue {
		prompt = "."
	}
	m.submitInput(prompt, &cmds)
	return tea.Batch(cmds...)
}

func (m ChatModel) queryOperationCmd(handle *daemon.OperationHandle) tea.Cmd {
	client, id, gen, ctx := m.client, m.SessionID, m.Generation, m.streamCtx
	return func() tea.Msg {
		receipt, err := client.ResolveOperation(ctx, handle)
		return ChatOperationResolvedMsg{SessionID: id, Generation: gen, Handle: handle, Receipt: receipt, Err: err}
	}
}

func (m ChatModel) resolveOperationCmd(handle *daemon.OperationHandle) tea.Cmd {
	id, gen := m.SessionID, m.Generation
	return tea.Tick(15*time.Second, func(time.Time) tea.Msg { return ChatOperationPollMsg{SessionID: id, Generation: gen, Handle: handle} })
}

func (m *ChatModel) sendCmd(handle *daemon.OperationHandle, prompt string, image *daemon.ImageAttachment, isCont bool) tea.Cmd {
	client, id, gen := m.client, m.SessionID, m.Generation
	return func() tea.Msg {
		msg := ChatTurnSentMsg{SessionID: id, Generation: gen, Prompt: prompt, Image: image, Continue: isCont, Handle: handle, OperationID: handle.ID()}
		result, err := client.SubmitOperation(context.Background(), handle)
		msg.Err = err
		if err == nil && result != nil {
			msg.OK, msg.Queued, msg.AcceptanceOrder = result.OK, result.Queued, result.AcceptanceOrder
		}
		return msg
	}
}

func (m *ChatModel) interruptCmd() tea.Cmd {
	client, id, gen := m.client, m.SessionID, m.Generation
	status := m.Status
	return func() tea.Msg {
		ok, err := client.InterruptObserved(context.Background(), status)
		return ChatInterruptMsg{SessionID: id, Generation: gen, Interrupted: ok, Err: err}
	}
}

func (m ChatModel) pendingSendCount() int {
	count := 0
	for _, pending := range m.pendingUsers {
		if !pending.Expired {
			count++
		}
	}
	return count
}

func (m ChatModel) operationRecoverable(id string) bool {
	for _, pending := range m.pendingUsers {
		if pending.OperationID == id {
			return !pending.Expired
		}
	}
	pending, exists := m.pendingContinuations[id]
	return exists && !pending.Expired
}

func (m *ChatModel) applyInputReceipt(receipt daemon.InputReceipt) {
	m.Status.InputOrder = max(m.Status.InputOrder, receipt.InputOrder())
	for i := range m.pendingUsers {
		if m.pendingUsers[i].OperationID == receipt.ID {
			m.pendingUsers[i].Queued = receipt.Pending()
			if receipt.Settled() {
				m.pendingUsers = slices.Delete(m.pendingUsers, i, i+1)
			}
			return
		}
	}
	if receipt.Settled() {
		delete(m.pendingContinuations, receipt.ID)
	}
}

func (m *ChatModel) handleOperationResults(msg tea.Msg) (tea.Cmd, bool) {
	var cmds []tea.Cmd
	switch msg := msg.(type) {
	case ChatOperationPollMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation || !m.operationRecoverable(msg.Handle.ID()) {
			return nil, true
		}
		return m.queryOperationCmd(msg.Handle), true
	case ChatOperationResolvedMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return nil, true
		}
		index := slices.IndexFunc(m.pendingUsers, func(p PendingUserTurn) bool { return p.OperationID == msg.Handle.ID() })
		if !m.operationRecoverable(msg.Handle.ID()) {
			return nil, true
		}
		if daemon.IsOperationExpired(msg.Err) {
			if index >= 0 {
				m.pendingUsers[index].Expired = true
			} else {
				pending := m.pendingContinuations[msg.Handle.ID()]
				pending.Expired = true
				m.pendingContinuations[msg.Handle.ID()] = pending
			}
			m.refreshViewportContent()
			return nil, true
		}
		if msg.Err == nil && (msg.Receipt.Admission == "rejected" || msg.Receipt.Settled()) {
			delete(m.pendingContinuations, msg.Handle.ID())
			m.dropSignIn()
			if rejection := msg.Receipt.Rejection(); rejection != nil {
				m.ClearNotices()
				m.AddError(rejection.Error())
			}
			if index >= 0 {
				m.pendingUsers = slices.Delete(m.pendingUsers, index, index+1)
			}
			m.refreshViewportContent()
			return nil, true
		}
		if msg.Err == nil {
			m.Status.InputOrder = max(m.Status.InputOrder, msg.Receipt.InputOrder())
		}
		if index >= 0 && msg.Err == nil {
			m.pendingUsers[index].Queued = true
			m.pendingUsers[index].BlockingReason = msg.Receipt.BlockingDetail()
			m.refreshViewportContent()
		}
		return tea.Batch(m.resolveOperationCmd(msg.Handle), m.hostAuthCmd(msg.Receipt.BlockingDetail())), true
	case ChatTurnSentMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return nil, true
		}
		m.isSending = false
		if msg.Err == nil {
			m.Status.InputOrder = max(m.Status.InputOrder, msg.AcceptanceOrder)
		}
		if msg.Err != nil {
			m.interruptDeferred = false
			if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](msg.Err); uncertain {
				if msg.Handle != nil && m.operationRecoverable(msg.Handle.ID()) && daemon.IsOperationExpired(msg.Err) {
					updated, cmd := m.Update(ChatOperationResolvedMsg{SessionID: m.SessionID, Generation: m.Generation, Handle: msg.Handle, Err: msg.Err})
					*m = updated
					return cmd, true
				}
				message := "Message admission is uncertain. Checking its operation receipt."
				if msg.Continue {
					message = "Continue admission is uncertain. Checking its operation receipt."
				}
				m.AddError(message)
				m.refreshViewportContent()
				if msg.Handle != nil && m.operationRecoverable(msg.Handle.ID()) {
					return m.resolveOperationCmd(msg.Handle), true
				}
				return nil, true
			}
			delete(m.pendingContinuations, msg.OperationID)
			if !msg.Continue {
				if i := slices.IndexFunc(m.pendingUsers, func(p PendingUserTurn) bool { return p.OperationID == msg.OperationID }); i >= 0 {
					m.pendingUsers = slices.Delete(m.pendingUsers, i, i+1)
				}
				if m.TextArea.Value() == "" {
					m.TextArea.SetValue(msg.Prompt)
				}
			}
			if m.AttachedImage == nil && msg.Image != nil {
				m.AttachedImage = msg.Image
			}
			if apiErr, ok := errors.AsType[*daemon.APIError](msg.Err); ok && (apiErr.Code == "workspace_invalid" || apiErr.Code == "workspace_unavailable") && m.Workspace != "" {
				m.Status.Running, m.Status.Idle = false, true
				retry := &WorkspaceRetry{Missing: m.Workspace, Prompt: msg.Prompt, Continue: msg.Continue, Image: msg.Image}
				cmds = append(cmds, func() tea.Msg { return ChatOpenFolderPickerMsg{Retry: retry} })
			} else {
				m.AddError(fmt.Sprintf("Could not send the message: %v", msg.Err))
				errText := msg.Err.Error()
				if msg.Queued {
					errText = "Message was not queued: " + errText
				}
				m.appendSettledEntry(HistoryEntry{Kind: EntryError, Text: errText})
			}
			m.refreshViewportContent()
			return tea.Batch(cmds...), true
		}

		if msg.Queued {
			if i := slices.IndexFunc(m.pendingUsers, func(p PendingUserTurn) bool {
				return p.OperationID == msg.OperationID && !p.Queued
			}); i >= 0 {
				m.pendingUsers[i].Queued = true
			}
		}
		if msg.Handle != nil && (msg.Continue || slices.ContainsFunc(m.pendingUsers, func(p PendingUserTurn) bool { return p.OperationID == msg.OperationID })) {
			cmds = append(cmds, m.resolveOperationCmd(msg.Handle))
		}

		// If user pressed Esc while this send was in flight, dispatch interrupt now that send is accepted
		if m.interruptDeferred {
			m.interruptDeferred = false
			m.Stopping = true
			cmds = append(cmds, m.interruptCmd())
		}
		return tea.Batch(cmds...), true
	case ChatInterruptMsg:
		if msg.SessionID != m.SessionID || msg.Generation != m.Generation {
			return nil, true
		}
		if msg.Err != nil || !msg.Interrupted {
			m.Stopping = false
			if msg.Err != nil {
				m.appendSettledEntry(HistoryEntry{Kind: EntryError, Text: "Could not stop the current reply: " + msg.Err.Error()})
			}
		}
		return nil, true
	}
	return nil, false
}
