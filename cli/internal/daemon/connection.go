package daemon

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
)

type ConnectionSnapshot struct {
	InstanceID string `json:"instance_id,omitempty"`
	Token      string `json:"token"`
	Build      string `json:"build,omitempty"`
	Digest     string `json:"digest,omitempty"`
	Port       int    `json:"port"`
	Pid        int    `json:"pid"`
	Version    int    `json:"version"`
}

type Connection struct {
	state       atomic.Pointer[connectionState]
	httpClient  *http.Client
	refreshGate chan struct{}
	rediscover  Rediscovery
	httpOnce    sync.Once
	refreshOnce sync.Once
}

type connectionState struct {
	endpoint     ConnectionSnapshot
	capabilities map[string]int64
}

// Rediscovery obtains an updated endpoint without owning API attachment.
type Rediscovery func(context.Context) (ConnectionSnapshot, error)

// NewConnection creates an unattached client for endpoint inspection. Attach
// validates the daemon and installs the capabilities needed by optional APIs.
// A nil rediscover disables recovery.
func NewConnection(snap ConnectionSnapshot, rediscover Rediscovery) *Connection {
	c := &Connection{rediscover: rediscover}
	c.state.Store(&connectionState{endpoint: snap})
	return c
}

func (c *Connection) Snapshot() ConnectionSnapshot {
	if c == nil {
		return ConnectionSnapshot{}
	}
	p := c.state.Load()
	if p == nil {
		return ConnectionSnapshot{}
	}
	return p.endpoint
}

func (c *Connection) Port() int {
	return c.Snapshot().Port
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
	c.state.Store(other.state.Load())
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
