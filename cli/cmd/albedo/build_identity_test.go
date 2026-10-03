package main

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

// The daemon hashes its own running tree with the same recipe; the shared
// fixture in test/fixtures/build-digest pins both implementations together.
func TestDigestTreeMatchesTheSharedFixture(t *testing.T) {
	fixture := filepath.Join("..", "..", "..", "test", "fixtures", "build-digest")
	const want = "a8f2d0de5c26845d69d69f9a98111ab795b83d4ab24e6f18068b57145c13fe42"
	if got := digestTree(fixture); got != want {
		t.Fatalf("digestTree(fixture) = %q, want %q", got, want)
	}
}

// An unreadable path must fail the whole digest rather than hash a subset the
// daemon would hash differently.
func TestDigestTreeFailsClosedOnUnreadablePaths(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "ebin", "readable.beam"), "readable")
	sealed := filepath.Join(root, "ebin", "sealed.beam")
	write(t, sealed, "sealed")
	if err := os.Chmod(sealed, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(sealed, 0o600) })
	if got := digestTree(root); got != "" {
		t.Fatalf("digestTree(unreadable) = %q, want empty", got)
	}
}

func TestAppDirRecognizesTheKnownLayouts(t *testing.T) {
	root := t.TempDir()

	packaged := filepath.Join(root, "pkg")
	write(t, filepath.Join(packaged, "bin", "albedo-daemon"), "#!/bin/sh\n")
	write(t, filepath.Join(packaged, "lib", "albedo", "albedo", "ebin", "m.beam"), "beam")
	if got := appDir(filepath.Join(packaged, "bin", "albedo-daemon")); got != filepath.Join(packaged, "lib", "albedo", "albedo") {
		t.Fatalf("packaged wrapper: appDir = %q", got)
	}

	application := filepath.Join(root, "app")
	write(t, filepath.Join(application, "priv", "bin", "albedo-daemon"), "#!/bin/sh\n")
	write(t, filepath.Join(application, "ebin", "m.beam"), "beam")
	if got := appDir(filepath.Join(application, "priv", "bin", "albedo-daemon")); got != application {
		t.Fatalf("in-application bootstrap: appDir = %q", got)
	}

	checkout := filepath.Join(root, "checkout")
	write(t, filepath.Join(checkout, "priv", "bin", "albedo-daemon"), "#!/bin/sh\n")
	dev := filepath.Join(checkout, "build", "dev", "erlang", "albedo")
	write(t, filepath.Join(dev, "ebin", "m.beam"), "beam")
	if got := appDir(filepath.Join(checkout, "priv", "bin", "albedo-daemon")); got != dev {
		t.Fatalf("checkout bootstrap: appDir = %q", got)
	}

	// A test snapshot launcher names no recognizable layout and compares by
	// label alone.
	snapshot := filepath.Join(root, "snapshot")
	write(t, filepath.Join(snapshot, "albedo-daemon"), "#!/bin/sh\n")
	write(t, filepath.Join(snapshot, "albedo", "ebin", "m.beam"), "beam")
	if got := appDir(filepath.Join(snapshot, "albedo-daemon")); got != "" {
		t.Fatalf("snapshot launcher: appDir = %q, want empty", got)
	}
}

func TestSelectedBuildLabelsAndDigestsTheCandidate(t *testing.T) {
	checkout := t.TempDir()
	write(t, filepath.Join(checkout, "priv", "bin", "albedo-daemon"), "#!/bin/sh\n")
	write(t, filepath.Join(checkout, "build", "dev", "erlang", "albedo", "ebin", "m.beam"), "beam")
	t.Setenv("ALBEDO_BUILD", "")
	t.Setenv("ALBEDO_DAEMON", "")

	identity := selectedBuild(checkout)
	if identity.Build != "" {
		t.Fatalf("unlabeled candidate carried a label: %q", identity.Build)
	}
	if want := digestTree(filepath.Join(checkout, "build", "dev", "erlang", "albedo")); identity.Digest != want {
		t.Fatalf("candidate digest = %q, want the derived tree's %q", identity.Digest, want)
	}

	// A candidate whose layout is unrecognized reports no digest.
	snapshot := filepath.Join(checkout, "snapshot")
	write(t, filepath.Join(snapshot, "albedo-daemon"), "#!/bin/sh\n")
	t.Setenv("ALBEDO_DAEMON", filepath.Join(snapshot, "albedo-daemon"))
	identity = selectedBuild(checkout)
	if identity.Digest != "" {
		t.Fatalf("snapshot digest = %q, want empty", identity.Digest)
	}
	if identity.Build == "" {
		t.Fatal("ALBEDO_DAEMON path did not become the label")
	}
}
