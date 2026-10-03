//go:build unix

package e2e

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
)

// A raw protocol reader and the Go client attach to the same paused real
// daemon turn. The reset snapshot must describe current activity and arrive
// through the Go callback as live normalized progress. Finalized file changes
// must also survive both the live result and durable history projection.
func TestLateChatClientRestoresNormalizedToolProgress(t *testing.T) {
	t.Parallel()
	const code = "from pathlib import Path\nimport time\nPath('progress-ready').write_text('ready')\nwhile not Path('finish-progress').exists(): time.sleep(0.01)\nfiles.write('trace-display.txt', 'finished trace\\n')\nprint('finished')"
	ready, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	provider := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		call := calls.Add(1)
		writer.Header().Set("Content-Type", "text/event-stream")
		flusher, _ := writer.(http.Flusher)
		writeChunk := func(delta map[string]any, finish string) {
			choice := map[string]any{"index": 0, "delta": delta, "finish_reason": nil}
			if finish != "" {
				choice["finish_reason"] = finish
			}
			chunk, _ := json.Marshal(map[string]any{"id": "go-progress-e2e", "choices": []any{choice}})
			_, _ = fmt.Fprintf(writer, "data: %s\n\n", chunk)
			if flusher != nil {
				flusher.Flush()
			}
		}
		if call == 1 {
			args, _ := json.Marshal(map[string]string{"code": code})
			for offset := 0; offset < len(args); offset += 9 {
				fragment := string(args[offset:min(len(args), offset+9)])
				delta := map[string]any{"tool_calls": []any{map[string]any{
					"index": 0, "function": map[string]any{"arguments": fragment},
				}}}
				if offset == 0 {
					delta["tool_calls"] = []any{map[string]any{
						"index": 0, "id": "native-go-progress", "type": "function",
						"function": map[string]any{"name": "python", "arguments": fragment},
					}}
				}
				writeChunk(delta, "")
			}
			close(ready)
			select {
			case <-release:
			case <-request.Context().Done():
				return
			case <-time.After(30 * time.Second):
				http.Error(writer, "test release timed out", http.StatusGatewayTimeout)
				return
			}
			writeChunk(map[string]any{}, "tool_calls")
		} else {
			writeChunk(map[string]any{"content": "done"}, "")
			writeChunk(map[string]any{}, "stop")
		}
		_, _ = fmt.Fprint(writer, "data: [DONE]\n\n")
	}))
	t.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
		provider.Close()
	})

	profile := t.Name()
	if err := saveAndSelectProvider(context.Background(), conn(t), profile, config.Settings{
		Extension: "openai", BaseURL: provider.URL, APIKey: "fixture-key",
		Model: "fixture-model", Protocol: "chat_completions",
	}); err != nil {
		t.Fatal(err)
	}
	workspace := t.TempDir()
	finishPath := filepath.Join(workspace, "finish-progress")
	t.Cleanup(func() { _ = os.WriteFile(finishPath, []byte("finish"), 0o600) })
	session := newSession(t, workspace)
	client := daemon.NewChatClient(conn(t), session)
	if _, err := client.Send(t.Context(), "pause for Go progress attachment", nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ready:
	case <-time.After(30 * time.Second):
		t.Fatal("provider did not reach the tool argument barrier")
	}

	compareReset := func(phase string) []daemon.ToolProgress {
		t.Helper()
		// A flushed provider fragment may still be waiting for the actor.
		// Wait for its full short preview before comparing two attachments.
		wireProgress := waitCurrentProgress(t, conn(t), session, phase, code)
		if len(wireProgress) != 1 || wireProgress[0].Phase != phase || wireProgress[0].Code == nil || wireProgress[0].Code.Text == "" {
			t.Fatalf("raw reset did not expose the active call: %+v", wireProgress)
		}
		stop := errors.New("received live reset snapshot")
		var restored *daemon.ToolProgress
		err := daemon.NewChatClient(conn(t), session).Stream(t.Context(), 0, func(event daemon.StreamEvent) error {
			if event.Type == daemon.EventToolProgress {
				if event.Replayed {
					t.Error("current progress was marked as replayed history")
				}
				restored = event.Progress
				return stop
			}
			return nil
		})
		if !errors.Is(err, stop) {
			t.Fatalf("Go stream did not deliver current progress: %v", err)
		}
		if restored == nil || !reflect.DeepEqual(*restored, wireProgress[0]) {
			t.Fatalf("Go callback differs from independently decoded reset snapshot: raw=%+v callback=%+v", wireProgress[0], restored)
		}
		return wireProgress
	}
	generating := compareReset("generating")
	if generating[0].Phase != "generating" {
		t.Fatalf("initial progress phase = %q, want generating", generating[0].Phase)
	}

	close(release)
	deadline := time.Now().Add(30 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(workspace, "progress-ready")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("Python tool did not reach its running barrier")
		}
		time.Sleep(25 * time.Millisecond)
	}
	running := compareReset("running")
	if running[0].Phase != "running" || running[0].CallID != generating[0].CallID {
		t.Fatalf("running reset lost call identity or phase: generating=%+v running=%+v", generating[0], running[0])
	}
	finishedTrace := errors.New("received finalized tool trace")
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	var liveTrace *daemon.ToolTrace
	err := daemon.NewChatClient(conn(t), session).Stream(ctx, 0, func(event daemon.StreamEvent) error {
		if event.Type == daemon.EventToolProgress && event.Progress != nil && event.Progress.Phase == "running" {
			return os.WriteFile(finishPath, []byte("finish"), 0o600)
		}
		if event.Type == daemon.EventTool && event.ToolName == "python" {
			if event.Replayed {
				t.Error("live tool result was marked as replayed history")
			}
			liveTrace = event.ToolTrace
			return finishedTrace
		}
		return nil
	})
	if !errors.Is(err, finishedTrace) {
		t.Fatalf("finalized tool trace did not reach the Go callback: %v", err)
	}
	assertTrace := func(trace *daemon.ToolTrace) {
		t.Helper()
		if trace == nil {
			t.Fatal("tool result lost its finalized trace")
		}
		for _, change := range trace.Changes {
			if filepath.Base(change.Path) == "trace-display.txt" && change.Kind == "diff" && strings.Contains(change.Diff, "+finished trace") {
				return
			}
		}
		t.Fatalf("tool trace lost the actual file change: %+v", trace)
	}
	assertTrace(liveTrace)
	deadline = time.Now().Add(30 * time.Second)
	for {
		status, err := client.GetStatus(t.Context())
		if err != nil {
			t.Fatal(err)
		}
		if calls.Load() >= 2 && !status.Running {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("tool turn did not finish: provider calls=%d status=%+v", calls.Load(), status)
		}
		time.Sleep(25 * time.Millisecond)
	}
	history, err := client.History(t.Context(), 0, 120)
	if err != nil {
		t.Fatal(err)
	}
	var replayedTrace *daemon.ToolTrace
	for _, event := range history.Events {
		if event.Type == daemon.EventTool && event.ToolName == "python" {
			replayedTrace = event.ToolTrace
		}
	}
	assertTrace(replayedTrace)
	if !reflect.DeepEqual(liveTrace, replayedTrace) {
		t.Fatalf("durable history changed the finalized trace: live=%+v history=%+v", liveTrace, replayedTrace)
	}
}

