package daemon

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"unicode/utf8"

	"albedo/cli/internal/daemon/protocol"
)

type HistoryPage struct {
	Events []StreamEvent
	Before int64
	More   bool
}

func (c *ChatClient) History(ctx context.Context, before int64, rows int) (*HistoryPage, error) {
	params := protocol.GetHistoryParams{Limit: new(int64(min(200, max(1, rows))))}
	if before > 0 {
		params.Before = &before
	}
	var wire protocol.HistoryPage
	err := executeRead(ctx, c.conn, operation{Name: "read history", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetHistoryRequest(base, c.agentID, &params)
	}, Policy: readRecovery}, func(data []byte) error {
		if err := decodeRequired(data, &wire, "items", "older", "newer", "high_water"); err != nil {
			return err
		}
		if wire.Items == nil || len(wire.Items) > 200 || wire.HighWater < 0 {
			return fieldError("history")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	page := &HistoryPage{More: wire.Older != nil}
	if len(wire.Items) > 0 {
		page.Before = wire.Items[0].Position
	}
	wire.Items, err = hydrateHistory(ctx, c.conn, c.agentID, wire.Items)
	if err != nil {
		return nil, err
	}
	page.Events, err = historyEvents(wire.Items)
	return page, err
}

func historyEvents(entries []protocol.HistoryEntry) ([]StreamEvent, error) {
	events := []StreamEvent{}
	arguments := map[string][]json.RawMessage{}
	for _, entry := range entries {
		if entry.Kind == "tool_call" && entry.Tool != nil {
			arguments[entry.Tool.ToolCallID] = entry.Content
			continue
		}
		if entry.Kind == "tool_result" && entry.Tool != nil {
			entry.Content = append(arguments[entry.Tool.ToolCallID], entry.Content...)
		}
		converted, err := historyEntryEvents(entry)
		if err != nil {
			return nil, err
		}
		for i := range converted {
			converted[i].Replayed = true
		}
		events = append(events, converted...)
	}
	return events, nil
}
func historyEntryEvents(entry protocol.HistoryEntry) ([]StreamEvent, error) {
	if entry.Kind == "continuation" {
		return nil, nil
	}
	if entry.ID == "" || entry.Position < 1 || entry.Content == nil {
		return nil, fieldError("history entry")
	}
	event := StreamEvent{EntryID: entry.ID, Position: entry.Position, TurnType: value(entry.TurnType), Timestamp: timestampMilliseconds(value(entry.CreatedAt)), TurnID: value(entry.TurnID), OperationID: value(entry.InputID), Replayed: true}
	var text strings.Builder
	for _, raw := range entry.Content {
		var part struct {
			Kind      string                    `json:"kind"`
			Text      string                    `json:"text"`
			Field     string                    `json:"field"`
			Value     json.RawMessage           `json:"value"`
			Image     *protocol.ImageMetadata   `json:"image"`
			Trace     json.RawMessage           `json:"trace"`
			Reference protocol.ContentReference `json:"reference"`
		}
		if err := json.Unmarshal(raw, &part); err != nil {
			return nil, err
		}
		switch part.Kind {
		case "text":
			text.WriteString(part.Text)
		case "json":
			switch part.Field {
			case "arguments":
				arguments, _ := dynamicValue(part.Value)
				event.ToolArgs, _ = arguments.(map[string]any)
			case "result":
				var str string
				if json.Unmarshal(part.Value, &str) == nil {
					event.ToolResult = str
				} else {
					event.ToolResult = string(part.Value)
				}
			case "elapsed_ms":
				_ = json.Unmarshal(part.Value, &event.ElapsedMs)
			case "origin":
				if err := json.Unmarshal(part.Value, &event.Source); err != nil {
					return nil, fieldError("history origin")
				}
			case "strategy":
				_ = json.Unmarshal(part.Value, &event.Strategy)
			case "evicted_entries":
				_ = json.Unmarshal(part.Value, &event.Evicted)
			}
		case "image":
			if part.Image != nil {
				event.Image = &ImageMetadata{MimeType: ImageMimeType(part.Image.MimeType), Width: int(part.Image.Width), Height: int(part.Image.Height), Bytes: int(part.Image.OriginalBytes)}
			}
		case "trace":
			event.ToolTrace = ParseToolTrace(part.Trace)
		case "reference":
			if !strings.HasPrefix(part.Reference.Field, "image-") {
				return nil, fieldError("unresolved history content")
			}
		default:
			return nil, fieldError("history content kind")
		}
	}
	event.Text = text.String()
	if entry.Mail != nil {
		event.Speaker = entry.Mail.SenderLabel
		event.MailKind = entry.Mail.Kind
		event.SenderSessionID = value(entry.Mail.SenderSessionID)
	}
	switch entry.Kind {
	case "user":
		event.Type = EventUser
		switch event.TurnType {
		case "agent":
			event.Source = "mail"
		case "webhook":
			event.Source = "webhook"
		case "scheduled":
			event.Source = "job"
		case "continue":
			event.Source = "continue"
		default:
			event.Source = "chat"
		}
	case "assistant":
		event.Type = EventMessage
	case "thinking":
		event.Type = EventThinking
		if entry.ThinkingDurationMs != nil {
			event.ElapsedMs = *entry.ThinkingDurationMs
			event.ElapsedObserved = true
		}
	case "tool_call":
		return nil, nil
	case "tool_result":
		event.Type = EventTool
		if entry.Tool == nil {
			return nil, fieldError("history tool")
		}
		event.ToolName = entry.Tool.Name
		event.ProgressCallID = value(entry.Tool.ProgressCallID)
		if event.ToolResult == "" {
			event.ToolResult = event.Text
		}
		event.Text = ""
	case "note", "image_fit":
		event.Type = EventNote
	case "continuation":
		return nil, nil
	case "compaction":
		event.Type = EventCompacted
		event.Summary = event.Text
	default:
		return nil, fieldError("history entry kind")
	}
	return []StreamEvent{event, {Type: EventCommitted, Seq: entry.Position, Replayed: true}}, nil
}

// ReadEntryContent reconstructs complete stored fields with verified byte offsets.
func ReadEntryContent(ctx context.Context, conn *Connection, session, entry string) (map[string][]byte, error) {
	fields := map[string][]byte{}
	complete := map[string]bool{}
	seen := map[string]bool{}
	params := protocol.GetHistoryContentParams{}
	total := 0
	for {
		var page protocol.EntryContentPage
		err := executeRead(ctx, conn, operation{Name: "read history content", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
			return protocol.NewGetHistoryContentRequest(base, session, entry, &params)
		}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &page, "entry_id", "parts", "next", "image") })
		if err != nil {
			return nil, err
		}
		if page.EntryID != entry || page.Parts == nil {
			return nil, fieldError("history content identity")
		}
		for _, part := range page.Parts {
			if part.Field == "" || complete[part.Field] || part.OffsetBytes != int64(len(fields[part.Field])) {
				return nil, fieldError("content byte offset")
			}
			data := []byte(part.Text)
			if part.Encoding == "base64" {
				var err error
				data, err = base64.StdEncoding.DecodeString(part.Text)
				if err != nil {
					return nil, err
				}
			} else if part.Encoding != "utf8" {
				return nil, fieldError("content encoding")
			}
			if part.Encoding == "utf8" && !utf8.Valid(data) {
				return nil, fieldError("content UTF-8")
			}
			total += len(data)
			if total > 50*1024*1024 {
				return nil, errors.New("entry content exceeds the client display limit")
			}
			fields[part.Field] = append(fields[part.Field], data...)
			complete[part.Field] = part.Complete
		}
		if page.Next == nil {
			for name := range fields {
				if !complete[name] {
					return nil, fieldError("incomplete content field")
				}
			}
			return fields, nil
		}
		if seen[*page.Next] {
			return nil, fieldError("repeated content page")
		}
		seen[*page.Next] = true
		params.Next = page.Next
	}
}

