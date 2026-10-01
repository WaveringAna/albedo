//go:build !(darwin || dragonfly || freebsd || linux || netbsd || openbsd)

package tui

func queryColors() (string, error) { return "", nil }
