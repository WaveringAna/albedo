// Writer failures, especially Cobra help's void callback, must reach callers.
// Concurrent executions must not mutate their shared terminal dependency.
// A process E2E cannot inject streams or share services between executions.
package cli

import (
	"errors"
	"io"
	"strings"
	"sync"
	"testing"

	"albedo/cli/internal/terminal"
)

type failingWriter struct{ err error }

func (w failingWriter) Write([]byte) (int, error) { return 0, w.err }
func TestOutputFailuresReachExecute(t *testing.T) {
	failure := errors.New("output unavailable")
	err := Execute(t.Context(), []string{"--help"}, Dependencies{}, Streams{In: strings.NewReader(""), Out: failingWriter{failure}, Err: io.Discard})
	if !errors.Is(err, failure) {
		t.Fatalf("help swallowed write failure: %v", err)
	}
}

func TestConcurrentExecutionsKeepTerminalStreams(t *testing.T) {
	input := strings.NewReader("original input")
	term := &terminal.Service{In: input, Out: io.Discard, Err: io.Discard}
	deps := Dependencies{Terminal: term}
	var executions sync.WaitGroup
	for range 4 {
		executions.Go(func() {
			for range 20 {
				var output strings.Builder
				streams := Streams{In: strings.NewReader(""), Out: &output, Err: io.Discard}
				if err := Execute(t.Context(), []string{"--help"}, deps, streams); err != nil {
					t.Error(err)
				}
				if output.Len() == 0 {
					t.Error("help did not reach the invocation's output")
				}
			}
		})
	}
	executions.Wait()
	if term.In != input || term.Out != io.Discard || term.Err != io.Discard {
		t.Fatal("executions changed the shared terminal streams")
	}
}
