package terminal

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
)

// Real-daemon PTY tests cover approval. This checks cancellation while input is
// blocked, where a leaked reader would otherwise survive the caller's wait.
func TestRestartConfirmationCancelsBlockedInput(t *testing.T) {
	input, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	defer writer.Close()
	output := &promptSignal{ready: make(chan struct{})}
	service := Service{In: input, Out: output, Capable: true}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		approved, err := service.ConfirmRestart(ctx, daemon.ConnectionSnapshot{Pid: 42}, daemon.BuildIdentity{})
		if approved {
			result <- errors.New("cancellation approved restart")
			return
		}
		result <- err
	}()
	select {
	case <-output.ready:
	case err := <-result:
		t.Fatalf("confirmation exited before waiting: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("confirmation did not begin reading input")
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("want canceled confirmation, got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("confirmation kept waiting after cancellation")
	}
}

type promptSignal struct {
	ready chan struct{}
	once  sync.Once
}

func (s *promptSignal) Write(data []byte) (int, error) {
	// Bubble Tea starts the input program with terminal control sequences.
	if strings.Contains(string(data), "\x1b") {
		s.once.Do(func() { close(s.ready) })
	}
	return len(data), nil
}
