package daemon

import (
	"context"
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
	wire, err := readHistory(ctx, c.conn, c.agentID, params)
	if err != nil {
		return nil, err
	}
	page := &HistoryPage{More: wire.Older != nil}
	if len(wire.Items) > 0 {
		page.Before = wire.Items[0].Position
	}
	entries, err := decodeHistoryEntries(wire.Items)
	if err != nil {
		return nil, err
	}
	entries, err = hydrateHistory(ctx, c.conn, c.agentID, entries)
	if err != nil {
		return nil, err
	}
	page.Events, err = historyEvents(entries)
	return page, err
}

func readHistory(ctx context.Context, conn *Connection, session string, params protocol.GetHistoryParams) (protocol.HistoryPage, error) {
	var wire protocol.HistoryPage
	err := executeRead(ctx, conn, operation{Name: "read history", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetHistoryRequest(base, session, &params)
	}, Policy: readRecovery}, func(data []byte) error {
		if err := decodeRequired(data, &wire); err != nil {
			return err
		}
		if wire.Items == nil || len(wire.Items) > 200 || wire.HighWater < 0 {
			return fieldError("history")
		}
		return nil
	})
	return wire, err
}

// historyPart is one decoded content part. Decoding once lets reference
// resolution, rewriting and projection share a single walk of the bytes.
type historyPart struct {
	Kind      string                    `json:"kind"`
	Text      string                    `json:"text"`
	Field     string                    `json:"field"`
	Value     json.RawMessage           `json:"value"`
	Image     *protocol.ImageMetadata   `json:"image"`
	Trace     json.RawMessage           `json:"trace"`
	Reference protocol.ContentReference `json:"reference"`
}

// historyEntry is a history entry whose content parts are decoded, so the raw
// encoding of a large field is never held beside the value it produced.
type historyEntry struct {
	wire  protocol.HistoryEntry
	parts []historyPart
}

func decodeHistoryEntries(entries []protocol.HistoryEntry) ([]historyEntry, error) {
	decoded := make([]historyEntry, len(entries))
	for i, entry := range entries {
		parts, err := decodeHistoryParts(entry.Content)
		if err != nil {
			return nil, err
		}
		entry.Content = nil
		decoded[i] = historyEntry{wire: entry, parts: parts}
	}
	return decoded, nil
}

// decodeHistoryParts keeps a nil content list nil: an entry without content is
// a protocol error, while an empty one carries no parts yet is valid.
func decodeHistoryParts(raw []json.RawMessage) ([]historyPart, error) {
	if raw == nil {
		return nil, nil
	}
	parts := make([]historyPart, len(raw))
	for i, value := range raw {
		if err := json.Unmarshal(value, &parts[i]); err != nil {
			return nil, err
		}
	}
	return parts, nil
}

