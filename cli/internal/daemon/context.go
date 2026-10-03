package daemon

import (
	"context"
	"net/http"
	"net/url"
	"strconv"
)

type ContextSection struct {
	ID, Label, Kind, Source, Preview string
	ItemCount, ByteCount, Pages      int
}
type CompactionState struct {
	TriggerFreePercent                                                                                              *float64
	InputLimitTokens, EstimatedInputTokens, ProviderInputTokens, ProviderCachedInputTokens, BeforeItems, AfterItems *int
	Strategy, Status, Source, EstimateMethod                                                                        string
}
type ContextSnapshot struct {
	SnapshotID                               string
	Compaction                               CompactionState
	CapturedAt                               *int64
	ContextWindowTokens                      *int
	State, Reason, Provider, Model, Protocol string
	Sections                                 []ContextSection
}
type ContextPage struct {
	SnapshotID, Section, Content, Omitted string
	Page, Pages                           int
}

func GetContextSnapshot(ctx context.Context, conn *Connection, id string) (ContextSnapshot, error) {
	var result ContextSnapshot
	err := executeRead(ctx, conn, operation{Capability: "context", Name: "read prepared context", Method: http.MethodGet, Path: sessionPath(id, "/context?view=summary"), Policy: readRecovery}, func(data []byte) error {
		var w wireContextSummary
		if err := decodeRequired(data, &w, "state", "snapshot_id", "captured_at", "provider", "model", "protocol", "context_window_tokens", "compaction", "sections", "reason"); err != nil {
			return err
		}
		if w.State != "ready" && w.State != "pending" {
			return fieldError("context state")
		}
		if w.State == "ready" && value(w.SnapshotID) == "" {
			return fieldError("context snapshot ID")
		}
		c := w.Compaction
		result = ContextSnapshot{SnapshotID: value(w.SnapshotID), CapturedAt: timestampMilliseconds(value(w.CapturedAt)), ContextWindowTokens: intPointer(w.ContextWindowTokens), State: w.State, Provider: value(w.Provider), Model: value(w.Model), Protocol: value(w.Protocol), Compaction: CompactionState{TriggerFreePercent: c.TriggerFreePercent, InputLimitTokens: intPointer(c.InputLimitTokens), EstimatedInputTokens: intPointer(c.EstimatedInputTokens), ProviderInputTokens: intPointer(c.ProviderInputTokens), ProviderCachedInputTokens: intPointer(c.ProviderCachedInputTokens), BeforeItems: intPointer(c.BeforeItems), AfterItems: intPointer(c.AfterItems), Strategy: value(c.Strategy), Status: c.Status, Source: value(c.Source), EstimateMethod: value(c.EstimateMethod)}}
		if w.Reason != nil {
			result.Reason = w.Reason.Detail
		}
		for _, section := range w.Sections {
			result.Sections = append(result.Sections, ContextSection{ID: section.ID, Label: section.Label, Kind: section.Kind, Source: value(section.Source), Preview: section.Preview.Text, ItemCount: int(section.ItemCount), ByteCount: int(section.UTF8Bytes), Pages: int(section.PageCount)})
		}
		return nil
	})
	return result, err
}
func GetContextPage(ctx context.Context, conn *Connection, id, snapshotID, section string, page int) (ContextPage, error) {
	if snapshotID == "" {
		return ContextPage{}, fieldError("context snapshot ID")
	}
	q := url.Values{"view": {"section"}, "snapshot_id": {snapshotID}, "section_id": {section}, "page": {strconv.Itoa(page)}}
	var result ContextPage
	err := executeRead(ctx, conn, operation{Capability: "context", Name: "read prepared context section", Method: http.MethodGet, Path: sessionPath(id, "/context?"+q.Encode()), Policy: readRecovery}, func(data []byte) error {
		var w wireContextSectionPage
		if err := decodeRequired(data, &w, "snapshot_id", "section_id", "text", "omitted", "page", "page_count"); err != nil {
			return err
		}
		if w.SnapshotID != snapshotID || w.SectionID != section || w.Page != int64(page) || len(w.Text) > 32768 || w.PageCount < 1 || w.Page >= w.PageCount {
			return fieldError("context section")
		}
		result = ContextPage{SnapshotID: w.SnapshotID, Section: w.SectionID, Content: w.Text, Omitted: value(w.Omitted), Page: int(w.Page), Pages: int(w.PageCount)}
		return nil
	})
	return result, err
}
func (c *ChatClient) ContextWindow(ctx context.Context) (*int, error) {
	snapshot, err := GetContextSnapshot(ctx, c.conn, c.agentID)
	return snapshot.ContextWindowTokens, err
}
