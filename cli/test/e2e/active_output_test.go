//go:build unix

// A TUI opened mid-response must hydrate the prefix before consuming its suffix,
// and replace provisional rows with exactly one canonical committed response.
package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"
	tea "charm.land/bubbletea/v2"
)

func TestTUIActiveOutputAttach(t *testing.T) {
	for _, size := range []int{32, 90000} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			prefix := strings.Repeat("p", size) + " paused α🙂"
			thinking := "thinking β"
			suffix := " final suffix"
			release := make(chan struct{})
			var releaseOnce sync.Once
			resume := func() { releaseOnce.Do(func() { close(release) }) }
			t.Cleanup(resume)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				flush := w.(http.Flusher)
				emit := func(field, text string) {
					payload, _ := json.Marshal(map[string]any{"id": "fixture", "choices": []any{map[string]any{
						"index": 0, "delta": map[string]string{field: text}, "finish_reason": nil,
					}}})
					fmt.Fprintf(w, "data: %s\n\n", payload)
					flush.Flush()
				}
				emit("reasoning_content", thinking)
				for _, part := range chunks(prefix, 1024) {
					emit("content", part)
				}
				select {
				case <-release:
				case <-r.Context().Done():
					return
				}
				emit("content", suffix)
				fmt.Fprint(w, "data: {\"id\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
				flush.Flush()
			}))
			t.Cleanup(server.Close)
			profile := fmt.Sprintf("active-output-%d", size)
			if err := saveAndSelectProvider(t.Context(), conn(t), profile, config.Settings{
				Extension: "openai", BaseURL: server.URL, APIKey: "fixture", Model: "fixture-model", Protocol: "chat_completions",
			}); err != nil {
				t.Fatal(err)
			}
			created, err := daemon.CreateSession(t.Context(), conn(t), daemon.CreateSessionRequest{Workspace: t.TempDir(), Provider: profile})
			if err != nil {
				t.Fatal(err)
			}
			session := daemonSession(t, created.ID)
			ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
			defer cancel()
			observed := make(chan struct{})
			ready := make(chan struct{})
			var readyOnce sync.Once
			observerErrors := make(chan error, 1)
			go func() {
				var text strings.Builder
				observerErrors <- daemon.NewChatClient(conn(t), session.ID).Stream(ctx, 0, func(event daemon.StreamEvent) error {
					readyOnce.Do(func() { close(ready) })
					if event.Type == daemon.EventText {
						text.WriteString(event.Text)
						if text.String() == prefix {
							close(observed)
						}
					}
					return nil
				})
			}()
			select {
			case <-ready:
			case err := <-observerErrors:
				t.Fatalf("responsive subscriber did not attach: %v", err)
			case <-ctx.Done():
				t.Fatal("responsive subscriber did not attach")
			}
			if _, err := daemon.NewChatClient(conn(t), session.ID).Send(ctx, "fixture", nil); err != nil {
				t.Fatal(err)
			}
			select {
			case <-observed:
			case err := <-observerErrors:
				t.Fatalf("responsive subscriber ended: %v", err)
			case <-ctx.Done():
				t.Fatal("responsive subscriber did not see complete prefix")
			}
			driver := driveTUI(t, &session)
			t.Cleanup(driver.App.Chat.Close)
			inbox := make(chan tea.Msg, 32)
			attachedAt := time.Now()
			streamMessages(ctx, driver.App.Chat.Init(), inbox)
			var restored, restoredThinking strings.Builder
			resumed := false
			committed := false
			for {
				select {
				case msg := <-inbox:
					cmd := driver.Update(msg)
					if event, ok := msg.(tui.ChatStreamEventMsg); ok {
						switch event.Event.Type {
						case daemon.EventCommitted:
							committed = true
						case daemon.EventText:
							if !resumed {
								restored.WriteString(event.Event.Text)
							}
						case daemon.EventThinking:
							if !resumed {
								restoredThinking.WriteString(event.Event.Text)
							}
						}
					}
					if !resumed && restored.String() == prefix && restoredThinking.String() == thinking {
						resumed = true
						t.Logf("Init to hydrated TUI prefix (%d bytes text): %s", len(prefix), time.Since(attachedAt))
						resume()
					}
					assistantCount := 0
					for _, entry := range driver.App.Chat.History.Entries() {
						if entry.Kind == tui.EntryAssistant && entry.Text == prefix+suffix && entry.Seq > 0 {
							assistantCount++
						}
					}
					if committed && assistantCount > 0 {
						if assistantCount != 1 {
							t.Fatalf("duplicate canonical responses: %d", assistantCount)
						}
						for _, entry := range driver.App.Chat.History.Entries() {
							if entry.Kind == tui.EntryAssistant && entry.Seq == 0 {
								t.Fatalf("provisional response survived canonical commit: %+v", entry)
							}
						}
						return
					}
					streamMessages(ctx, cmd, inbox)
				case <-ctx.Done():
					t.Fatalf("attachment lost prefix or duplicated response: restored=%d want=%d thinking=%q resumed=%v\n%s", restored.Len(), len(prefix), restoredThinking.String(), resumed, driver.View())
				}
			}
		})
	}
}
