package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"

	"albedo/cli/internal/daemon"
)

// selectedBuild describes the daemon executable this CLI would launch. The
// label comes from ALBEDO_BUILD, or from the resolved ALBEDO_DAEMON path; the
// digest hashes the candidate's OTP application directory when its layout is
// recognizable (see appDir). A part that cannot be determined stays empty.
func selectedBuild(projectRoot string) daemon.BuildIdentity {
	identity := daemon.BuildIdentity{Build: os.Getenv("ALBEDO_BUILD")}
	candidate := os.Getenv("ALBEDO_DAEMON")
	if identity.Build == "" && candidate != "" {
		identity.Build, _ = filepath.EvalSymlinks(candidate)
	}
	if candidate == "" && projectRoot != "" {
		candidate = filepath.Join(projectRoot, "priv", "bin", "albedo-daemon")
	}
	if resolved, err := filepath.EvalSymlinks(candidate); err == nil {
		if appDir := appDir(resolved); appDir != "" {
			identity.Digest = digestTree(appDir)
		}
	}
	return identity
}

// appDir derives the OTP application directory (holding ebin and priv) that a
// daemon executable runs from. Three layouts are recognized: a packaged
// wrapper at <package>/bin/albedo-daemon with its code at
// <package>/lib/albedo/albedo, a bootstrap inside an application directory at
// <app>/priv/bin/albedo-daemon, and a source checkout bootstrap at
// <root>/priv/bin/albedo-daemon whose code gleam builds under
// <root>/build/dev/erlang/albedo. Anything else, such as a test snapshot
// launcher, stays unrecognized and compares by label alone.
func appDir(executable string) string {
	packaged := filepath.Join(filepath.Dir(executable), "..", "lib", "albedo", "albedo")
	if hasEbin(packaged) {
		return packaged
	}
	if filepath.Base(executable) != "albedo-daemon" {
		return ""
	}
	bin := filepath.Dir(executable)
	if filepath.Base(bin) != "bin" || filepath.Base(filepath.Dir(bin)) != "priv" {
		return ""
	}
	root := filepath.Dir(filepath.Dir(bin))
	if hasEbin(root) {
		return root
	}
	dev := filepath.Join(root, "build", "dev", "erlang", "albedo")
	if hasEbin(dev) {
		return dev
	}
	return ""
}

func hasEbin(dir string) bool {
	info, err := os.Stat(filepath.Join(dir, "ebin"))
	return err == nil && info.IsDir()
}

// digestTree hashes a build the way the daemon hashes its own running tree
// (albedo_daemon:build_digest/0): sha256 over the sorted relative paths and
// bytes of every regular file under ebin/ and priv/, symlinks followed. An
// unreadable path fails the whole digest, the call the daemon's walker makes
// too, and the shared fixture in test/fixtures/build-digest pins both
// implementations to one constant.
func digestTree(appDir string) string {
	var paths []string
	for _, sub := range []string{"ebin", "priv"} {
		root := filepath.Join(appDir, sub)
		info, err := os.Stat(root)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return ""
		}
		if !info.IsDir() {
			continue
		}
		paths, err = appendTreePaths(paths, root, sub)
		if err != nil {
			return ""
		}
	}
	sort.Strings(paths)
	hasher := sha256.New()
	// One buffer for every file: io.Copy from an *os.File allocates its own
	// for each, and a build tree has hundreds.
	buf := make([]byte, 32*1024)
	for _, rel := range paths {
		hasher.Write([]byte(rel))
		file, err := os.Open(filepath.Join(appDir, rel))
		if err != nil {
			return ""
		}
		_, err = io.CopyBuffer(hasher, struct{ io.Reader }{file}, buf)
		file.Close()
		if err != nil {
			return ""
		}
	}
	return hex.EncodeToString(hasher.Sum(nil))
}

func appendTreePaths(paths []string, dir, rel string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		childRel := rel + "/" + entry.Name()
		child := filepath.Join(dir, entry.Name())
		info, err := os.Stat(child) // follows symlinks, like the daemon's walker
		if err != nil {
			return nil, err
		}
		switch {
		case info.IsDir():
			if paths, err = appendTreePaths(paths, child, childRel); err != nil {
				return nil, err
			}
		case info.Mode().IsRegular():
			paths = append(paths, childRel)
		}
	}
	return paths, nil
}
