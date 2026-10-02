//go:build !unix

package daemon

import (
	"errors"
	"os"
	"os/exec"
)

func detach(cmd *exec.Cmd) {}

func passFileLimit() {}

// processAlive cannot be checked portably here; assume the lock holder is live.
func processAlive(int) bool { return true }

func tryLauncherLock(*os.File) (bool, error) {
	return false, errors.New("local daemon launch requires a platform with advisory file locks")
}
func endpointRefused(error) bool { return false }
