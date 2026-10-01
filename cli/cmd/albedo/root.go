package main

import (
	"os"
	"path/filepath"
)

func isAlbedoRoot(dir string) bool {
	if dir == "" {
		return false
	}
	if _, err := os.Stat(filepath.Join(dir, "gleam.toml")); err == nil {
		if _, err := os.Stat(filepath.Join(dir, "src", "albedo.gleam")); err == nil {
			return true
		}
	}
	return false
}

func findProjectRoot() string {
	if env := os.Getenv("ALBEDO_ROOT"); env != "" && isAlbedoRoot(env) {
		return env
	}
	if exe, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		// Check exe/../.. (e.g. repo/cli/bin/albedo -> repo)
		parent2 := filepath.Dir(filepath.Dir(exe))
		if isAlbedoRoot(parent2) {
			return parent2
		}
		parent3 := filepath.Dir(parent2)
		if isAlbedoRoot(parent3) {
			return parent3
		}
	}
	if buildRoot != "" && isAlbedoRoot(buildRoot) {
		return buildRoot
	}
	if cwd, err := os.Getwd(); err == nil {
		cur := cwd
		for {
			if isAlbedoRoot(cur) {
				return cur
			}
			parent := filepath.Dir(cur)
			if parent == cur {
				break
			}
			cur = parent
		}
	}
	if buildRoot != "" {
		return buildRoot
	}
	cwd, _ := os.Getwd()
	return cwd
}
