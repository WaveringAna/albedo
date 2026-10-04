package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/url"
	"path"
	"slices"
	"strings"
	"time"

	"albedo/cli/internal/daemon/protocol"

	"github.com/google/jsonschema-go/jsonschema"
)

type PageActionRequest struct {
	Action  PageAction
	Row     *PageRow
	Form    map[string]json.RawMessage
	Session *Session
}

func LoadPage(ctx context.Context, conn *Connection, session, command string) (*PageDocument, error) {
	snapshot, err := GetSession(ctx, conn, session)
	if err != nil {
		return nil, err
	}
	if command == "/ttl" || command == "/quota" || command == "/requests" {
		return loadPlatformInspector(ctx, conn, snapshot, command)
	}
	var buildRequest func(string, io.Reader) (*http.Request, error)
	switch command {
	case "/work":
		buildRequest = func(base string, _ io.Reader) (*http.Request, error) {
			return protocol.NewListWorkRequest(base, &protocol.ListWorkParams{Workspace: snapshot.Workspace})
		}
	case "/paperclips":
		buildRequest = func(base string, _ io.Reader) (*http.Request, error) {
			return protocol.NewListPaperclipsRequest(base, nil)
		}
	case "/schedule":
		buildRequest = func(base string, _ io.Reader) (*http.Request, error) {
			return protocol.NewListScheduleRequest(base, &protocol.ListScheduleParams{SessionID: session})
		}
	case "/links":
		buildRequest = func(base string, _ io.Reader) (*http.Request, error) {
			return protocol.NewGetLinkGroupRequest(base, &protocol.GetLinkGroupParams{Workspace: snapshot.Workspace})
		}
	default:
		catalog, err := GetCapabilityCatalog(ctx, conn, session)
		if err != nil {
			return nil, err
		}
		for _, declared := range catalog.Commands {
			if declared.Name == command && declared.Delivery == "read" {
				payload, err := executeBoundOperation(ctx, conn, declared.Operation, nil, map[string]json.RawMessage{}, &snapshot)
				if err != nil {
					return nil, err
				}
				doc, err := readResultPage(payload, declared.Name, declared.Description)
				if err == nil {
					doc.Session = &snapshot
					doc.read = &pageRead{Name: declared.Name, Description: declared.Description, Operation: declared.Operation, Form: map[string]json.RawMessage{}}
				}
				return doc, err
			}
		}
		return nil, fmt.Errorf("no declared page for %s", command)
	}
	var doc *PageDocument
	err = executeRead(ctx, conn, operation{Name: "read " + command + " page", BuildRequest: buildRequest, Policy: readRecovery}, func(data []byte) error { var err error; doc, err = decodePageDocument(data); return err })
	if doc != nil {
		doc.Session = &snapshot
	}
	return doc, err
}
func RefreshPage(ctx context.Context, conn *Connection, session, command string, previous *PageDocument) (*PageDocument, error) {
	if previous == nil || previous.read == nil {
		return LoadPage(ctx, conn, session, command)
	}
	snapshot, err := GetSession(ctx, conn, session)
	if err != nil {
		return nil, err
	}
	read := previous.read
	payload, err := executeBoundOperation(ctx, conn, read.Operation, read.Row, read.Form, &snapshot)
	if err != nil {
		return nil, err
	}
	doc, err := readResultPage(payload, read.Name, read.Description)
	if err == nil {
		doc.Session, doc.read = &snapshot, read
	}
	return doc, err
}
func ExecutePageAction(ctx context.Context, conn *Connection, request PageActionRequest) (CommandResult, error) {
	form := request.Form
	if form == nil {
		form = map[string]json.RawMessage{}
	}
	payload, err := executeBoundOperation(ctx, conn, request.Action.Operation, request.Row, form, request.Session)
	if err != nil {
		return CommandResult{}, err
	}
	if request.Action.Operation.Method == http.MethodGet {
		doc, err := readResultPage(payload, request.Action.Label, "")
		if err != nil {
			return CommandResult{}, err
		}
		doc.Session = request.Session
		var row *PageRow
		if request.Row != nil {
			captured := *request.Row
			row = &captured
		}
		doc.read = &pageRead{Name: request.Action.Label, Operation: request.Action.Operation, Row: row, Form: maps.Clone(form)}
		return CommandResult{Result: payload, Page: doc}, nil
	}
	return extensionResult(payload), nil
}
func executeBoundOperation(ctx context.Context, conn *Connection, declared protocol.ActionOperation, row *PageRow, form map[string]json.RawMessage, session *Session) ([]byte, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	template := declared.PathTemplate
	if !strings.HasPrefix(template, "/") || strings.HasPrefix(template, "//") || strings.ContainsAny(template, "?#\\") || path.Clean(template) != template {
		return nil, errors.New("unsafe declared action path")
	}
	var rowData, sessionData json.RawMessage
	if row != nil {
		rowData, _ = json.Marshal(row.wire)
	}
	if session != nil {
		sessionData, _ = json.Marshal(session.wire)
	}
	formData, _ := json.Marshal(form)
	resolve := func(raw protocol.Binding) (json.RawMessage, error) {
		return resolveBinding(json.RawMessage(raw), rowData, formData, sessionData)
	}
	route := template
	for name, binding := range declared.Path {
		resolved, err := resolve(binding)
		if err != nil {
			return nil, err
		}
		text, err := bindingText(resolved)
		if err != nil {
			return nil, err
		}
		if text == "" || text == "." || text == ".." || strings.ContainsAny(text, "/\\") {
			return nil, errors.New("unsafe path binding")
		}
		route = strings.ReplaceAll(route, "{"+name+"}", url.PathEscape(text))
	}
	if strings.ContainsAny(route, "{}") {
		return nil, errors.New("unresolved action path")
	}
	method := declared.Method
	if !strings.HasPrefix(route, "/extensions/") && method != http.MethodGet {
		return nil, errors.New("a page cannot edit platform credentials, defaults, or daemon lifecycle")
	}
	if method != http.MethodGet && method != http.MethodPut && method != http.MethodPost && method != http.MethodPatch && method != http.MethodDelete {
		return nil, errors.New("unsupported declared action method")
	}
	query := url.Values{}
	for name, binding := range declared.Query {
		resolved, err := resolve(binding)
		if err != nil {
			if _, optional := errors.AsType[*missingFormBindingError](err); optional {
				continue
			}
			return nil, err
		}
		text, err := bindingText(resolved)
		if err != nil {
			return nil, err
		}
		query.Set(name, text)
	}
	headers := http.Header{}
	for name, binding := range declared.Headers {
		if !strings.EqualFold(name, "If-Match") {
			return nil, errors.New("declared actions may only bind If-Match")
		}
		resolved, err := resolve(binding)
		if err != nil {
			return nil, err
		}
		text, err := bindingText(resolved)
		if err != nil {
			return nil, err
		}
		if text == "" {
			return nil, errors.New("the displayed resource has no validator")
		}
		headers.Set("If-Match", text)
	}
	var body any
	if len(declared.Body) > 0 {
		if err := validateBodyBindings(declared.Body); err != nil {
			return nil, err
		}
		fields := map[string]any{}
		for pointer, binding := range declared.Body {
			resolved, err := resolve(binding)
			if err != nil {
				if _, optional := errors.AsType[*missingFormBindingError](err); optional {
					continue
				}
				return nil, err
			}
			field, err := dynamicValue(resolved)
			if err != nil {
				return nil, err
			}
			if err := setBodyPointer(fields, pointer, field); err != nil {
				return nil, err
			}
		}
		body = fields
	}
	if method == http.MethodPatch {
		headers.Set("Content-Type", "application/merge-patch+json")
	}
	if encoded := query.Encode(); encoded != "" {
		route += "?" + encoded
	}
	policy := noRecovery
	if method == http.MethodGet {
		policy = readRecovery
	}
	var resultSchema *jsonschema.Resolved
	if method != http.MethodGet {
		var schema jsonschema.Schema
		if len(declared.ResultSchema) > 0 {
			if err := json.Unmarshal(declared.ResultSchema, &schema); err != nil {
				return nil, fmt.Errorf("invalid declared result schema: %w", err)
			}
		}
		var err error
		resultSchema, err = schema.Resolve(&jsonschema.ResolveOptions{Loader: func(*url.URL) (*jsonschema.Schema, error) {
			return nil, errors.New("result schemas cannot retrieve external references")
		}})
		if err != nil {
			return nil, fmt.Errorf("invalid declared result schema: %w", err)
		}
	}
	op := operation{Name: "invoke " + declared.OperationID, Method: method, Path: route, Headers: headers, Body: body, Policy: policy}
	if method == http.MethodGet {
		return requestBytes(ctx, conn, op, responseLimits{successStatus: http.StatusOK, bodyBytes: 1048576, errorBytes: 65536})
	}
	status := http.StatusOK
	if method == http.MethodPost && (template == "/extensions/work/items" || template == "/extensions/paperclips/items" || template == "/extensions/schedule/jobs") {
		status = http.StatusCreated
	}
	var payload []byte
	err := executeMutation(ctx, conn, op, []int{status}, func(data []byte, _ int) error {
		result, err := dynamicValue(data)
		if err != nil {
			return err
		}
		if err := resultSchema.Validate(result); err != nil {
			return fmt.Errorf("declared result schema: %w", err)
		}
		if err := validateExtensionAcknowledgment(data, template, method); err != nil {
			return err
		}
		payload = slices.Clone(data)
		return nil
	})
	return payload, err
}
func extensionResult(data []byte) CommandResult {
	result := CommandResult{Result: data, Message: "Saved."}
	var envelope struct {
		Notification      *protocol.Notification        `json:"notification"`
		Notifications     []protocol.TargetNotification `json:"notifications"`
		Page              *protocol.PageDescriptor      `json:"page"`
		Truncated         bool                          `json:"truncated"`
		NotificationCount int64                         `json:"notification_count"`
	}
	if json.Unmarshal(data, &envelope) == nil {
		if envelope.Notification != nil && envelope.Notification.State == "failed" {
			result.Message = "Saved; notification failed: " + value(envelope.Notification.Detail)
		}
		for _, target := range envelope.Notifications {
			if target.Notification.State == "failed" {
				if result.Message == "Saved." {
					result.Message = "Saved; notifications failed:"
				}
				result.Message += " " + target.SessionID + ": " + value(target.Notification.Detail)
			}
		}
		if envelope.Truncated {
			result.Message += fmt.Sprintf(" Notification results show %d of %d sessions.", len(envelope.Notifications), envelope.NotificationCount)
		}
		if envelope.Page != nil {
			result.Page, _ = pageValue(*envelope.Page)
		}
	}
	return result
}

// Built-in operations have typed contracts independent of their page layout.
// Additional extensions describe their own result schema in the catalog.
func validateExtensionAcknowledgment(data []byte, route, method string) error {
	switch {
	case strings.HasPrefix(route, "/extensions/links/"):
		var result protocol.LinkChange
		return decodeRequired(data, &result)
	case method == http.MethodDelete && (strings.HasPrefix(route, "/extensions/work/") || strings.HasPrefix(route, "/extensions/paperclips/") || strings.HasPrefix(route, "/extensions/schedule/")):
		var result protocol.ExtensionDeletion
		return decodeRequired(data, &result)
	case strings.HasPrefix(route, "/extensions/work/"):
		var result protocol.WorkChange
		return decodeRequired(data, &result)
	case strings.HasPrefix(route, "/extensions/paperclips/"):
		var result protocol.PaperclipChange
		return decodeRequired(data, &result)
	case strings.HasPrefix(route, "/extensions/schedule/"):
		var result protocol.ScheduleChange
		return decodeRequired(data, &result)
	default:
		if !json.Valid(data) {
			return fieldError("extension operation result")
		}
		return nil
	}
}