func historyEvents(entries []historyEntry) ([]StreamEvent, error) {
	events := []StreamEvent{}
	arguments := map[string][]historyPart{}
	for _, entry := range entries {
		if entry.wire.Kind == "tool_call" && entry.wire.Tool != nil {
			arguments[entry.wire.Tool.ToolCallID] = entry.parts
			continue
		}
		if entry.wire.Kind == "tool_result" && entry.wire.Tool != nil {
			entry.parts = slices.Concat(arguments[entry.wire.Tool.ToolCallID], entry.parts)
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

func historyEntryEvents(entry historyEntry) ([]StreamEvent, error) {
	wire := entry.wire
	if wire.Kind == "continuation" {
		return nil, nil
	}
	if wire.ID == "" || wire.Position < 1 || entry.parts == nil {
		return nil, fieldError("history entry")
	}
	event := StreamEvent{EntryID: wire.ID, Position: wire.Position, TurnType: value(wire.TurnType), Timestamp: timestampMilliseconds(value(wire.CreatedAt)), TurnID: value(wire.TurnID), OperationID: value(wire.InputID), Replayed: true}
	var text strings.Builder
	for _, part := range entry.parts {
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
				event.Images = append(event.Images, ImageMetadata{MimeType: ImageMimeType(part.Image.MimeType), Width: int(part.Image.Width), Height: int(part.Image.Height), Bytes: int(part.Image.OriginalBytes)})
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
	if wire.Mail != nil {
		event.Speaker = wire.Mail.SenderLabel
		event.MailKind = wire.Mail.Kind
		event.SenderSessionID = value(wire.Mail.SenderSessionID)
	}
	switch wire.Kind {
	case "user":
		event.Type = EventUser
		switch event.TurnType {
		case "agent":
			event.Source = "mail"
		case "webhook":
			event.Source = "webhook"
		case "event":
			event.Source = "event"
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
		if wire.ThinkingDurationMs != nil {
			event.ElapsedMs = *wire.ThinkingDurationMs
			event.ElapsedObserved = true
		}
	case "tool_call":
		return nil, nil
	case "tool_result":
		event.Type = EventTool
		if wire.Tool == nil {
			return nil, fieldError("history tool")
		}
		event.ToolName = wire.Tool.Name
		event.ProgressCallID = value(wire.Tool.ProgressCallID)
		if event.ToolResult == "" {
			event.ToolResult = event.Text
		}
		event.Text = ""
	case "note", "image_fit":
		event.Type = EventNote
	case "compaction":
		event.Type = EventCompacted
		event.Summary = event.Text
	default:
		return nil, fieldError("history entry kind")
	}
	return []StreamEvent{event, {Type: EventCommitted, Seq: wire.Position, Replayed: true}}, nil
}

// ReadEntryContent reconstructs complete stored fields with verified byte offsets.
func ReadEntryContent(ctx context.Context, conn *Connection, session, entry string) (map[string][]byte, error) {
	fields, err := readEntryContents(ctx, conn, session, []string{entry})
	if err != nil {
		return nil, err
	}
	return fields[entry], nil
}

// The batched content route names at most 200 entries of at most 128
// characters each; a history page never comes close.
const (
	contentBatchEntries = 200
	contentEntryIDBytes = 128
)

// readEntryContents reconstructs the stored text fields of several entries,
// walking the batched content route until every field it serves is complete.
func readEntryContents(ctx context.Context, conn *Connection, session string, entries []string) (map[string]map[string][]byte, error) {
	if len(entries) > contentBatchEntries {
		return nil, fieldError("content entries")
	}
	requested := make(map[string]bool, len(entries))
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry == "" || len(entry) > contentEntryIDBytes {
			return nil, fieldError("content entries")
		}
		if requested[entry] {
			continue
		}
		requested[entry] = true
		names = append(names, entry)
	}
	params := protocol.GetHistoryContentBatchParams{Entries: strings.Join(names, ",")}
	fields := map[string]map[string][]byte{}
	complete := map[string]map[string]bool{}
	total := 0
	err := walkPages(func(next *string) (protocol.EntryContentBatch, *string, error) {
		params.Next = next
		var page protocol.EntryContentBatch
		pageErr := executeRead(ctx, conn, operation{Name: "read history content", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
			return protocol.NewGetHistoryContentBatchRequest(base, session, &params)
		}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &page) })
		return page, page.Next, pageErr
	}, func(page protocol.EntryContentBatch) error {
		if page.Parts == nil {
			return fieldError("content parts")
		}
		for _, part := range page.Parts {
			if part.Field == "" || part.Encoding != "utf8" || !requested[part.EntryID] {
				return fieldError("content part")
			}
			if fields[part.EntryID] == nil {
				fields[part.EntryID] = map[string][]byte{}
				complete[part.EntryID] = map[string]bool{}
			}
			if complete[part.EntryID][part.Field] || part.OffsetBytes != int64(len(fields[part.EntryID][part.Field])) {
				return fieldError("content byte offset")
			}
			data := []byte(part.Text)
			if !utf8.Valid(data) {
				return fieldError("content UTF-8")
			}
			total += len(data)
			if total > 50*1024*1024 {
				return errors.New("entry content exceeds the client display limit")
			}
			fields[part.EntryID][part.Field] = append(fields[part.EntryID][part.Field], data...)
			complete[part.EntryID][part.Field] = part.Complete
		}
		return nil
	}, "repeated content page")
	if err != nil {
		return nil, err
	}
	for entry := range complete {
		for _, done := range complete[entry] {
			if !done {
				return nil, fieldError("incomplete content field")
			}
		}
	}
	return fields, nil
}

// hydrateHistory resolves every content reference of a page in one walk of the
// batch content route and expands it in place of the reference.
func hydrateHistory(ctx context.Context, conn *Connection, session string, entries []historyEntry) ([]historyEntry, error) {
	needed := []string{}
	references := map[string][]string{}
	for _, entry := range entries {
		names := []string{}
		for _, part := range entry.parts {
			if part.Kind == "reference" && !strings.HasPrefix(part.Reference.Field, "image-") {
				names = append(names, part.Reference.Field)
			}
		}
		if len(names) == 0 {
			continue
		}
		needed = append(needed, entry.wire.ID)
		references[entry.wire.ID] = names
	}
	if len(needed) == 0 {
		return entries, nil
	}
	content, err := readEntryContents(ctx, conn, session, needed)
	if err != nil {
		return nil, err
	}
	result := slices.Clone(entries)
	for i, entry := range result {
		names, referenced := references[entry.wire.ID]
		if !referenced {
			continue
		}
		fields := content[entry.wire.ID]
		for _, name := range names {
			if _, served := fields[name]; !served {
				return nil, fieldError("referenced content size")
			}
		}
		parts := slices.Clone(entry.parts)
		for j, part := range parts {
			if part.Kind != "reference" || strings.HasPrefix(part.Reference.Field, "image-") {
				continue
			}
			expanded, err := expandReference(part, fields)
			if err != nil {
				return nil, err
			}
			parts[j] = expanded
		}
		result[i].parts = parts
	}
	return result, nil
}

// expandReference turns a content reference into the part it stands for, with
// the stored bytes as the value rather than another JSON encoding of them.
func expandReference(part historyPart, fields map[string][]byte) (historyPart, error) {
	content, ok := fields[part.Reference.Field]
	if !ok || int64(len(content)) != part.Reference.Bytes {
		return historyPart{}, fieldError("referenced content size")
	}
	switch part.Reference.Field {
	case "text":
		return historyPart{Kind: "text", Text: string(content)}, nil
	case "trace":
		if !json.Valid(content) {
			return historyPart{}, fieldError("referenced JSON")
		}
		return historyPart{Kind: "trace", Trace: content}, nil
	default:
		if !json.Valid(content) {
			return historyPart{}, fieldError("referenced JSON")
		}
		return historyPart{Kind: "json", Field: part.Reference.Field, Value: content}, nil
	}
}

// Live summaries read the same durable content resources as history pages.
type eventContentReader struct {
	ctx     context.Context
	conn    *Connection
	session string
}

func (reader *eventContentReader) hydrateTool(data *toolEventData) error {
	reference := data.Reference
	if reference == nil {
		return nil
	}
	parsed, err := url.Parse(reference.URL)
	if err != nil {
		return err
	}
	prefix := "/sessions/" + url.PathEscape(reader.session) + "/history/"
	if parsed.IsAbs() || parsed.RawQuery != "" || !strings.HasPrefix(parsed.Path, prefix) {
		return fieldError("tool content reference")
	}
	entry := strings.TrimPrefix(parsed.Path, prefix)
	if entry == "" || strings.Contains(entry, "/") {
		return fieldError("tool content reference")
	}
	fields, err := ReadEntryContent(reader.ctx, reader.conn, reader.session, entry)
	if err != nil {
		return err
	}
	content, ok := fields[reference.Field]
	if !ok || int64(len(content)) != reference.Bytes {
		return fieldError("tool content size")
	}
	if reference.Field != "arguments" && reference.Field != "result" && reference.Field != "trace" {
		return fieldError("tool content field")
	}
	if !json.Valid(content) {
		return fieldError("tool content JSON")
	}
	for _, field := range []string{"arguments", "result", "trace"} {
		if full, present := fields[field]; present {
			if !json.Valid(full) {
				return fieldError("tool content JSON")
			}
			switch field {
			case "arguments":
				data.Arguments = json.RawMessage(full)
			case "result":
				data.Result = json.RawMessage(full)
			case "trace":
				data.Trace = json.RawMessage(full)
			}
		}
	}
	data.Reference = nil
	data.ContentComplete = true
	return nil
}
