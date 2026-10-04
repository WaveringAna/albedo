package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"strings"
	"unicode/utf8"

	"albedo/cli/internal/daemon/protocol"
)

func validateActiveOutput(session string, outputs []protocol.ActiveOutput) error {
	if outputs == nil || len(outputs) > 256 {
		return fieldError("active output")
	}
	seen := map[string]bool{}
	var total int64
	inlineBytes := 0
	for _, output := range outputs {
		if output.MessageID == "" || output.RunID == "" || seen[output.MessageID] || output.Bytes < 0 || (output.Kind != "text" && output.Kind != "thinking") || (output.Text == nil) == (output.Reference == nil) || output.ElapsedMs != nil && *output.ElapsedMs < 0 {
			return fieldError("active output descriptor")
		}
		seen[output.MessageID] = true
		total += output.Bytes
		if output.Bytes > 64*1024*1024 || total > 64*1024*1024 {
			return fieldError("active output size")
		}
		if output.Text != nil {
			encoded, _ := json.Marshal(*output.Text)
			inlineBytes += len(encoded)
			if inlineBytes > 64*1024 {
				return fieldError("active output inline size")
			}
			if !utf8.ValidString(*output.Text) || int64(len(*output.Text)) != output.Bytes {
				return fieldError("active output text")
			}
			continue
		}
		reference := output.Reference
		parsed, err := url.Parse(reference.URL)
		prefix := "/sessions/" + url.PathEscape(session) + "/active-output/"
		if err != nil || parsed.IsAbs() || parsed.Host != "" || parsed.Fragment != "" || !strings.HasPrefix(parsed.Path, prefix) || strings.Contains(strings.TrimPrefix(parsed.Path, prefix), "/") || strings.TrimPrefix(parsed.Path, prefix) == "" || parsed.Query().Get("snapshot") == "" || reference.Field != output.Kind || reference.Bytes != output.Bytes {
			return fieldError("active output reference")
		}
	}
	return nil
}

type stagedActiveOutput struct {
	output protocol.ActiveOutput
	offset int64
}
type activeOutputStage struct {
	file    *os.File
	outputs []stagedActiveOutput
}

func (stage *activeOutputStage) close() {
	if stage != nil && stage.file != nil {
		name := stage.file.Name()
		_ = stage.file.Close()
		_ = os.Remove(name)
	}
}

// Validate and stage complete prefixes before replacing any visible state. Large
// prefixes stay on disk rather than accumulating in the pending event batch.
func stageActiveOutput(ctx context.Context, conn *Connection, outputs []protocol.ActiveOutput) (*activeOutputStage, error) {
	stage := &activeOutputStage{}
	if len(outputs) == 0 {
		return stage, nil
	}
	offset := int64(0)
	for _, output := range outputs {
		stage.outputs = append(stage.outputs, stagedActiveOutput{output: output, offset: offset})
		if output.Reference == nil {
			continue
		}
		if stage.file == nil {
			file, err := os.CreateTemp("", "albedo-active-output-*")
			if err != nil {
				return nil, err
			}
			stage.file = file
		}
		if err := stage.readReference(ctx, conn, output); err != nil {
			stage.close()
			return nil, err
		}
		offset += output.Bytes
	}
	return stage, nil
}
func (stage *activeOutputStage) readReference(ctx context.Context, conn *Connection, output protocol.ActiveOutput) error {
	reference := output.Reference
	route, _ := url.Parse(reference.URL)
	contentID := route.Path[strings.LastIndex(route.Path, "/")+1:]
	offset := int64(0)
	complete := false
	return walkPages(func(next *string) (protocol.EntryContentPage, *string, error) {
		query := route.Query()
		if next != nil {
			query.Set("next", *next)
		}
		route.RawQuery = query.Encode()
		var page protocol.EntryContentPage
		err := executeRead(ctx, conn, operation{Name: "read active output", Path: route.String(), Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &page) })
		return page, page.Next, err
	}, func(page protocol.EntryContentPage) error {
		if page.EntryID != contentID || page.Parts == nil || len(page.Parts) == 0 || complete {
			return fieldError("active output content identity")
		}
		for _, part := range page.Parts {
			if part.Field != output.Kind || part.Encoding != "utf8" || part.OffsetBytes != offset || !utf8.ValidString(part.Text) || complete || part.Text == "" && !part.Complete {
				return fieldError("active output content offset")
			}
			offset += int64(len(part.Text))
			if offset > output.Bytes {
				return fieldError("active output content cutoff")
			}
			if _, err := io.WriteString(stage.file, part.Text); err != nil {
				return err
			}
			complete = part.Complete
		}
		if page.Next == nil && (!complete || offset != output.Bytes) || page.Next != nil && complete {
			return fieldError("active output content completeness")
		}
		return nil
	}, "repeated active output page")
}
func (stage *activeOutputStage) deliver(ctx context.Context, onEvent func(StreamEvent) error) error {
	if stage == nil {
		return nil
	}
	for _, item := range stage.outputs {
		var input io.Reader
		if item.output.Text != nil {
			input = strings.NewReader(*item.output.Text)
		} else {
			input = io.NewSectionReader(stage.file, item.offset, item.output.Bytes)
		}
		reader := bufio.NewReader(input)
		var chunk strings.Builder
		emit := func(final bool) error {
			event := StreamEvent{Type: EventType(item.output.Kind), Text: chunk.String(), MessageID: item.output.MessageID, TurnID: item.output.RunID}
			if final && item.output.ElapsedMs != nil {
				event.ElapsedMs = *item.output.ElapsedMs
				event.ElapsedObserved = true
			}
			if err := onEvent(event); err != nil {
				return err
			}
			chunk.Reset()
			return nil
		}
		for {
			if err := ctx.Err(); err != nil {
				return err
			}
			char, size, err := reader.ReadRune()
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				return err
			}
			if char == utf8.RuneError && size == 1 {
				return fieldError("active output UTF-8")
			}
			if chunk.Len()+size > 64*1024 {
				if err := emit(false); err != nil {
					return err
				}
			}
			chunk.WriteRune(char)
		}
		if err := emit(true); err != nil {
			return err
		}
	}
	return nil
}