func hydrateHistory(ctx context.Context, conn *Connection, session string, entries []protocol.HistoryEntry) ([]protocol.HistoryEntry, error) {
	result := entries
	cloned := false
	for i, entry := range entries {
		if entry.ContentComplete {
			continue
		}
		needsContent := false
		for _, raw := range entry.Content {
			var part struct {
				Kind      string                    `json:"kind"`
				Reference protocol.ContentReference `json:"reference"`
			}
			if err := json.Unmarshal(raw, &part); err != nil {
				return nil, err
			}
			if part.Kind == "reference" && !strings.HasPrefix(part.Reference.Field, "image-") {
				needsContent = true
			}
		}
		if !needsContent {
			continue
		}
		fields, err := ReadEntryContent(ctx, conn, session, entry.ID)
		if err != nil {
			return nil, err
		}
		if !cloned {
			result = slices.Clone(entries)
			cloned = true
		}
		result[i].Content = nil
		for _, raw := range entry.Content {
			var part struct {
				Kind      string                    `json:"kind"`
				Reference protocol.ContentReference `json:"reference"`
			}
			_ = json.Unmarshal(raw, &part)
			if part.Kind != "reference" {
				result[i].Content = append(result[i].Content, raw)
				continue
			}
			field := part.Reference.Field
			if strings.HasPrefix(field, "image-") {
				result[i].Content = append(result[i].Content, raw)
				continue
			}
			content, ok := fields[field]
			if !ok || int64(len(content)) != part.Reference.Bytes {
				return nil, fieldError("referenced content size")
			}
			var expanded any
			switch field {
			case "text":
				expanded = map[string]any{"kind": "text", "text": string(content)}
			case "arguments", "result":
				if !json.Valid(content) {
					return nil, fieldError("referenced JSON")
				}
				expanded = map[string]any{"kind": "json", "field": field, "value": json.RawMessage(content)}
			case "trace":
				expanded = map[string]any{"kind": "trace", "trace": json.RawMessage(content)}
			default:
				if !json.Valid(content) {
					return nil, fieldError("referenced JSON")
				}
				expanded = map[string]any{"kind": "json", "field": field, "value": json.RawMessage(content)}
			}
			encoded, err := json.Marshal(expanded)
			if err != nil {
				return nil, err
			}
			result[i].Content = append(result[i].Content, encoded)
		}
	}
	return result, nil
}

