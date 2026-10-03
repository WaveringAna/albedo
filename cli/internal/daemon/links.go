package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

type linkConfiguration struct {
	Value wireLinkConfiguration
	ETag  string
}

func getLinkConfiguration(ctx context.Context, conn *Connection, workspace string) (linkConfiguration, error) {
	result := linkConfiguration{}
	query := url.Values{"workspace": {workspace}, "view": {"configuration"}, "limit": {"200"}}
	err := executeRead(ctx, conn, operation{Name: "read linked workspace membership", Method: http.MethodGet, Path: "/extensions/links/groups?" + query.Encode(), Validator: &result.ETag, Policy: readRecovery}, func(data []byte) error {
		if err := decodeRequired(data, &result.Value, "workspace", "group_id", "members", "revision", "next"); err != nil {
			return err
		}
		if result.Value.Workspace == "" || result.Value.GroupID == "" || result.ETag == "" {
			return fieldError("link configuration")
		}
		return nil
	})
	return result, err
}

// PrepareLinkMerge captures both groups before a person confirms their merge.
func PrepareLinkMerge(ctx context.Context, conn *Connection, session Session, otherWorkspace string) (*PageDocument, error) {
	current, err := getLinkConfiguration(ctx, conn, session.Workspace)
	if err != nil {
		return nil, err
	}
	other, err := getLinkConfiguration(ctx, conn, otherWorkspace)
	if err != nil {
		return nil, err
	}
	if current.Value.GroupID == other.Value.GroupID {
		return nil, fmt.Errorf("these workspaces already share a linked group")
	}
	literal := func(v any) wireBinding {
		encoded, _ := json.Marshal(map[string]any{"source": "literal", "value": v})
		return wireBinding(encoded)
	}
	operation := wireActionOperation{OperationID: "mergeLinkGroups", Method: http.MethodPost, PathTemplate: "/extensions/links/groups", Path: map[string]wireBinding{}, Query: map[string]wireBinding{"workspace": literal(current.Value.Workspace), "view": literal("configuration")}, Headers: map[string]wireBinding{"If-Match": literal(current.ETag)}, Body: map[string]wireBinding{"/other_workspace": literal(other.Value.Workspace), "/other_etag": literal(other.ETag)}, ResultSchema: json.RawMessage(`{"type":"object","required":["resource","notifications","notification_count","truncated"]}`)}
	doc := &PageDocument{Title: "Link workspace groups", Summary: "The complete groups will share memory and work after you confirm.", Session: &session, Rows: []PageRow{}, Actions: []PageAction{{ID: "merge", Key: "enter", Label: "link these groups", Confirmation: "Link both displayed workspace groups?", Confirm: true, Operation: operation}}}
	for _, group := range []linkConfiguration{current, other} {
		detail := strings.Join(group.Value.Members, "\n")
		if group.Value.Next != nil {
			detail += "\nAdditional members are omitted from this preview."
		}
		doc.Rows = append(doc.Rows, PageRow{ID: group.Value.GroupID, Text: group.Value.Workspace, Badge: fmt.Sprintf("%d shown", len(group.Value.Members)), Detail: detail, Tone: TonePlain})
	}
	return doc, nil
}
