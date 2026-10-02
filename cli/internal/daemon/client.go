package daemon

import (
	"crypto/rand"
	"encoding/hex"
	"strings"
	"sync"
)

// ChatClient retains the cursor and argument state for one stream subscription.
// Callers must serialize stream subscriptions and reset operations.
type ChatClient struct {
	conn            *Connection
	argumentsByCall map[string]*strings.Builder
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
		conn:            conn,
		agentID:         strings.TrimSpace(agentID),
		clientID:        "cli-" + hex.EncodeToString(identity),
		afterSeq:        -1,
		argumentsByCall: make(map[string]*strings.Builder),
	}
}

func (c *ChatClient) ClientID() string {
	return c.clientID
}
