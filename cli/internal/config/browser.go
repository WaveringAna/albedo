package config

import (
	"os/exec"
	"runtime"
)

// OpenBrowser opens a URL in the system's default browser.
func OpenBrowser(urlStr string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", urlStr)
	case "windows":
		cmd = exec.Command("cmd", "/c", "start", "", urlStr)
	default:
		cmd = exec.Command("xdg-open", urlStr)
	}
	_ = cmd.Start()
}
