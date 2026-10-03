package daemon

import (
	"crypto/rand"
	"encoding/hex"
	"strings"
	"sync"
)

// ChatClient retains the cursor and live progress keys for one subscription.
// Callers must serialize stream subscriptions and reset operations.
type ChatClient struct {
	conn            *Connection
	progressCallIDs map[string]struct{}
	agentID         string
	clientID        string
	afterSeq        int64
	afterGeneration string
	mu              sync.Mutex
}

// NewChatClient shares conn's HTTP transport. A nil connection panics.
func NewChatClient(conn *Connection, agentID string) *ChatClient {
	if conn == nil {
		panic("daemon.NewChatClient: nil connection")
	}
	identity := make([]byte, 16)
	_, _ = rand.Read(identity)
	return &ChatClient{
		conn:     conn,
		agentID:  strings.TrimSpace(agentID),
		clientID: "cli-" + hex.EncodeToString(identity),
		afterSeq: -1,
	}
}
