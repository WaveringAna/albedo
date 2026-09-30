//go:build !unix

package daemon

import "os/exec"

func detach(cmd *exec.Cmd) {}

func passFileLimit() {}

// processAlive cannot be checked portably here; assume the lock holder is live.
func processAlive(int) bool { return true }
