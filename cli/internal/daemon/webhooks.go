package daemon

import (
	"context"
	"errors"
	"io"
	"net/http"
	"regexp"

	"albedo/cli/internal/daemon/protocol"
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
type WebhookCreateRequest = protocol.HookCreate
type WebhookPatch = protocol.HookPatch
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

func hookValue(w protocol.HookConfigurationResource, deliveryURL string) Webhook {
	c := w.Value
	return Webhook{ID: c.ID, Session: c.SessionID, Name: c.Name, URL: deliveryURL, Address: deliveryURL, Header: c.SignatureHeader, Prefix: c.SignaturePrefix, Revision: c.Revision, ETag: w.ETag, Enabled: c.Enabled}
}
func ListWebhooks(ctx context.Context, conn *Connection, sessionID string) ([]WebhookEntry, error) {
	r := []WebhookEntry{}
	params := protocol.ListHooksParams{Limit: new(int64(200))}
	if sessionID != "" {
		params.SessionID = &sessionID
	}
	err := walkPages(func(next *string) (protocol.HookPage, *string, error) {
		params.Next = next
		var page protocol.HookPage
		pageErr := executeRead(ctx, conn, operation{Name: "list webhooks", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
			return protocol.NewListHooksRequest(base, &params)
		}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &page) })
		return page, page.Next, pageErr
	}, func(page protocol.HookPage) error {
		if page.Items == nil {
			return fieldError("hooks")
		}
		for _, row := range page.Items {
			if row.ConfigurationResource.ETag == "" {
				return fieldError("hook validator")
			}
			var deferred *string
			if row.DeferralReason != nil {
				deferred = &row.DeferralReason.Detail
			}
			r = append(r, WebhookEntry{Hook: hookValue(row.ConfigurationResource, row.DeliveryURL), Queued: int(row.PendingCount), Deferred: deferred})
		}
		return nil
	}, "hook page cursor")
	if err != nil {
		return nil, err
	}
	return r, nil
}

func hookChange(ctx context.Context, conn *Connection, op operation, status int, secret bool) (*WebhookResult, error) {
	var w protocol.HookChange
	err := executeMutation(ctx, conn, op, []int{status}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &w); err != nil {
			return err
		}
		if w.Resource.ETag == "" || w.Resource.Value.ID == "" {
			return fieldError("hook resource")
		}
		if secret && value(w.Secret) == "" {
			return fieldError("hook secret")
		}
		if !secret && w.Secret != nil {
			return fieldError("unexpected hook secret")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	h := hookValue(w.Resource, "")
	r := &WebhookResult{Hook: &h, Secret: value(w.Secret), Message: "Saved."}
	if w.Notification.State == "failed" {
		r.Message = "Saved; notification failed: " + value(w.Notification.Detail)
	}
	return r, nil
}
func CreateWebhook(ctx context.Context, conn *Connection, request WebhookCreateRequest) (*WebhookResult, error) {
	if !webhookNamePattern.MatchString(request.Name) || request.SessionID == "" {
		return nil, errors.New("webhook creation requires a session and a valid name")
	}
	return hookChange(ctx, conn, operation{Name: "create webhook", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewCreateHookRequest(base, request)
	}, Body: request, Policy: noRecovery}, 201, true)
}
func EditWebhook(ctx context.Context, conn *Connection, id, etag string, patch WebhookPatch) (*WebhookResult, error) {
	headers, err := observedHeaders(etag)
	if err != nil {
		return nil, err
	}
	return hookChange(ctx, conn, operation{Name: "edit webhook", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewPatchHookRequestWithApplicationMergePatchPlusJSONBody(base, id, &protocol.PatchHookParams{View: "configuration", IfMatch: etag}, patch)
	}, Headers: headers, Body: patch, Policy: noRecovery}, 200, false)
}
func RotateWebhookSecret(ctx context.Context, conn *Connection, id, etag, secret string) (*WebhookResult, error) {
	headers, err := observedHeaders(etag)
	if err != nil {
		return nil, err
	}
	headers.Set("Content-Type", "application/json")
	return hookChange(ctx, conn, operation{Name: "rotate webhook secret", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewRotateHookSecretRequestWithBody(base, id, &protocol.RotateHookSecretParams{IfMatch: etag}, "application/json", body)
	}, Headers: headers, Body: protocol.HookSecretRequest{Secret: optionalText(secret)}, Policy: noRecovery}, 200, true)
}
func DeleteWebhook(ctx context.Context, conn *Connection, id, etag string) (*WebhookResult, error) {
	headers, err := observedHeaders(etag)
	if err != nil {
		return nil, err
	}
	var w protocol.ExtensionDeletion
	err = executeMutation(ctx, conn, operation{Name: "delete webhook", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewDeleteHookRequest(base, id, &protocol.DeleteHookParams{View: "configuration", IfMatch: etag})
	}, Headers: headers, Policy: noRecovery}, []int{200}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &w); err != nil {
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
	var w protocol.HookPermission
	err := executeRead(ctx, conn, operation{Name: "read webhook agent permission", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetHookPermissionRequest(base, id)
	}, Validator: &r.ETag, Policy: readRecovery}, func(data []byte) error {
		if err := decodeRequired(data, &w); err != nil {
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
	var w protocol.HookPermissionChange
	err = executeMutation(ctx, conn, operation{Name: "edit webhook agent permission", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewPatchHookPermissionRequestWithBody(base, id, &protocol.PatchHookPermissionParams{IfMatch: etag}, "application/merge-patch+json", body)
	}, Headers: headers, Body: protocol.HookPermissionPatch{AgentManage: &enabled}, Policy: noRecovery}, []int{200}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &w); err != nil {
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
