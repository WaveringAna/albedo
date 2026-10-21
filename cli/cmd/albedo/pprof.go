//go:build pprof

package main

import (
	"net/http"
	_ "net/http/pprof"
	"os"
)

// a pprof build (go build -tags pprof) serves net/http/pprof on
// ALBEDO_PPROF, e.g. 127.0.0.1:6060, for profiling a live TUI.
func init() {
	if addr := os.Getenv("ALBEDO_PPROF"); addr != "" {
		go http.ListenAndServe(addr, nil) //nolint:errcheck
	}
}
