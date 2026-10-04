package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"albedo/cli/internal/daemon/protocol"
)

type linkConfiguration struct {
	Value protocol.LinkConfiguration
	ETag  string
}

func getLinkConfiguration(ctx context.Context, conn *Connection, workspace string) (linkConfiguration, error) {
	result := linkConfiguration{}
	params := protocol.GetLinkGroupParams{Workspace: workspace, View: new("configuration"), Limit: new(int64(200))}
	err := executeRead(ctx, conn, operation{Name: "read linked workspace membership", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetLinkGroupRequest(base, &params)
	}, Validator: &result.ETag, Policy: readRecovery}, func(data []byte) error {
		if err := decodeRequired(data, &result.Value); err != nil {
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
	params := protocol.MergeLinkGroupsParams{Workspace: current.Value.Workspace, View: "configuration", IfMatch: current.ETag}
	request, err := protocol.NewMergeLinkGroupsRequestWithBody("", &params, "application/json", nil)
	if err != nil {
		return nil, err
	}
	literal := func(v any) protocol.Binding {
		encoded, _ := json.Marshal(map[string]any{"source": "literal", "value": v})
		return protocol.Binding(encoded)
	}
	operation := protocol.ActionOperation{OperationID: "mergeLinkGroups", Method: request.Method, PathTemplate: request.URL.Path, Path: map[string]protocol.Binding{}, Query: map[string]protocol.Binding{"workspace": literal(current.Value.Workspace), "view": literal("configuration")}, Headers: map[string]protocol.Binding{"If-Match": literal(current.ETag)}, Body: map[string]protocol.Binding{"/other_workspace": literal(other.Value.Workspace), "/other_etag": literal(other.ETag)}, ResultSchema: json.RawMessage(`{"type":"object","required":["resource","notifications","notification_count","truncated"]}`)}
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
