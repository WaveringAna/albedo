package tui

import (
	"cmp"
	"context"
	"errors"
	"os/exec"
	"slices"

	tea "charm.land/bubbletea/v2"

	"albedo/cli/internal/daemon"
)

// hostSignIn is the session's host needing a person to sign in over ssh
// before a waiting turn can start. ctrl+l opens the daemon's ControlMaster
// in this terminal when the daemon shares this machine, so ssh can ask for
// the passphrase or code here; then the host is probed again and the
// waiting turn starts on the daemon's next try.
type hostSignIn struct {
	host, controlPath, notice string
	here                      bool
}

// chatHostAuthMsg is the probe of a host a blocked turn may be waiting on.
type chatHostAuthMsg struct {
	SessionID  string
	Generation int64
	Status     daemon.HostStatus
}

type chatSignedInMsg struct {
	SessionID string
	Err       error
}

// hostAuthCmd asks the host of a remote session whose waiting turn is
// blocked whether it needs a sign-in: the daemon's reason is ssh's words,
// and the probe carries the control path the sign-in opens.
func (m *ChatModel) hostAuthCmd(blocked string) tea.Cmd {
	host, _ := daemon.SplitLocation(m.Workspace)
	if host == "" || blocked == "" || m.hostAuth != nil {
		return nil
	}
	client, ctx, id, generation := m.client, m.streamCtx, m.SessionID, m.Generation
	return func() tea.Msg {
		status, err := client.Host(ctx, host)
		if err != nil || status.State != "needs_auth" {
			return nil
		}
		return chatHostAuthMsg{SessionID: id, Generation: generation, Status: status}
	}
}

// offerSignIn says how to sign in: here when the daemon shares this machine
// (its master socket is ours to open), otherwise on the daemon's machine.
func (m *ChatModel) offerSignIn(msg chatHostAuthMsg) {
	if msg.SessionID != m.SessionID || msg.Generation != m.Generation || m.hostAuth != nil {
		return
	}
	host := msg.Status.Host
	auth := &hostSignIn{host: host, controlPath: msg.Status.ControlPath, here: m.client.LocalDaemon()}
	auth.notice = "Run `ssh " + host + "` on the machine albedo runs on; the waiting message goes after."
	if auth.here {
		auth.notice = "Press ctrl+l to sign in to " + cmp.Or(m.Host, host) + " here; the waiting message goes after."
	}
	m.hostAuth = auth
	m.AddError(auth.notice)
}

// signInCmd runs `ssh -M -fN` on the daemon's control path: ssh prompts in
// the terminal, forks the master into the background once signed in, and the
// daemon's BatchMode connections ride it from then on.
func (m *ChatModel) signInCmd() tea.Cmd {
	auth, client, id := m.hostAuth, m.client, m.SessionID
	return tea.ExecProcess(signInCommand(auth.host, auth.controlPath), func(err error) tea.Msg {
		if err == nil {
			var status daemon.HostStatus
			status, err = client.WarmHost(context.Background(), auth.host)
			if err == nil && status.State != "ready" {
				err = errors.New(cmp.Or(status.Detail, status.State))
			}
		}
		return chatSignedInMsg{SessionID: id, Err: err}
	})
}

// signInCommand opens host's master on controlPath, asking in the terminal.
func signInCommand(host, controlPath string) *exec.Cmd {
	return exec.Command("ssh", "-M", "-fN", "-o", "ControlPath="+controlPath, "-o", "ControlPersist=600", host)
}

func (m *ChatModel) signedIn(msg chatSignedInMsg) {
	auth := m.hostAuth
	if msg.SessionID != m.SessionID || auth == nil {
		return
	}
	if msg.Err != nil {
		m.AddError("Signing in to " + auth.host + " failed: " + msg.Err.Error())
		return
	}
	m.dropSignIn()
}

// dropSignIn forgets the offer once nothing waits on it: signed in, or the
// turn it was for started or went away.
func (m *ChatModel) dropSignIn() {
	if auth := m.hostAuth; auth != nil {
		m.hostAuth = nil
		m.Notices = slices.DeleteFunc(m.Notices, func(n Notice) bool { return n.Message == auth.notice })
		m.syncViewportHeight()
	}
}
