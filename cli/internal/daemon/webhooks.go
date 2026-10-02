package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

type Webhook struct {
	ID       string `json:"id"`
	Session  string `json:"session"`
	Name     string `json:"name"`
	URL      string `json:"url"`
	Address  string `json:"-"`
	Header   string `json:"signatureHeader"`
	Prefix   string `json:"signaturePrefix"`
	Revision int    `json:"revision"`
	Enabled  bool   `json:"enabled"`
}

type WebhookEntry struct {
	Deferred *string `json:"deferred"`
	Hook     Webhook `json:"hook"`
	Queued   int     `json:"queued"`
}

type WebhookResult struct {
	Hook            *Webhook       `json:"hook"`
	Session         string         `json:"session"`
	Secret          string         `json:"secret"`
	Message         string         `json:"message"`
	Hooks           []WebhookEntry `json:"hooks"`
	AgentManagement bool           `json:"agentManagement"`
}

func webhookArguments(body CommandRequest) (action, details string) {
	if body.Args != nil {
		return body.Args.Action, strings.TrimSpace(body.Args.Details)
	}
	action, details, _ = strings.Cut(strings.TrimSpace(body.Arguments), " ")
	return strings.TrimSpace(action), strings.TrimSpace(details)
}

func webhookGeneratesSecret(action, details string) bool {
	switch action {
	case "create", "rotate":
		return true
	case "create_in":
		_, rest, _ := strings.Cut(details, " ")
		_, supplied, _ := strings.Cut(rest, " ")
		return supplied == ""
	default:
		return false
	}
}

type webhookWire struct {
	ID       *string `json:"id"`
	Session  *string `json:"session"`
	Name     *string `json:"name"`
	URL      *string `json:"url"`
	Header   *string `json:"signatureHeader"`
	Prefix   *string `json:"signaturePrefix"`
	Revision *int    `json:"revision"`
	Enabled  *bool   `json:"enabled"`
}

func (wire webhookWire) hook() (*Webhook, error) {
	for _, field := range []struct {
		name  string
		value *string
	}{{"id", wire.ID}, {"session", wire.Session}, {"name", wire.Name}, {"url", wire.URL}, {"signatureHeader", wire.Header}, {"signaturePrefix", wire.Prefix}} {
		if field.value == nil {
			return nil, fieldError(field.name)
		}
	}
	if *wire.ID == "" {
		return nil, fieldError("id")
	}
	if wire.Enabled == nil {
		return nil, fieldError("enabled")
	}
	if wire.Revision == nil {
		return nil, fieldError("revision")
	}
	return &Webhook{ID: *wire.ID, Session: *wire.Session, Name: *wire.Name, URL: *wire.URL, Header: *wire.Header, Prefix: *wire.Prefix, Revision: *wire.Revision, Enabled: *wire.Enabled}, nil
}

