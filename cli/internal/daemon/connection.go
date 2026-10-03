package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
)

type ConnectionSnapshot struct {
	Token   string `json:"token"`
	Build   string `json:"build,omitempty"`
	Digest  string `json:"digest,omitempty"`
	Port    int    `json:"port"`
	Pid     int    `json:"pid"`
	Version int    `json:"version"`
}

type Connection struct {
	snapshot    atomic.Pointer[ConnectionSnapshot]
	httpClient  *http.Client
	refreshGate chan struct{}
	rediscover  Rediscovery
	httpOnce    sync.Once
	refreshOnce sync.Once
}

// Rediscovery obtains an updated endpoint without owning API attachment.
type Rediscovery func(context.Context) (ConnectionSnapshot, error)

// NewConnection creates an API client. A nil rediscover disables recovery.
func NewConnection(snap ConnectionSnapshot, rediscover Rediscovery) *Connection {
	c := &Connection{rediscover: rediscover}
	c.snapshot.Store(&snap)
	return c
}

func (c *Connection) Snapshot() ConnectionSnapshot {
	if c == nil {
		return ConnectionSnapshot{}
	}
	p := c.snapshot.Load()
	if p == nil {
		return ConnectionSnapshot{}
	}
	return *p
}

func (c *Connection) Port() int {
	return c.Snapshot().Port
}

func (c *Connection) Token() string {
	return c.Snapshot().Token
}

func (c *Connection) Pid() int {
	return c.Snapshot().Pid
}

func (c *Connection) Version() int {
	return c.Snapshot().Version
}

func (c *Connection) Build() string {
	return c.Snapshot().Build
}

func (c *Connection) BaseURL() string {
	port := c.Port()
	if port <= 0 {
		return ""
	}
	return fmt.Sprintf("http://127.0.0.1:%d", port)
}

// Local says the daemon runs on this machine, so an ssh master opened here
// is one it can ride.
func (c *Connection) Local() bool {
	return strings.HasPrefix(c.BaseURL(), "http://127.0.0.1:")
}

func (c *Connection) Update(other *Connection) {
	if c == nil || other == nil || c == other {
		return
	}
	snap := other.Snapshot()
	c.snapshot.Store(&snap)
}

// Refresh serializes rediscovery and installs only a compatible live endpoint.
func (c *Connection) Refresh(ctx context.Context) error {
	if c == nil {
		return errors.New("not connected to Albedo")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	c.refreshOnce.Do(func() { c.refreshGate = make(chan struct{}, 1) })
	select {
	case c.refreshGate <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}
	defer func() { <-c.refreshGate }()
	if err := ctx.Err(); err != nil {
		return err
	}
	if c.rediscover == nil {
		return errors.New("daemon rediscovery is unavailable")
	}
	snap, err := c.rediscover(ctx)
	if err != nil {
		return err
	}
	attached, err := Attach(ctx, snap, nil)
	if err != nil {
		return err
	}
	defer attached.HTTPClient().CloseIdleConnections()
	c.Update(attached)
	return nil
}

// HTTPClient returns the reusable HTTP client owned by this Connection.
// Address and token updates retain the same client and pool.
func (c *Connection) HTTPClient() *http.Client {
	c.httpOnce.Do(func() { c.httpClient = newHTTPClient() })
	return c.httpClient
}

func (c *Connection) MarshalJSON() ([]byte, error) {
	snap := c.Snapshot()
	return json.Marshal(snap)
}

func (c *Connection) UnmarshalJSON(data []byte) error {
	var snap ConnectionSnapshot
	if decodeErr := json.Unmarshal(data, &snap); decodeErr != nil {
		return decodeErr
	}
	c.snapshot.Store(&snap)
	return nil
}

func ctxDone(ctx context.Context) <-chan struct{} {
	if ctx == nil {
		return nil
	}
	return ctx.Done()
}
