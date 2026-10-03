package daemon

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"regexp"
)

type Webhook struct {
	ID, Session, Name, URL, Address, Header, Prefix, Revision, ETag string
	Enabled                                                         bool
}
type WebhookEntry struct {
	Deferred *string
	Hook     Webhook
	Queued   int
}
type WebhookResult struct {
	Hook                                                *Webhook
	Session, Secret, Message, PermissionETag, DeletedID string
	Hooks                                               []WebhookEntry
	AgentManagement                                     bool
}
type WebhookPermission struct {
	SessionID, ETag string
	AgentManagement bool
}
type WebhookCreateRequest struct {
	SessionID string  `json:"session_id"`
	Name      string  `json:"name"`
	Secret    string  `json:"secret,omitempty"`
	Header    string  `json:"signature_header,omitempty"`
	Prefix    *string `json:"signature_prefix,omitempty"`
	Enabled   *bool   `json:"enabled,omitempty"`
}
type WebhookPatch struct {
	Name    *string `json:"name,omitempty"`
	Header  *string `json:"signature_header,omitempty"`
	Prefix  *string `json:"signature_prefix,omitempty"`
	Enabled *bool   `json:"enabled,omitempty"`
}
type WebhookAction string

const (
	WebhookCreate       WebhookAction = "create"
	WebhookSignature    WebhookAction = "signature"
	WebhookRotate       WebhookAction = "rotate"
	WebhookEnable       WebhookAction = "enable"
	WebhookDisable      WebhookAction = "disable"
	WebhookDelete       WebhookAction = "delete"
	WebhookAgentEnable  WebhookAction = "agent_enable"
	WebhookAgentDisable WebhookAction = "agent_disable"
)

// WebhookRequest is a captured terminal form operation, not a public dispatcher.
type WebhookRequest struct {
	Action                                                WebhookAction
	HookID, SessionID, Name, Secret, Header, Prefix, ETag string
}

var webhookNamePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
var webhookHeaderPattern = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

