//go:build unix

package daemon

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
)

// detach starts the daemon in its own session so closing the launching
// terminal (SIGHUP to its process group) does not take the daemon down.
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

// passFileLimit gives the daemon the open-file limit this process runs with.
// Go raises its own soft limit at startup but starts children with the
// original one, 256 on macOS: too few for a daemon holding client
// connections, kernels and databases. Setting the limit explicitly, even to
// the value it already has, makes every later child inherit it.
func passFileLimit() {
	var limit syscall.Rlimit
	if syscall.Getrlimit(syscall.RLIMIT_NOFILE, &limit) == nil {
		_ = syscall.Setrlimit(syscall.RLIMIT_NOFILE, &limit)
	}
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func tryLauncherLock(file *os.File) (bool, error) {
	err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
		return false, nil
	}
	return err == nil, err
}

func endpointRefused(err error) bool { return errors.Is(err, syscall.ECONNREFUSED) }
