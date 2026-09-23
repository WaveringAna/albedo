package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

func stateForTest(t *testing.T) *searchState {
	t.Helper()
	s := &searchState{root: context.Background()}
	t.Cleanup(s.stop)
	return s
}
func TestOldResultDuringNewDebounceIsRejected(t *testing.T) {
	s := stateForTest(t)
	a := s.change("a")
	if !s.begin(a.generation) {
		t.Fatal("A did not start")
	}
	b := s.change("b") // B has NOT started I/O yet.
	if a.ctx.Err() != context.Canceled {
		t.Fatal("A wasn't cancelled immediately")
	}
	if s.complete(a.generation, []string{"old"}, nil) || s.phase != waiting || len(s.rows) != 0 {
		t.Fatal("A leaked through debounce")
	}
	if !s.begin(b.generation) || !s.complete(b.generation, []string{"fresh"}, nil) {
		t.Fatal("B rejected")
	}
	if s.rows[0] != "fresh" {
		t.Fatal("wrong rows")
	}
}
func TestStaleFailureCannotStopNewLoading(t *testing.T) {
	s := stateForTest(t)
	a := s.change("a")
	s.begin(a.generation)
	b := s.change("b")
	s.begin(b.generation)
	if s.complete(a.generation, nil, errors.New("old error")) || s.phase != loading || s.err != nil {
		t.Fatal("stale error changed active state")
	}
}
func TestDuplicateAndStaleDebouncesDoNotStartWork(t *testing.T) {
	s := stateForTest(t)
	a := s.change("a")
	b := s.change("b")
	if s.begin(a.generation) || !s.begin(b.generation) || s.begin(b.generation) {
		t.Fatal("invalid request admission")
	}
}
func TestCompletionOwnsRowsAndRejectsDuplicate(t *testing.T) {
	s := stateForTest(t)
	a := s.change("a")
	s.begin(a.generation)
	rows := []string{"fresh"}
	s.complete(a.generation, rows, nil)
	rows[0] = "mutated"
	if s.rows[0] != "fresh" || s.complete(a.generation, nil, errors.New("late")) {
		t.Fatal("completion not isolated")
	}
	if a.ctx.Err() != context.Canceled {
		t.Fatal("completion leaked cancel resources")
	}
}
func TestRetryGetsNewIdentityAndStopRejectsResults(t *testing.T) {
	s := stateForTest(t)
	a := s.change("same")
	s.begin(a.generation)
	s.complete(a.generation, nil, errors.New("failed"))
	if s.phase != failed {
		t.Fatal("missing error phase")
	}
	b := s.change("same")
	if a.generation == b.generation || s.err != nil {
		t.Fatal("retry reuses old state")
	}
	s.begin(b.generation)
	s.stop()
	if b.ctx.Err() != context.Canceled || s.complete(b.generation, []string{"late"}, nil) || s.begin(b.generation) {
		t.Fatal("stopped request resumed")
	}
}
func TestCancelledDebounceReturnsWithoutWaiting(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	done := make(chan error, 1)
	go func() { done <- await(ctx, time.Hour) }()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled timer still waiting")
	}
}
func TestDemoBackendCancellationAndResponses(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := demoSearch(ctx, "slow"); !errors.Is(err, context.Canceled) {
		t.Fatalf("%v", err)
	}
	if rows, err := demoSearch(context.Background(), "QUEUE"); err != nil || len(rows) != 1 || rows[0] != "queue worker" {
		t.Fatalf("%v %v", rows, err)
	}
	if _, err := demoSearch(context.Background(), "error"); err == nil {
		t.Fatal("error scenario missing")
	}
}
