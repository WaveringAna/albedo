package tui

import (
	"os"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestShortTargetKeepsWhatDiffers(t *testing.T) {
	r := NewTranscriptRenderer()
	store := "/nix/store/nbdsrxykbb3ghsldfn5qckaqppgiblcn-albedo-daemon-1.0.0/lib/albedo/priv/python/albedo_plugins/bash.py"
	if got := r.shortTarget(store, true, 200); got != "/nix/store/…-albedo-daemon-1.0.0/lib/albedo/priv/python/albedo_plugins/bash.py" {
		t.Fatalf("store hash kept: %q", got)
	}
	got := r.shortTarget(store, true, 40)
	if ansi.StringWidth(got) != 40 || got[len(got)-len("bash.py"):] != "bash.py" || got[:len("/nix/store/")] != "/nix/store/" {
		t.Fatalf("path lost its ends: %q", got)
	}
	if got := r.shortTarget("cargo build --release --locked", false, 12); got != "cargo build…" {
		t.Fatalf("command not cut at the end: %q", got)
	}
}

func TestShortTargetNamesPathsFromTheWorkspace(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		t.Skip("no home directory")
	}
	for _, workspace := range []string{home + "/proj/albedo", "~/proj/albedo/"} {
		r := TranscriptRenderer{Workspace: workspace}
		cases := map[string]string{
			home + "/proj/albedo/cli/internal/tui/transcript.go": "cli/internal/tui/transcript.go",
			home + "/proj/hydrant":                               "~/proj/hydrant",
			home + "/proj/albedo2/x":                             "~/proj/albedo2/x",
			"/tmp/drain_probe.py":                                "/tmp/drain_probe.py",
			"git -C " + home + "/proj/albedo/cli diff":           "git -C cli diff",
		}
		for target, want := range cases {
			if got := r.shortTarget(target, true, 200); got != want {
				t.Fatalf("workspace %q: %q became %q, want %q", workspace, target, got, want)
			}
		}
	}
}
