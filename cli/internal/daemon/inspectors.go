package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

type CachePolicyPage = wireCachePolicyPage
type CachePolicyQuery struct {
	Extension, Host, Model, Next string
	Limit                        int
}
type RequestRecordPage = wireRequestRecordPage
type QuotaPage = wireQuotaPage

func GetCachePolicy(ctx context.Context, conn *Connection, query CachePolicyQuery) (CachePolicyPage, error) {
	q := url.Values{"view": {"cache-policy"}, "limit": {fmt.Sprint(min(200, max(1, query.Limit)))}}
	for key, text := range map[string]string{"extension": query.Extension, "host": query.Host, "model": query.Model, "next": query.Next} {
		if text != "" {
			q.Set(key, text)
		}
	}
	var result wireCachePolicyPage
	err := executeRead(ctx, conn, operation{Name: "inspect cache policy", Method: http.MethodGet, Path: "/models?" + q.Encode(), Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &result, "entries", "layers", "matched", "next") })
	return result, err
}
func GetRequestRecords(ctx context.Context, conn *Connection, session, next string, limit int) (RequestRecordPage, error) {
	q := url.Values{"view": {"requests"}, "limit": {fmt.Sprint(min(200, max(1, limit)))}}
	if next != "" {
		q.Set("next", next)
	}
	var result wireRequestRecordPage
	err := executeRead(ctx, conn, operation{Capability: "context", Name: "inspect provider requests", Method: http.MethodGet, Path: sessionPath(session, "/context?"+q.Encode()), Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &result, "items", "next") })
	return result, err
}
func GetQuotaHistory(ctx context.Context, conn *Connection, next string, limit int) (QuotaPage, error) {
	q := url.Values{"include": {"quota_history"}, "limit": {fmt.Sprint(min(200, max(1, limit)))}}
	if next != "" {
		q.Set("next", next)
	}
	var result wireServer
	err := executeRead(ctx, conn, operation{Name: "inspect quota history", Method: http.MethodGet, Path: "/server?" + q.Encode(), Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &result, "quota_history") })
	return result.QuotaHistory, err
}

// Platform inspectors are rendered locally from typed facts. Their domain APIs
// remain usable by clients that do not display terminal pages.
func loadPlatformInspector(ctx context.Context, conn *Connection, snapshot Session, command string) (*PageDocument, error) {
	doc := &PageDocument{Title: strings.TrimPrefix(command, "/"), Rows: []PageRow{}, Actions: []PageAction{}, Session: &snapshot}
	next := ""
	seen := map[string]bool{}
	appendRow := func(id, text, badge string, details any) {
		encoded, _ := json.MarshalIndent(details, "", "  ")
		doc.Rows = append(doc.Rows, PageRow{ID: id, Text: text, Badge: badge, Detail: string(encoded), Tone: TonePlain})
	}
	for {
		switch command {
		case "/ttl":
			page, err := GetCachePolicy(ctx, conn, CachePolicyQuery{Limit: 200, Next: next})
			if err != nil {
				return nil, err
			}
			if next == "" {
				for _, layer := range page.Layers {
					state := "loaded"
					if !layer.Loaded {
						state = "not loaded"
					}
					if layer.Error != nil {
						state = layer.Error.Detail
					}
					doc.Summary += fmt.Sprintf("%s: %s · %s\n", layer.Name, state, layer.Path)
				}
			}
			for _, entry := range page.Entries {
				appendRow(entry.ID, entry.ID, entry.Policy, entry)
			}
			next = value(page.Next)
		case "/requests":
			page, err := GetRequestRecords(ctx, conn, snapshot.ID, next, 200)
			if err != nil {
				return nil, err
			}
			for _, entry := range page.Items {
				appendRow(fmt.Sprint(entry.Sequence), entry.ProviderProfile+" · "+entry.Model, entry.Outcome, entry)
			}
			next = value(page.Next)
		case "/quota":
			page, err := GetQuotaHistory(ctx, conn, next, 200)
			if err != nil {
				return nil, err
			}
			for _, entry := range page.Items {
				badge := entry.Status
				if entry.UsedPercent != nil {
					badge = fmt.Sprintf("%.1f%% used", *entry.UsedPercent)
				}
				appendRow(fmt.Sprint(entry.Sequence), entry.Provider+" · "+entry.Label, badge, entry)
			}
			next = value(page.Next)
		default:
			return nil, fmt.Errorf("unknown platform inspector %s", command)
		}
		if next == "" {
			break
		}
		if seen[next] {
			return nil, fieldError("inspector page cursor")
		}
		seen[next] = true
	}
	doc.Summary = strings.TrimSpace(doc.Summary)
	doc.Empty = "No observations yet."
	return doc, nil
}
