package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"albedo/cli/internal/daemon/protocol"
)

type CachePolicyPage = protocol.CachePolicyPage
type CachePolicyQuery struct {
	Extension, Host, Model, Next string
	Limit                        int
}
type RequestRecordPage = protocol.RequestRecordPage
type QuotaPage = protocol.QuotaPage
type QuotaObservation = protocol.QuotaObservation

func GetCachePolicy(ctx context.Context, conn *Connection, query CachePolicyQuery) (CachePolicyPage, error) {
	params := protocol.ListModelsParams{View: new("cache-policy"), Limit: new(int64(min(200, max(1, query.Limit))))}
	if query.Extension != "" {
		params.Extension = &query.Extension
	}
	if query.Host != "" {
		params.Host = &query.Host
	}
	if query.Model != "" {
		params.Model = &query.Model
	}
	if query.Next != "" {
		params.Next = &query.Next
	}
	var result protocol.CachePolicyPage
	err := executeRead(ctx, conn, operation{Name: "inspect cache policy", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewListModelsRequest(base, &params)
	}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &result) })
	return result, err
}
func GetRequestRecords(ctx context.Context, conn *Connection, session, next string, limit int) (RequestRecordPage, error) {
	params := protocol.GetContextParams{View: new("requests"), Limit: new(int64(min(200, max(1, limit))))}
	if next != "" {
		params.Next = &next
	}
	var result protocol.RequestRecordPage
	err := executeRead(ctx, conn, operation{Capability: "context", Name: "inspect provider requests", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetContextRequest(base, session, &params)
	}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &result) })
	return result, err
}

// GetLatestQuota is the newest reading of every limit of every account.
func GetLatestQuota(ctx context.Context, conn *Connection) ([]QuotaObservation, error) {
	var result protocol.Server
	err := executeRead(ctx, conn, operation{Name: "read latest quota", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetServerRequest(base, nil)
	}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &result) })
	return result.Quota, err
}

// QuotaTrailQuery names one limit of one account, and optionally how far back to read.
type QuotaTrailQuery struct {
	Provider string
	Account  string
	Limit    string
	Since    time.Time
}

// GetQuotaTrail is a limit's readings, oldest first. It reads at most five
// pages of 200, newest first, so a limit with more than that since the bound
// comes back without its oldest readings: a trail is for drawing, not for audit.
func GetQuotaTrail(ctx context.Context, conn *Connection, q QuotaTrailQuery) ([]QuotaObservation, error) {
	observations := []QuotaObservation{}
	next := ""
	seen := map[string]bool{}
	for page := 0; page < 5; page++ {
		params := protocol.GetServerParams{
			Include:       new("quota_history"),
			Limit:         new(int64(200)),
			QuotaProvider: &q.Provider,
			QuotaAccount:  &q.Account,
			QuotaLimit:    &q.Limit,
		}
		if !q.Since.IsZero() {
			formatted := q.Since.UTC().Format(time.RFC3339Nano)
			params.QuotaSince = &formatted
		}
		if next != "" {
			params.Next = &next
		}
		var result protocol.Server
		err := executeRead(ctx, conn, operation{Name: "inspect quota trail", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
			return protocol.NewGetServerRequest(base, &params)
		}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &result, "quota_history") })
		if err != nil {
			return nil, err
		}
		if result.QuotaHistory == nil {
			return nil, fieldError("quota history")
		}
		observations = append(observations, result.QuotaHistory.Items...)
		next = value(result.QuotaHistory.Next)
		if next == "" {
			break
		}
		if seen[next] {
			return nil, fieldError("quota trail page cursor")
		}
		seen[next] = true
	}
	slices.Reverse(observations)
	return observations, nil
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
