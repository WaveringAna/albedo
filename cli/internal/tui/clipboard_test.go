package tui

// These tests catch cancellation blocked by a descendant's inherited stdout.
// The daemon E2E suite cannot drive the TUI's local clipboard subprocesses.

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestClipboardCancellationClosesDescendantStdout(t *testing.T) {
	shell, err := exec.LookPath("sh")
	if err != nil {
		t.Skip("requires sh")
	}
	for _, parent := range []string{"wait", "exit 0"} {
		t.Run(parent, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
			defer cancel()

			start := time.Now()
			out, err := execClipboardCommand(ctx, shell, "-c", `sleep 2 & printf '%s\n' "$!"; `+parent)
			elapsed := time.Since(start)
			// Kill the fixture's descendant promptly even when an assertion fails.
			pid, parseErr := strconv.Atoi(strings.TrimSpace(string(out)))
			if parseErr != nil {
				t.Fatalf("descendant did not report its PID: %q: %v", out, parseErr)
			}
			process, findErr := os.FindProcess(pid)
			if findErr != nil {
				t.Fatal(findErr)
			}
			_ = process.Kill()

			if !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("expected deadline error, got %v", err)
			}
			if elapsed >= time.Second {
				t.Fatalf("cancellation took %s with a 50 ms deadline", elapsed)
			}
		})
	}
}
