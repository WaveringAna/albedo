package main

import (
	"context"
	"errors"
	"strings"
	"time"
)

type phase uint8

const (
	idle phase = iota
	waiting
	loading
	ready
	failed
	stopped
)

type ticket struct {
	ctx        context.Context
	generation uint64
	query      string
}
type searchState struct {
	root       context.Context
	cancel     context.CancelFunc
	generation uint64
	query      string
	phase      phase
	rows       []string
	err        error
}

// change is called synchronously in Update at the moment intent changes.
func (s *searchState) change(query string) ticket {
	s.generation++ // Invalidate A before B's debounce, not when B's I/O starts.
	if s.cancel != nil {
		s.cancel()
	}
	ctx, cancel := context.WithTimeout(s.root, 3*time.Second)
	s.cancel = cancel
	s.query = query
	s.phase = waiting
	s.rows = nil
	s.err = nil
	return ticket{ctx: ctx, generation: s.generation, query: query}
}

func (s *searchState) begin(generation uint64) bool {
	if generation != s.generation || s.phase != waiting {
		return false
	}
	s.phase = loading
	return true
}

func (s *searchState) complete(generation uint64, rows []string, err error) bool {
	if generation != s.generation || s.phase != loading {
		return false
	}
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
	s.err = err
	if err != nil {
		s.phase = failed
		s.rows = nil
	} else {
		s.phase = ready
		s.rows = append([]string(nil), rows...)
	}
	return true
}

func (s *searchState) stop() {
	s.generation++
	s.phase = stopped
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
}

// await is used by the actual command adapter. Cancellation stops the timer
// instead of leaving a growing pile of superseded debounce timers alive.
func await(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

type searchFunc func(context.Context, string) ([]string, error)

// demoSearch is an injected local service, NOT an external API. A backend must
// honor context; generation guards alone do not bound backend resource use.
func demoSearch(ctx context.Context, query string) ([]string, error) {
	delay := 60 * time.Millisecond
	if query == "slow" {
		delay = 500 * time.Millisecond
	}
	if err := await(ctx, delay); err != nil {
		return nil, err
	}
	if query == "error" {
		return nil, errors.New("demo service unavailable")
	}
	names := []string{"alpha", "beta", "queue worker", "東京 production", "slow worker"}
	rows := make([]string, 0, len(names))
	for _, name := range names {
		if strings.Contains(strings.ToLower(name), strings.ToLower(query)) {
			rows = append(rows, name)
		}
	}
	return rows, nil
}
