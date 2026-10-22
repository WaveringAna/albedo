package tui

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/webui"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFindOrStartWebUsesLiveManifest(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }))
	defer server.Close()
	data, _ := json.Marshal(webui.Manifest{PID: os.Getpid(), URL: server.URL})
	if err := os.WriteFile(filepath.Join(home, "web.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := findOrStartWeb(t.Context())
	if err != nil || got != server.URL {
		t.Fatalf("manifest discovery = %q, %v", got, err)
	}
}

func TestArtifactRowHasVersionedOpenAction(t *testing.T) {
	version := int64(2)
	trace := &daemon.ToolTrace{Activities: []daemon.ToolActivity{{Kind: "artifact", Target: "release timeline", Artifact: &daemon.ArtifactActivity{ID: "artifact-1", Version: version}}}}
	rendered := (TranscriptRenderer{}).RenderToolTrace(trace, DisplayFlags{}, 120)
	if !strings.Contains(rendered, "↗ open artifact albedo updated: release timeline · v2") || !strings.Contains(rendered, "albedo:artifact:artifact-1.2") {
		t.Fatalf("unexpected row: %q", rendered)
	}
}

func TestClosedBurstKeepsTheNewestArtifactRow(t *testing.T) {
	made := func(version int64) HistoryEntry {
		return HistoryEntry{Kind: EntryTool, ToolTrace: &daemon.ToolTrace{Activities: []daemon.ToolActivity{
			{Kind: "artifact", Target: "counter", Artifact: &daemon.ArtifactActivity{ID: "abc", Version: version}},
		}}}
	}
	rendered := (TranscriptRenderer{}).RenderBurst([]HistoryEntry{made(1), made(2)}, DisplayFlags{}, 120)
	if strings.Count(rendered, "albedo:artifact:") != 1 || !strings.Contains(rendered, "albedo:artifact:abc.2") {
		t.Fatalf("a closed burst should offer the newest version once: %q", rendered)
	}
}
