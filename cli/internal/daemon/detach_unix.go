//go:build unix

package daemon

import (
	"errors"
	"os/exec"
	"syscall"
)

// detach starts the daemon in its own session so closing the launching
// terminal (SIGHUP to its process group) does not take the daemon down.
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
