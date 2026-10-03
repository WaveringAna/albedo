package tui

import (
	"fmt"

	tea "charm.land/bubbletea/v2"
)

// Sign-in startup can finish after its screen closes. Cleanup must still run;
// credential mutation outcomes remain visible without selecting a stale flow.
func (m *AppModel) handleLoginOutcome(msg tea.Msg) (bool, tea.Cmd) {
	switch result := msg.(type) {
	case signInStartedMsg, signInStatusMsg, signInPollMsg:
		var cmd tea.Cmd
		m.Login, cmd = m.Login.Update(msg)
		return true, cmd
	case providerSavedMsg:
		if m.State == AppStateLogin && !m.Login.closed && result.Gen == m.Login.Generation {
			return false, nil
		}
		if result.Err != nil {
			message := operationError(result.Err, "Provider update failed: ", "Provider update may have been accepted; check your accounts before trying again.")
			m.AddError(message)
			if m.State == AppStateLogin {
				m.Login.Error = message
			}
		} else {
			m.AddNotice(fmt.Sprintf("Provider %s saved.", result.Name))
		}
		return true, nil
	case signInsLoadedMsg:
		if !result.Mutation || m.State == AppStateLogin && !m.Login.closed && result.Gen == m.Login.Generation {
			return false, nil
		}
		if result.Err != nil {
			message := operationError(result.Err, "Account update failed: ", "Account update may have been accepted; check your accounts before trying again.")
			m.AddError(message)
			if m.State == AppStateLogin {
				m.Login.Error = message
			}
		} else {
			m.AddNotice("Account update saved.")
		}
		return true, nil
	}
	return false, nil
}
