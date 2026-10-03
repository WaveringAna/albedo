// Controlled peers exercise delivery and failure behavior the real daemon cannot force deterministically.
package daemon

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestPagedContentValidatesOffsetsAndReconstructsUTF8(t *testing.T) {
	for _, failure := range []string{"", "offset", "false completeness"} {
		t.Run(failure, func(t *testing.T) {
			imageReads := 0
			image := map[string]any{"mime_type": "image/png", "width": 1, "height": 1, "original_bytes": 3, "reference": map[string]any{"url": "/sessions/s/history/u", "field": "image-0", "bytes": 3}}
			conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/sessions/s/history" {
					entry := func(id, kind string, position int, content ...any) map[string]any {
						return map[string]any{"id": id, "kind": kind, "position": position, "created_at": nil, "input_id": nil, "turn_id": nil, "content_complete": false, "content": content, "tool": nil, "checkpoint_id": nil}
					}
					partial := entry("e", "assistant", 2, map[string]any{"kind": "reference", "reference": map[string]any{"url": "/sessions/s/history/e", "field": "text", "bytes": 6}})
					partial["content_complete"] = failure == "false completeness"
					complete := entry("full", "assistant", 3, map[string]any{"kind": "text", "text": strings.Repeat("complete reply ", 128)})
					complete["content_complete"] = true
					_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{
						entry("u", "user", 1, map[string]any{"kind": "text", "text": "inspect this image"}, map[string]any{"kind": "image", "image": image}),
						partial, complete,
					}, "older": nil, "newer": nil, "high_water": 3})
					return
				}
				if r.URL.Path == "/sessions/s/history/u" {
					imageReads++
					_ = json.NewEncoder(w).Encode(map[string]any{"entry_id": "u", "parts": []any{map[string]any{"field": "image-0", "offset_bytes": 0, "encoding": "base64", "text": "AAEC", "complete": true}}, "next": nil, "image": image})
					return
				}
				if r.URL.Path != "/sessions/s/history/e" {
					t.Errorf("wrong content URL %s", r.URL)
				}
				offset := 0
				text := "雪"
				complete := false
				var next any = "next-a"
				if r.URL.Query().Get("next") != "" {
					offset = 3
					text = "月"
					complete = true
					next = nil
					if failure == "offset" {
						offset = 1
					}
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"entry_id": "e", "parts": []any{map[string]any{"field": "text", "offset_bytes": offset, "encoding": "utf8", "text": text, "complete": complete}}, "next": next, "image": nil})
			})
			page, err := NewChatClient(conn, "s").History(t.Context(), 0, 10)
			if failure != "" {
				if err == nil {
					t.Fatalf("invalid %s accepted", failure)
				}
				return
			}
			if err != nil || len(page.Events) != 6 || page.Events[0].Type != EventUser || page.Events[0].Text != "inspect this image" || page.Events[0].Image == nil || page.Events[0].Image.Bytes != 3 || page.Events[2].Type != EventMessage || page.Events[2].Text != "雪月" || page.Events[4].Type != EventMessage || page.Events[4].Text != strings.Repeat("complete reply ", 128) {
				t.Fatalf("history lost full text or image metadata: %+v, %v", page, err)
			}
			if imageReads != 0 {
				t.Fatal("displaying image metadata fetched raw image bytes")
			}
			fields, err := ReadEntryContent(t.Context(), conn, "s", "u")
			if err != nil || string(fields["image-0"]) != string([]byte{0, 1, 2}) || imageReads != 1 {
				t.Fatalf("explicit full image retrieval changed: %v, %v", fields, err)
			}
		})
	}
}

// A malformed acknowledgement must retain the original login intent even when
// the form is cleared or edited while its retained decision is being queried.
