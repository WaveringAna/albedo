// Use the production helper for ownership tests, without booting its server.
package storage

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var testDaemon string

func TestMain(m *testing.M) {
	testDaemon = os.Getenv("ALBEDO_TEST_DAEMON")
	var snapshot string
	if testDaemon == "" {
		var err error
		snapshot, err = os.MkdirTemp("", "albedo-storage-tests-")
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		command := exec.Command("../../../test/snapshot-daemon.sh", filepath.Join(snapshot, "daemon"))
		command.Stderr = os.Stderr
		output, err := command.Output()
		if err != nil {
			os.RemoveAll(snapshot)
			fmt.Fprintln(os.Stderr, "build storage test daemon:", err)
			os.Exit(1)
		}
		testDaemon = strings.TrimSpace(string(output))
	}
	status := m.Run()
	if snapshot != "" {
		os.RemoveAll(snapshot)
	}
	os.Exit(status)
}

func testCommand(ctx context.Context, args ...string) (*exec.Cmd, error) {
	return exec.CommandContext(ctx, testDaemon, args...), nil
}