// Live summaries use the same durable content resource as history pages.
func hydrateSessionEvent(ctx context.Context, conn *Connection, session string, raw json.RawMessage) (json.RawMessage, error) {
	var envelope sessionEventEnvelope
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, err
	}
	switch envelope.Type {
	case "message":
		var data struct {
			Entry protocol.HistoryEntry `json:"entry"`
		}
		if err := decodeRequired(envelope.Data, &data, "entry"); err != nil {
			return nil, err
		}
		entries, err := hydrateHistory(ctx, conn, session, []protocol.HistoryEntry{data.Entry})
		if err != nil {
			return nil, err
		}
		data.Entry = entries[0]
		envelope.Data, err = json.Marshal(data)
		if err != nil {
			return nil, err
		}
	case "tool":
		var data map[string]json.RawMessage
		if err := json.Unmarshal(envelope.Data, &data); err != nil {
			return nil, err
		}
		var reference *protocol.ContentReference
		if err := json.Unmarshal(data["reference"], &reference); err != nil {
			return nil, err
		}
		if reference == nil {
			return raw, nil
		}
		parsed, err := url.Parse(reference.URL)
		if err != nil {
			return nil, err
		}
		prefix := "/sessions/" + url.PathEscape(session) + "/history/"
		if parsed.IsAbs() || parsed.RawQuery != "" || !strings.HasPrefix(parsed.Path, prefix) {
			return nil, fieldError("tool content reference")
		}
		entry := strings.TrimPrefix(parsed.Path, prefix)
		if entry == "" || strings.Contains(entry, "/") {
			return nil, fieldError("tool content reference")
		}
		fields, err := ReadEntryContent(ctx, conn, session, entry)
		if err != nil {
			return nil, err
		}
		content, ok := fields[reference.Field]
		if !ok || int64(len(content)) != reference.Bytes {
			return nil, fieldError("tool content size")
		}
		if reference.Field != "arguments" && reference.Field != "result" && reference.Field != "trace" {
			return nil, fieldError("tool content field")
		}
		if !json.Valid(content) {
			return nil, fieldError("tool content JSON")
		}
		for _, field := range []string{"arguments", "result", "trace"} {
			if full, present := fields[field]; present {
				if !json.Valid(full) {
					return nil, fieldError("tool content JSON")
				}
				data[field] = json.RawMessage(full)
			}
		}
		data["reference"] = json.RawMessage("null")
		data["content_complete"] = json.RawMessage("true")
		envelope.Data, err = json.Marshal(data)
		if err != nil {
			return nil, err
		}
	default:
		return raw, nil
	}
	return json.Marshal(envelope)
}
