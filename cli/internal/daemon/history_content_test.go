// The batched content walk shares one request among a history page, so its
// cursor, its entry membership and its byte offsets are a contract the real
// daemon cannot be made to violate.
package daemon

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// historyEntryFixture is one history entry as the daemon writes it, keyed by
// the members the decoder requires.
func historyEntryFixture(id, kind string, position int, tool map[string]any, content ...any) map[string]any {
	return map[string]any{
		"id": id, "kind": kind, "position": position, "created_at": nil,
		"input_id": nil, "turn_id": nil, "content_complete": false,
		"content": content, "tool": tool, "checkpoint_id": nil,
	}
}

func referencePart(entry, field string, bytes int) map[string]any {
	return map[string]any{"kind": "reference", "reference": map[string]any{
		"url": "/sessions/s/history/" + entry, "field": field, "bytes": bytes,
	}}
}

func textPart(text string) map[string]any { return map[string]any{"kind": "text", "text": text} }

func pagePart(entry, field string, offset int, text string, complete bool) map[string]any {
	return map[string]any{"entry_id": entry, "field": field, "offset_bytes": offset, "encoding": "utf8", "text": text, "complete": complete}
}

// batchedConnection serves one history page whose large fields are references,
// and hands every content request to the test's handler.
func batchedConnection(t *testing.T, content http.HandlerFunc) *Connection {
	t.Helper()
	return controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/sessions/s/history":
			image := map[string]any{"mime_type": "image/png", "width": 1, "height": 1, "original_bytes": 3, "reference": map[string]any{"url": "/sessions/s/history/u/image-0", "field": "image-0", "bytes": 3}}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []any{
					historyEntryFixture("u", "user", 1, nil, textPart("inspect this image"), map[string]any{"kind": "image", "image": image}),
					historyEntryFixture("a", "assistant", 2, nil, referencePart("a", "text", 6)),
					historyEntryFixture("b", "tool_result", 3, map[string]any{"name": "python", "tool_call_id": "c1", "progress_call_id": nil}, map[string]any{"kind": "json", "field": "result", "value": `{"status":"ok"}`}, referencePart("b", "arguments", 15)),
				},
				"older": nil, "newer": nil, "high_water": 3,
			})
		case r.URL.Path == "/sessions/s/history/content":
			content(w, r)
		default:
			t.Errorf("unexpected request %s", r.URL)
			http.NotFound(w, r)
		}
	})
}

// writeBatchPage writes one content page with its continuation.
func writeBatchPage(t *testing.T, w http.ResponseWriter, parts []any, next *string) {
	t.Helper()
	var encoded any
	if next != nil {
		encoded = *next
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"parts": parts, "next": encoded})
}

func TestBatchedContentWalkReconstructsAWholePage(t *testing.T) {
	requests := 0
	conn := batchedConnection(t, func(w http.ResponseWriter, r *http.Request) {
		requests++
		if got := r.URL.Query().Get("entries"); got != "a,b" {
			t.Errorf("content request named %q, want the page's referenced entries in order", got)
		}
		next := "piece-two"
		switch r.URL.Query().Get("next") {
		case "":
			writeBatchPage(t, w, []any{
				pagePart("a", "text", 0, "雪", false),
			}, &next)
		case "piece-two":
			writeBatchPage(t, w, []any{
				pagePart("a", "text", 3, "月", true),
				pagePart("b", "arguments", 0, `{"x":1}        `, true),
			}, nil)
		default:
			t.Errorf("repeated content cursor %q", r.URL.Query().Get("next"))
		}
	})
	page, err := NewChatClient(conn, "s").History(t.Context(), 0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if requests != 2 {
		t.Fatalf("a page of two references cost %d content requests, want one walk of two pages", requests)
	}
	if len(page.Events) != 6 {
		t.Fatalf("history produced %d events: %+v", len(page.Events), page.Events)
	}
	if page.Events[0].Type != EventUser || page.Events[0].Text != "inspect this image" || len(page.Events[0].Images) != 1 || page.Events[0].Images[0].Bytes != 3 {
		t.Fatalf("user entry lost its text or image metadata: %+v", page.Events[0])
	}
	if page.Events[2].Type != EventMessage || page.Events[2].Text != "雪月" {
		t.Fatalf("a field split across pages did not rejoin: %+v", page.Events[2])
	}
	tool := page.Events[4]
	if tool.Type != EventTool || tool.ToolName != "python" || tool.ToolResult != `{"status":"ok"}` || tool.ToolArgs["x"] == nil {
		t.Fatalf("tool result kept a reference instead of its arguments: %+v", tool)
	}
}

func TestBatchedContentWalkRejectsBrokenPages(t *testing.T) {
	for _, scenario := range []struct {
		name    string
		content http.HandlerFunc
	}{
		{"offset", func(w http.ResponseWriter, r *http.Request) {
			writeBatchPage(t, w, []any{
				pagePart("a", "text", 0, "雪", false),
				pagePart("a", "text", 4, "月", true),
				pagePart("b", "arguments", 0, `{"x":1}        `, true),
			}, nil)
		}},
		{"incomplete", func(w http.ResponseWriter, r *http.Request) {
			writeBatchPage(t, w, []any{
				pagePart("a", "text", 0, "雪", false),
				pagePart("b", "arguments", 0, `{"x":1}        `, true),
			}, nil)
		}},
		{"unrequested entry", func(w http.ResponseWriter, r *http.Request) {
			writeBatchPage(t, w, []any{
				pagePart("a", "text", 0, "雪月", true),
				pagePart("elsewhere", "arguments", 0, `{"x":1}        `, true),
			}, nil)
		}},
		{"wrong encoding", func(w http.ResponseWriter, r *http.Request) {
			part := pagePart("a", "text", 0, "雪月", true)
			part["encoding"] = "base64"
			writeBatchPage(t, w, []any{part, pagePart("b", "arguments", 0, `{"x":1}        `, true)}, nil)
		}},
		{"field never served", func(w http.ResponseWriter, r *http.Request) {
			writeBatchPage(t, w, []any{pagePart("a", "text", 0, "雪月", true)}, nil)
		}},
		{"not JSON", func(w http.ResponseWriter, r *http.Request) {
			writeBatchPage(t, w, []any{
				pagePart("a", "text", 0, "雪月", true),
				pagePart("b", "arguments", 0, "not json at all", true),
			}, nil)
		}},
		{"size disagrees with reference", func(w http.ResponseWriter, r *http.Request) {
			writeBatchPage(t, w, []any{
				pagePart("a", "text", 0, "雪月", true),
				pagePart("b", "arguments", 0, `{"x":1}`, true),
			}, nil)
		}},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			conn := batchedConnection(t, scenario.content)
			if _, err := NewChatClient(conn, "s").History(t.Context(), 0, 10); err == nil {
				t.Fatal("broken content page accepted")
			}
		})
	}
}

func TestBatchedContentWalkRefusesAnOversizedPage(t *testing.T) {
	requested := make([]string, contentBatchEntries+1)
	for i := range requested {
		requested[i] = "entry-" + strings.Repeat("x", i)
	}
	conn := batchedConnection(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("an oversized content request was sent")
		http.Error(w, "unexpected", http.StatusTeapot)
	})
	if _, err := readEntryContents(t.Context(), conn, "s", requested); err == nil {
		t.Fatal("a content walk named more entries than the route takes")
	}
	if _, err := readEntryContents(t.Context(), conn, "s", []string{strings.Repeat("x", contentEntryIDBytes+1)}); err == nil {
		t.Fatal("a content walk named an entry id longer than the route takes")
	}
}
