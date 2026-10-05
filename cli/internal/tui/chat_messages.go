package tui

import (
	"albedo/cli/internal/daemon"
)

type ChatBackToSessionsMsg struct{}

type ChatQuitMsg struct{}

// ChatEditorFinishedMsg is sent after the external editor process exits.
type ChatEditorFinishedMsg struct {
	Err        error
	SessionID  string
	Text       string
	Generation int64
	Edited     bool
}

// ChatOlderLoadedMsg carries a page of history from before what is shown.
type ChatOlderLoadedMsg struct {
	Err        error
	Page       *daemon.HistoryPage
	SessionID  string
	Generation int64
}

type ChatNewSessionMsg struct{}

type ChatOpenModelPickerMsg struct{}

type ChatOpenExtensionPickerMsg struct{}

type ChatOpenTreePickerMsg struct{}

type ChatOpenContextInspectorMsg struct{}

type ChatOpenPageMsg struct {
	Command string
}

type ChatOpenLoginMsg struct {
	Name string
}

type ChatExecuteCommandMsg struct {
	Name string
	Args string
}

type ChatStreamEventMsg struct {
	SessionID  string
	Event      daemon.StreamEvent
	Generation int64
}

type ChatProgressTickMsg struct {
	SessionID  string
	Generation int64
}

type ChatClearCopyStatusMsg struct {
	SessionID  string
	Generation int64
	Revision   uint64
}

type ChatStatusMsg struct {
	Err        error
	Status     *daemon.AgentStatus
	Glances    []PageGlance
	SessionID  string
	Generation int64
	Revision   uint64
}

// ChatHostMsg is the probe of the host a remote workspace is on.
type ChatHostMsg struct {
	Err        error
	SessionID  string
	Workspace  string
	Status     daemon.HostStatus
	Generation int64
}

// ChatWindowMsg carries the context window for the model a usage event named.
type ChatWindowMsg struct {
	Err        error
	Tokens     *int
	SessionID  string
	Model      string
	Generation int64
}

// ChatCacheFadeMsg arrives when Usage's cached count reaches its next step.
type ChatCacheFadeMsg struct {
	Usage      *daemon.Usage
	SessionID  string
	Generation int64
}

type ChatStatusPollMsg struct {
	SessionID  string
	Generation int64
	Poll       uint64
}

// ChatStreamResultMsg follows all accepted events from the same subscription.
type ChatStreamResultMsg struct {
	SessionID  string
	Generation int64
	Err        error
	Recovering bool
}

type streamDelivery struct {
	Event      *daemon.StreamEvent
	Err        error
	Recovering bool
}

type ChatStreamClosedMsg struct {
	SessionID  string
	Generation int64
}

type ChatOperationResolvedMsg struct {
	SessionID  string
	Generation int64
	Handle     *daemon.OperationHandle
	Receipt    daemon.InputReceipt
	Err        error
}

type ChatTurnSentMsg struct {
	Handle          *daemon.OperationHandle
	OperationID     string
	Err             error
	Images          []daemon.ImageAttachment
	Pastes          []string
	SessionID       string
	Prompt          string
	Generation      int64
	Continue        bool
	OK              bool
	Queued          bool
	AcceptanceOrder int64
}

type ChatInterruptMsg struct {
	Err         error
	SessionID   string
	Generation  int64
	Interrupted bool
}

// ChatOpenFolderPickerMsg asks for the folder picker; Retry is the turn a
// missing workspace refused.
type ChatOpenFolderPickerMsg struct{ Retry *WorkspaceRetry }

type ChatOperationPollMsg struct {
	SessionID  string
	Generation int64
	Handle     *daemon.OperationHandle
}