func readCurrentProgress(t *testing.T, connection *daemon.Connection, session string) []daemon.ToolProgress {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	endpoint := connection.BaseURL() + "/sessions/" + url.PathEscape(session)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Accept", "text/event-stream")
	request.Header.Set("Authorization", "Bearer "+connection.Snapshot().Token)
	response, err := connection.HTTPClient().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("raw session stream: %s", response.Status)
	}
	scanner := bufio.NewScanner(response.Body)
	scanner.Buffer(make([]byte, 4096), 10*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var batch struct {
			Events   []map[string]any `json:"events"`
			Snapshot struct {
				CurrentProgress []struct {
					CallID     string  `json:"call_id"`
					ToolCallID *string `json:"tool_call_id"`
					Name       string  `json:"name"`
					Phase      string  `json:"phase"`
					Preview    *struct {
						Text   string `json:"text"`
						Offset int    `json:"offset_scalars"`
					} `json:"preview"`
				} `json:"current_progress"`
			} `json:"snapshot"`
		}
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &batch); err != nil {
			t.Fatal(err)
		}
		if len(batch.Events) == 0 || batch.Events[0]["type"] != "reset" {
			t.Fatalf("late raw attachment did not begin with a reset: %+v", batch.Events)
		}
		if batch.Snapshot.CurrentProgress == nil {
			t.Fatal("reset snapshot omitted current_progress")
		}
		result := []daemon.ToolProgress{}
		for _, item := range batch.Snapshot.CurrentProgress {
			progress := daemon.ToolProgress{CallID: item.CallID, Name: item.Name, Phase: item.Phase}
			if item.ToolCallID != nil {
				progress.ToolCallID = *item.ToolCallID
			}
			if item.Preview != nil {
				progress.Code = &daemon.ToolCodePreview{Text: item.Preview.Text, Offset: item.Preview.Offset}
			}
			result = append(result, progress)
		}
		return result
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	t.Fatal("raw session stream ended before a reset batch")
	return nil
}

func waitCurrentProgress(t *testing.T, connection *daemon.Connection, session, phase, code string) []daemon.ToolProgress {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for {
		progress := readCurrentProgress(t, connection, session)
		if len(progress) == 1 && progress[0].Phase == phase && progress[0].Code != nil && progress[0].Code.Offset == 0 && progress[0].Code.Text == code {
			return progress
		}
		if time.Now().After(deadline) {
			t.Fatal("reset snapshots never exposed the provider's live progress")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
