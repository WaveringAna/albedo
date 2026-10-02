package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"slices"
	"time"
)

type ContextSection struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Kind      string `json:"kind"` // "instructions" | "extension_context" | "history" | "tools" | "other"
	Source    string `json:"source"`
	Preview   string `json:"preview"`
	ItemCount int    `json:"item_count"`
	ByteCount int    `json:"byte_count"`
	Pages     int    `json:"pages"`
}

type CompactionState struct {
	TriggerFreePercent        *float64 `json:"trigger_free_percent,omitempty"`
	InputLimitTokens          *int     `json:"input_limit_tokens,omitempty"`
	EstimatedInputTokens      *int     `json:"estimated_input_tokens,omitempty"`
	ProviderInputTokens       *int     `json:"provider_input_tokens,omitempty"`
	ProviderCachedInputTokens *int     `json:"provider_cached_input_tokens,omitempty"`
	BeforeItems               *int     `json:"before_items,omitempty"`
	AfterItems                *int     `json:"after_items,omitempty"`
	Strategy                  string   `json:"strategy,omitempty"`
	Status                    string   `json:"status"` // "not_configured" | "not_needed" | "compacted" | "unknown"
	Source                    string   `json:"source,omitempty"`
	EstimateMethod            string   `json:"estimate_method,omitempty"`
}

type ContextSnapshot struct {
	Compaction          CompactionState  `json:"compaction"`
	CapturedAt          *int64           `json:"captured_at,omitempty"`
	ContextWindowTokens *int             `json:"context_window_tokens,omitempty"`
	State               string           `json:"state"` // "pending" | "ready"
	Reason              string           `json:"reason,omitempty"`
	Provider            string           `json:"provider,omitempty"`
	Model               string           `json:"model,omitempty"`
	Protocol            string           `json:"protocol,omitempty"`
	Sections            []ContextSection `json:"sections,omitempty"`
}

type ContextPage struct {
	Section string `json:"section"`
	Content string `json:"content"`
	Omitted string `json:"omitted,omitempty"`
	Page    int    `json:"page"`
	Pages   int    `json:"pages"`
}

func utf16Length(s string) int {
	length := 0
	for _, char := range s {
		length++
		if char > 0xffff {
			length++
		}
	}
	return length
}

func isNeg(p *int) bool { return p != nil && *p < 0 }

var (
	validKinds         = []string{"instructions", "extension_context", "history", "tools", "other"}
	compactionStatuses = []string{"not_configured", "not_needed", "compacted", "unknown"}
)

func validContextSnapshot(s ContextSnapshot) error {
	if s.State == "pending" {
		if utf16Length(s.Reason) <= 500 {
			return nil
		}
		return errors.New("daemon returned invalid context metadata")
	}
	if s.State != "ready" || utf16Length(s.Model) > 512 || s.Sections == nil || len(s.Sections) > 1000 ||
		utf16Length(s.Provider) > 512 || utf16Length(s.Protocol) > 512 || (s.CapturedAt != nil && *s.CapturedAt < 0) ||
		isNeg(s.ContextWindowTokens) {
		return errors.New("daemon returned invalid context metadata")
	}
	for _, sec := range s.Sections {
		if sec.ID == "" || utf16Length(sec.ID) > 200 || sec.Label == "" || utf16Length(sec.Label) > 200 || !slices.Contains(validKinds, sec.Kind) ||
			utf16Length(sec.Source) > 500 || sec.ItemCount < 0 || sec.ByteCount < 0 || utf16Length(sec.Preview) > 2000 || sec.Pages < 0 || sec.Pages > 10000 {
			return errors.New("daemon returned invalid context section metadata")
		}
	}
	c := s.Compaction
	badPct := c.TriggerFreePercent != nil && (math.IsNaN(*c.TriggerFreePercent) || math.IsInf(*c.TriggerFreePercent, 0) || *c.TriggerFreePercent < 0 || *c.TriggerFreePercent > 100)
	if !slices.Contains(compactionStatuses, c.Status) || utf16Length(c.Strategy) > 200 || utf16Length(c.Source) > 500 || utf16Length(c.EstimateMethod) > 500 ||
		badPct || isNeg(c.InputLimitTokens) || isNeg(c.EstimatedInputTokens) ||
		isNeg(c.ProviderInputTokens) || isNeg(c.ProviderCachedInputTokens) ||
		isNeg(c.BeforeItems) || isNeg(c.AfterItems) {
		return errors.New("daemon returned invalid compaction metadata")
	}
	return nil
}

func validContextPage(p ContextPage, sectionID string) error {
	if p.Section != sectionID || p.Page < 0 || p.Pages < 0 || p.Pages > 10000 || p.Page >= max(1, p.Pages) || utf16Length(p.Content) > 65536 || utf16Length(p.Omitted) > 1000 {
		return errors.New("daemon returned invalid context page")
	}
	return nil
}

type contextSectionWire struct {
	ID        *string `json:"id"`
	Label     *string `json:"label"`
	Kind      *string `json:"kind"`
	Source    *string `json:"source"`
	Preview   *string `json:"preview"`
	ItemCount *int    `json:"item_count"`
	ByteCount *int    `json:"byte_count"`
	Pages     *int    `json:"pages"`
}