func hookValue(w wireHookConfigurationResource, deliveryURL string) Webhook {
	c := w.Value
	return Webhook{ID: c.ID, Session: c.SessionID, Name: c.Name, URL: deliveryURL, Address: deliveryURL, Header: c.SignatureHeader, Prefix: c.SignaturePrefix, Revision: c.Revision, ETag: w.ETag, Enabled: c.Enabled}
}
func ListWebhooks(ctx context.Context, conn *Connection, sessionID string) ([]WebhookEntry, error) {
	r := []WebhookEntry{}
	q := url.Values{"limit": {"200"}}
	if sessionID != "" {
		q.Set("session_id", sessionID)
	}
	seen := map[string]bool{}
	for {
		var page wireHookPage
		err := executeRead(ctx, conn, operation{Name: "list webhooks", Method: http.MethodGet, Path: "/extensions/webhooks/hooks?" + q.Encode(), Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &page, "items", "next") })
		if err != nil {
			return nil, err
		}
		if page.Items == nil {
			return nil, fieldError("hooks")
		}
		for _, row := range page.Items {
			if row.ConfigurationResource.ETag == "" {
				return nil, fieldError("hook validator")
			}
			var deferred *string
			if row.DeferralReason != nil {
				deferred = &row.DeferralReason.Detail
			}
			r = append(r, WebhookEntry{Hook: hookValue(row.ConfigurationResource, row.DeliveryURL), Queued: int(row.PendingCount), Deferred: deferred})
		}
		if page.Next == nil {
			return r, nil
		}
		if seen[*page.Next] {
			return nil, fieldError("hook page cursor")
		}
		seen[*page.Next] = true
		q.Set("next", *page.Next)
	}
}
func hookChange(ctx context.Context, conn *Connection, op operation, status int, secret bool) (*WebhookResult, error) {
	var w wireHookChange
	err := executeMutation(ctx, conn, op, []int{status}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &w, "resource", "notification"); err != nil {
			return err
		}
		if w.Resource.ETag == "" || w.Resource.Value.ID == "" {
			return fieldError("hook resource")
		}
		if secret && w.Secret == "" {
			return fieldError("hook secret")
		}
		if !secret && w.Secret != "" {
			return fieldError("unexpected hook secret")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	h := hookValue(w.Resource, "")
	r := &WebhookResult{Hook: &h, Secret: w.Secret, Message: "Saved."}
	if w.Notification.State == "failed" {
		r.Message = "Saved; notification failed: " + value(w.Notification.Detail)
	}
	return r, nil
}
func CreateWebhook(ctx context.Context, conn *Connection, request WebhookCreateRequest) (*WebhookResult, error) {
	if !webhookNamePattern.MatchString(request.Name) || request.SessionID == "" {
		return nil, errors.New("webhook creation requires a session and a valid name")
	}
	return hookChange(ctx, conn, operation{Name: "create webhook", Method: http.MethodPost, Path: "/extensions/webhooks/hooks", Body: request, Policy: noRecovery}, 201, true)
}
func EditWebhook(ctx context.Context, conn *Connection, id, etag string, patch WebhookPatch) (*WebhookResult, error) {
	headers, err := observedHeaders(etag)
	if err != nil {
		return nil, err
	}
	return hookChange(ctx, conn, operation{Name: "edit webhook", Method: http.MethodPatch, Path: "/extensions/webhooks/hooks/" + url.PathEscape(id) + "?view=configuration", Headers: headers, Body: patch, Policy: noRecovery}, 200, false)
}
func RotateWebhookSecret(ctx context.Context, conn *Connection, id, etag, secret string) (*WebhookResult, error) {
	headers, err := observedHeaders(etag)
	if err != nil {
		return nil, err
	}
	headers.Set("Content-Type", "application/json")
	return hookChange(ctx, conn, operation{Name: "rotate webhook secret", Method: http.MethodPost, Path: "/extensions/webhooks/hooks/" + url.PathEscape(id) + "/secret", Headers: headers, Body: struct {
		Secret string `json:"secret,omitempty"`
	}{secret}, Policy: noRecovery}, 200, true)
}
func DeleteWebhook(ctx context.Context, conn *Connection, id, etag string) (*WebhookResult, error) {
	headers, err := observedHeaders(etag)
	if err != nil {
		return nil, err
	}
	var w wireExtensionDeletion
	err = executeMutation(ctx, conn, operation{Name: "delete webhook", Method: http.MethodDelete, Path: "/extensions/webhooks/hooks/" + url.PathEscape(id) + "?view=configuration", Headers: headers, Policy: noRecovery}, []int{200}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &w, "id", "notification"); err != nil {
			return err
		}
		if w.ID != id {
			return fieldError("deleted hook")
		}
		return nil
	})
	r := &WebhookResult{Message: "Deleted.", DeletedID: w.ID}
	if w.Notification.State == "failed" {
		r.Message += " Notification failed: " + value(w.Notification.Detail)
	}
	return r, err
}
func GetWebhookPermission(ctx context.Context, conn *Connection, id string) (WebhookPermission, error) {
	r := WebhookPermission{SessionID: id}
	var w wireHookPermission
	err := executeRead(ctx, conn, operation{Name: "read webhook agent permission", Method: http.MethodGet, Path: "/extensions/webhooks/permissions/" + url.PathEscape(id), Validator: &r.ETag, Policy: readRecovery}, func(data []byte) error {
		if err := decodeRequired(data, &w, "session_id", "agent_manage", "revision"); err != nil {
			return err
		}
		if w.SessionID != id || r.ETag == "" {
			return fieldError("webhook permission")
		}
		r.AgentManagement = w.AgentManage
		return nil
	})
	return r, err
}
func SetWebhookPermission(ctx context.Context, conn *Connection, id, etag string, enabled bool) (*WebhookResult, error) {
	headers, err := observedHeaders(etag)
	if err != nil {
		return nil, err
	}
	var w wireHookPermissionChange
	err = executeMutation(ctx, conn, operation{Name: "edit webhook agent permission", Method: http.MethodPatch, Path: "/extensions/webhooks/permissions/" + url.PathEscape(id), Headers: headers, Body: map[string]bool{"agent_manage": enabled}, Policy: noRecovery}, []int{200}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &w, "resource", "notification"); err != nil {
			return err
		}
		if w.Resource.Value.SessionID != id || w.Resource.ETag == "" || w.Resource.Value.AgentManage != enabled {
			return fieldError("webhook permission acknowledgment")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	result := &WebhookResult{AgentManagement: w.Resource.Value.AgentManage, PermissionETag: w.Resource.ETag, Message: "Saved agent permission."}
	if w.Notification.State == "failed" {
		result.Message += " Notification failed: " + value(w.Notification.Detail)
	}
	return result, nil
}