func decodeWebhookResult(data []byte, body CommandRequest) (_ *WebhookResult, err error) {
	// Keep webhook field errors local to the hook even when it is nested in a
	// receipt or list, matching mutation failure reporting.
	defer func() {
		if detail, ok := errors.AsType[*json.UnmarshalTypeError](err); ok && detail.Field != "" {
			field := detail.Field
			if index := strings.LastIndexByte(field, '.'); index >= 0 {
				field = field[index+1:]
			}
			err = &responseFieldError{field: field, cause: err}
		}
	}()
	action, details := webhookArguments(body)
	result := &WebhookResult{}
	switch action {
	case "", "list":
		var wire struct {
			Session         *string `json:"session"`
			AgentManagement *bool   `json:"agentManagement"`
			Hooks           []struct {
				Hook     *webhookWire    `json:"hook"`
				Queued   *int            `json:"queued"`
				Deferred json.RawMessage `json:"deferred"`
			} `json:"hooks"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return nil, err
		}
		if wire.Session == nil {
			return nil, fieldError("session")
		}
		if wire.AgentManagement == nil {
			return nil, fieldError("agentManagement")
		}
		if wire.Hooks == nil {
			return nil, fieldError("hooks")
		}
		result.Session, result.AgentManagement = *wire.Session, *wire.AgentManagement
		result.Hooks = make([]WebhookEntry, 0, len(wire.Hooks))
		for _, entry := range wire.Hooks {
			if entry.Hook == nil {
				return nil, fieldError("hook")
			}
			hook, err := entry.Hook.hook()
			if err != nil {
				return nil, err
			}
			if entry.Queued == nil || *entry.Queued < 0 {
				return nil, fieldError("queued")
			}
			if len(entry.Deferred) == 0 {
				return nil, fieldError("deferred")
			}
			var deferred *string
			if err := json.Unmarshal(entry.Deferred, &deferred); err != nil {
				return nil, &responseFieldError{field: "deferred", cause: err}
			}
			result.Hooks = append(result.Hooks, WebhookEntry{Hook: *hook, Queued: *entry.Queued, Deferred: deferred})
		}
	case "agent_on", "agent_off":
		var wire struct {
			Message *string `json:"message"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return nil, err
		}
		if wire.Message == nil {
			return nil, fieldError("message")
		}
		result.Message = *wire.Message
	case "create", "create_with_secret", "create_in", "rotate", "rotate_with_secret":
		var wire struct {
			Hook    *webhookWire    `json:"hook"`
			Message *string         `json:"message"`
			Secret  json.RawMessage `json:"secret"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return nil, err
		}
		if wire.Hook == nil {
			return nil, fieldError("hook")
		}
		hook, err := wire.Hook.hook()
		if err != nil {
			return nil, err
		}
		if wire.Message == nil {
			return nil, fieldError("message")
		}
		result.Hook, result.Message = hook, *wire.Message
		if len(wire.Secret) > 0 || webhookGeneratesSecret(action, details) {
			if len(wire.Secret) == 0 {
				return nil, fieldError("secret")
			}
			if err := json.Unmarshal(wire.Secret, &result.Secret); err != nil {
				return nil, &responseFieldError{field: "secret", cause: err}
			}
			if result.Secret == "" {
				return nil, fieldError("secret")
			}
		}
	case "signature", "enable", "disable", "delete":
		var wire webhookWire
		if err := json.Unmarshal(data, &wire); err != nil {
			return nil, err
		}
		hook, err := wire.hook()
		if err != nil {
			return nil, err
		}
		result.Hook = hook
	default:
		return nil, errors.New("unsupported webhook action")
	}
	return result, nil
}

type WebhookAction string

const (
	WebhookList         WebhookAction = "list"
	WebhookCreate       WebhookAction = "create"
	WebhookSignature    WebhookAction = "signature"
	WebhookRotate       WebhookAction = "rotate"
	WebhookEnable       WebhookAction = "enable"
	WebhookDisable      WebhookAction = "disable"
	WebhookDelete       WebhookAction = "delete"
	WebhookAgentEnable  WebhookAction = "agent_enable"
	WebhookAgentDisable WebhookAction = "agent_disable"
)

var webhookNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

var webhookHeaderPattern = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

type WebhookRequest struct {
	Action                                          WebhookAction
	HookID, SessionID, Name, Secret, Header, Prefix string
}

func RunWebhook(ctx context.Context, conn *Connection, session string, request WebhookRequest) (*WebhookResult, error) {
	for _, value := range []string{request.HookID, request.SessionID, request.Name, request.Secret, request.Header, request.Prefix} {
		if strings.ContainsAny(value, " \t\r\n") {
			return nil, errors.New("webhook fields cannot contain spaces")
		}
	}
	action := string(request.Action)
	details := request.HookID
	switch request.Action {
	case WebhookList:
		details = ""
	case WebhookCreate:
		if request.SessionID == "" || !webhookNamePattern.MatchString(request.Name) {
			return nil, errors.New("webhook creation requires a session and a valid name")
		}
		if request.Secret != "" && (len(request.Secret) < 16 || len(request.Secret) > 4096) {
			return nil, errors.New("webhook secret must contain 16–4096 bytes")
		}
		action = "create_in"
		details = request.SessionID + " " + request.Name
		if request.Secret != "" {
			details += " " + request.Secret
		}
	case WebhookSignature:
		if request.HookID == "" || !webhookHeaderPattern.MatchString(request.Header) || len(request.Prefix) > 32 {
			return nil, errors.New("webhook signature requires a hook, valid header and prefix")
		}
		details = request.HookID + " " + request.Header + " " + request.Prefix
	case WebhookRotate:
		if request.HookID == "" {
			return nil, errors.New("webhook rotation requires a hook")
		}
		if request.Secret != "" && (len(request.Secret) < 16 || len(request.Secret) > 4096) {
			return nil, errors.New("webhook secret must contain 16–4096 bytes")
		}
		if request.Secret != "" {
			action = "rotate_with_secret"
			details = request.HookID + " " + request.Secret
		}
	case WebhookEnable, WebhookDisable, WebhookDelete:
		if request.HookID == "" {
			return nil, errors.New("webhook action requires a hook")
		}
	case WebhookAgentEnable:
		action, details = "agent_on", ""
	case WebhookAgentDisable:
		action, details = "agent_off", ""
	default:
		return nil, errors.New("unknown webhook action")
	}
	result, err := executeCommand(ctx, conn, session, CommandRequest{Name: "/webhooks", Args: &CommandArgs{Action: action, Details: details}}, false)
	if err != nil {
		return nil, err
	}
	snapshot := conn.Snapshot()
	hooks := result.Webhooks
	for i := range hooks.Hooks {
		hooks.Hooks[i].Hook.Address = hooks.Hooks[i].Hook.URL
		if snapshot.Port != 0 {
			hooks.Hooks[i].Hook.Address = fmt.Sprintf("http://127.0.0.1:%d%s", snapshot.Port, hooks.Hooks[i].Hook.URL)
		}
	}
	if hooks.Hook != nil {
		hooks.Hook.Address = hooks.Hook.URL
		if snapshot.Port != 0 {
			hooks.Hook.Address = fmt.Sprintf("http://127.0.0.1:%d%s", snapshot.Port, hooks.Hook.URL)
		}
	}
	return hooks, nil
}