func (wire contextSectionWire) value() ContextSection {
	var section ContextSection
	if wire.ID != nil {
		section.ID = *wire.ID
	}
	if wire.Label != nil {
		section.Label = *wire.Label
	}
	if wire.Kind != nil {
		section.Kind = *wire.Kind
	}
	if wire.Source != nil {
		section.Source = *wire.Source
	}
	if wire.Preview != nil {
		section.Preview = *wire.Preview
	}
	if wire.ItemCount != nil {
		section.ItemCount = *wire.ItemCount
	}
	if wire.ByteCount != nil {
		section.ByteCount = *wire.ByteCount
	}
	if wire.Pages != nil {
		section.Pages = *wire.Pages
	}
	return section
}

type compactionWire struct {
	CompactionState
	Status *string `json:"status"`
}

func GetContextSnapshot(ctx context.Context, conn *Connection, session string) (ContextSnapshot, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var result ContextSnapshot
	if err := checkCapability(ctx, conn, "session_context", "for /context"); err != nil {
		return result, err
	}
	err := executeRead(ctx, conn, operation{Name: "get context snapshot", Method: http.MethodGet, Path: sessionPath(session, "/context"), Policy: readRecovery}, func(data []byte) error {
		// The pending and ready variants require different scalar fields.
		var payload struct {
			State               *string              `json:"state"`
			Reason              *string              `json:"reason"`
			Model               *string              `json:"model"`
			Provider            string               `json:"provider"`
			Protocol            string               `json:"protocol"`
			CapturedAt          *int64               `json:"captured_at"`
			ContextWindowTokens *int                 `json:"context_window_tokens"`
			Sections            []contextSectionWire `json:"sections"`
			Compaction          *compactionWire      `json:"compaction"`
		}
		if err := json.Unmarshal(data, &payload); err != nil {
			return err
		}
		if payload.State == nil {
			return fieldError("state")
		}
		result = ContextSnapshot{
			State:               *payload.State,
			Provider:            payload.Provider,
			Protocol:            payload.Protocol,
			CapturedAt:          payload.CapturedAt,
			ContextWindowTokens: payload.ContextWindowTokens,
		}
		if payload.Reason != nil {
			result.Reason = *payload.Reason
		}
		if payload.Model != nil {
			result.Model = *payload.Model
		}
		if result.State == "pending" && payload.Reason == nil {
			return fieldError("reason")
		}
		if result.State == "ready" {
			if payload.Model == nil {
				return fieldError("model")
			}
			if payload.Sections == nil {
				return fieldError("sections")
			}
			if payload.Compaction == nil || payload.Compaction.Status == nil {
				return fieldError("compaction.status")
			}
		}
		if payload.Sections != nil {
			result.Sections = make([]ContextSection, len(payload.Sections))
			for i, section := range payload.Sections {
				if result.State == "ready" && (section.ID == nil || section.Label == nil || section.Kind == nil || section.Source == nil || section.Preview == nil || section.ItemCount == nil || section.ByteCount == nil || section.Pages == nil) {
					return fieldError("sections")
				}
				result.Sections[i] = section.value()
			}
		}
		if payload.Compaction != nil {
			result.Compaction = payload.Compaction.CompactionState
			if payload.Compaction.Status != nil {
				result.Compaction.Status = *payload.Compaction.Status
			}
		}
		return validContextSnapshot(result)
	})
	return result, err
}
func GetContextPage(ctx context.Context, conn *Connection, session, section string, page int) (ContextPage, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var result ContextPage
	if err := checkCapability(ctx, conn, "session_context", "for /context"); err != nil {
		return result, err
	}
	err := executeRead(ctx, conn, operation{Name: "get context page", Method: http.MethodGet, Path: sessionPath(session, fmt.Sprintf("/context/%s/%d", url.PathEscape(section), page)), Policy: readRecovery}, func(data []byte) error {
		var wire struct {
			Section *string `json:"section"`
			Content *string `json:"content"`
			Omitted string  `json:"omitted"`
			Page    *int    `json:"page"`
			Pages   *int    `json:"pages"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return err
		}
		if wire.Section == nil || wire.Content == nil || wire.Page == nil || wire.Pages == nil {
			return errors.New("daemon returned incomplete context page")
		}
		result = ContextPage{Section: *wire.Section, Content: *wire.Content, Omitted: wire.Omitted, Page: *wire.Page, Pages: *wire.Pages}
		if result.Page != page {
			return fieldError("page")
		}
		return validContextPage(result, section)
	})
	return result, err
}

func (c *ChatClient) ContextWindow(ctx context.Context) (*int, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	operation := operation{Name: "read context", Method: http.MethodGet, Path: sessionPath(c.agentID, "/context"), Body: nil, Policy: readRecovery}
	body, err := requestBytes(reqCtx, c.conn, operation, responseLimits{successStatus: http.StatusOK, bodyBytes: 1024 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return nil, err
	}

	var data struct {
		Window *int `json:"context_window_tokens"`
	}
	if err := json.Unmarshal(body, &data); err != nil {
		return nil, err
	}
	if data.Window != nil && *data.Window <= 0 {
		return nil, nil
	}
	return data.Window, nil
}
