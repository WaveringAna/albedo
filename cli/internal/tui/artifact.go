package tui

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/webui"
	tea "charm.land/bubbletea/v2"
)

type artifactOpenResult struct {
	Notice string
	Err    error
}

// artifactRow renders one selectable artifact activity consistently in transcript and cards.
func artifactRow(activity daemon.ToolActivity, width int) string {
	if activity.Artifact == nil {
		return ""
	}
	label := "↗ open artifact albedo made for you: " + activity.Target
	if activity.Artifact.Version > 1 {
		label = fmt.Sprintf("↗ open artifact albedo updated: %s · v%d", activity.Target, activity.Artifact.Version)
	}
	key := activity.Artifact.ID + "." + strconv.FormatInt(activity.Artifact.Version, 10)
	return fit(rowAction{verb: verbArtifact, key: key}.mark()+DefaultStyles.Busy.Render(label), "", width)
}

func (m ChatModel) openArtifactAction(key string) tea.Cmd {
	id, versionText, ok := strings.Cut(key, ".")
	version, err := strconv.ParseInt(versionText, 10, 64)
	if !ok || id == "" || err != nil || version < 1 || m.artifactConn == nil {
		return func() tea.Msg { return artifactOpenResult{Err: errors.New("artifact details are unavailable")} }
	}
	return openArtifactCmd(m.artifactConn, m.openBrowser, id, version)
}

func openArtifactCmd(conn *daemon.Connection, openBrowser func(string), id string, version int64) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		artifact, err := daemon.GetArtifact(ctx, conn, id)
		if err != nil {
			var api *daemon.APIError
			if errors.As(err, &api) && api.StatusCode == http.StatusNotFound {
				return artifactOpenResult{Err: errors.New("this artifact was deleted")}
			}
			return artifactOpenResult{Err: fmt.Errorf("could not read artifact: %w", err)}
		}
		key := artifact.Key
		if key == "" {
			return artifactOpenResult{Err: errors.New("artifact has no page key")}
		}
		base, err := findOrStartWeb(ctx)
		if err != nil {
			return artifactOpenResult{Err: err}
		}
		entry := artifact.Entry
		if entry == "" {
			return artifactOpenResult{Err: errors.New("artifact has no entry page")}
		}
		target := strings.TrimRight(base, "/") + "/frame/" + id + "." + key + "/" + strconv.FormatInt(version, 10) + "/" + entry
		if openBrowser != nil {
			openBrowser(target)
		}
		return artifactOpenResult{Notice: "opened " + artifact.Title + " in your browser"}
	}
}

func findOrStartWeb(ctx context.Context) (string, error) {
	path := webui.ManifestPath()
	if manifest, err := webui.ReadManifest(path); err == nil && webui.ManifestAlive(manifest) {
		return manifest.URL, nil
	}
	executable, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("cannot find albedo web: %w", err)
	}
	log, err := os.OpenFile(filepath.Join(filepath.Dir(path), "web.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return "", fmt.Errorf("cannot start albedo web: %w", err)
	}
	command := exec.Command(executable, "web", "--no-open")
	command.Stdout, command.Stderr, command.Env = log, log, os.Environ()
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		log.Close()
		return "", fmt.Errorf("cannot start albedo web: %w", err)
	}
	_ = log.Close()
	go func() { _ = command.Wait() }() // reaped when it stops, not left as a zombie
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return "", errors.New("albedo web did not start within 8 seconds")
		case <-ticker.C:
			if manifest, err := webui.ReadManifest(path); err == nil && webui.ManifestAlive(manifest) {
				return manifest.URL, nil
			}
		}
	}
}
