package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
)

type CommandResult struct {
	Model     *ModelSelection
	Effort    *EffortResult
	Page      *PageDocument
	Webhooks  *WebhookResult
	Message   string
	Result    json.RawMessage
	Submitted bool
}
type EffortResult struct {
	Effort    string   `json:"-"`
	Message   string   `json:"message"`
	Available []string `json:"available"`
}
type Webhook struct {
	ID       string `json:"id"`
	Session  string `json:"session"`
	Name     string `json:"name"`
	URL      string `json:"url"`
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

func decodeCommand(data []byte, status int) (CommandResult, error) {
	var wire struct {
		Result    json.RawMessage `json:"result"`
		Submitted json.RawMessage `json:"submitted"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return CommandResult{}, err
	}
	if status == 200 {
		if wire.Result == nil {
			return CommandResult{}, fieldError("result")
		}
		if wire.Submitted != nil {
			return CommandResult{}, fieldError("submitted")
		}
		return CommandResult{Result: wire.Result}, nil
	}
	if wire.Result != nil {
		return CommandResult{}, fieldError("result")
	}
	var submitted bool
	if wire.Submitted == nil || json.Unmarshal(wire.Submitted, &submitted) != nil || !submitted {
		return CommandResult{}, fieldError("submitted")
	}
	return CommandResult{Submitted: true}, nil
}

func ExecuteCommand(ctx context.Context, conn *Connection, id string, body map[string]any) (CommandResult, error) {
	return executeCommand(ctx, conn, id, body, false)
}
func ExecutePageCommand(ctx context.Context, conn *Connection, id string, body map[string]any) (CommandResult, error) {
	return executeCommand(ctx, conn, id, body, true)
}
func executeCommand(ctx context.Context, conn *Connection, id string, body map[string]any, page bool) (CommandResult, error) {
	var result CommandResult
	name, _ := body["name"].(string)
	err := executeMutation(ctx, conn, Operation{Name: "execute command " + name, Method: http.MethodPost, Path: sessionPath(id, "/commands"), Body: body, Policy: AuthRecovery}, []int{200, 202}, func(data []byte, status int) error {
		var err error
		result, err = decodeCommand(data, status)
		if err != nil {
			return err
		}
		if page || name == "/model" || name == "/effort" || name == "/webhooks" {
			if result.Submitted {
				return fieldError("result")
			}
			payload := result.Result
			switch {
			case page:
				if err := validatePage(payload); err != nil {
					return err
				}
				var envelope struct {
					Page PageDocument `json:"page"`
				}
				if err := json.Unmarshal(payload, &envelope); err != nil {
					return err
				}
				result.Page = &envelope.Page
				return nil
			case name == "/model":
				model, err := decodeModelSelection(payload)
				if err != nil {
					return err
				}
				result.Model = &model
				return nil
			case name == "/effort":
				if err := validateEffort(payload, body); err != nil {
					return err
				}
				var wire struct {
					Effort    *string  `json:"effort"`
					Message   string   `json:"message"`
					Available []string `json:"available"`
				}
				if err := json.Unmarshal(payload, &wire); err != nil {
					return err
				}
				effort := EffortResult{Available: wire.Available, Message: wire.Message}
				if wire.Effort != nil {
					effort.Effort = *wire.Effort
				}
				result.Effort = &effort
				return nil
			case name == "/webhooks":
				if err := validateWebhooks(payload, body); err != nil {
					return err
				}
				var webhook WebhookResult
				if err := json.Unmarshal(payload, &webhook); err != nil {
					return err
				}
				result.Webhooks = &webhook
				result.Message = webhook.Message
				return nil
			}
		}
		if len(result.Result) > 0 && result.Result[0] == '{' {
			if fields, err := object(result.Result); err == nil {
				var message string
				if raw := fields["message"]; raw != nil && json.Unmarshal(raw, &message) == nil {
					result.Message = message
				}
			}
		}
		return nil
	})
	return result, err
}
func validateEffort(data []byte, body map[string]any) error {
	fields, err := object(data)
	if err != nil {
		return err
	}
	var effort *string
	if err := nullable(fields, "effort", &effort); err != nil {
		return err
	}
	var message string
	if err := required(fields, "message", &message); err != nil {
		return err
	}
	arguments, _ := body["arguments"].(string)
	args, _ := body["args"].(map[string]string)
	if arguments == "" && args["level"] == "" {
		var available stringCollection
		return required(fields, "available", &available)
	}
	return nil
}

func validatePage(data []byte) error {
	envelope, err := object(data)
	if err != nil {
		return err
	}
	page, err := object(envelope["page"])
	if err != nil {
		return fieldError("page")
	}
	for _, key := range []string{"title", "summary", "empty"} {
		var value string
		if err := required(page, key, &value); err != nil {
			return err
		}
	}
	if err := validateRows(page["rows"]); err != nil {
		return err
	}
	var actions []json.RawMessage
	if err := required(page, "actions", &actions); err != nil {
		return err
	}
	for _, raw := range actions {
		action, err := object(raw)
		if err != nil {
			return err
		}
		var key, input string
		if err := required(action, "key", &key); err != nil {
			return err
		}
		if len([]rune(key)) != 1 {
			return fieldError("key")
		}
		for _, key := range []string{"label", "run"} {
			var value string
			if err := required(action, key, &value); err != nil {
				return err
			}
		}
		for _, key := range []string{"row", "confirm"} {
			var value bool
			if err := required(action, key, &value); err != nil {
				return err
			}
		}
		if err := required(action, "input", &input); err != nil {
			return err
		}
		switch input {
		case "none":
		case "text", "secret":
			var prompt string
			if err := required(action, "prompt", &prompt); err != nil {
				return err
			}
			if input == "text" {
				var prefill bool
				if err := required(action, "prefill", &prefill); err != nil {
					return err
				}
			}
		case "value":
			var value string
			if err := required(action, "value", &value); err != nil {
				return err
			}
		case "choice":
			var options stringCollection
			if err := required(action, "options", &options); err != nil {
				return err
			}
			if len(options) == 0 {
				return fieldError("options")
			}
		default:
			return fieldError("input")
		}
	}
	raw, ok := page["glance"]
	if !ok {
		return fieldError("glance")
	}
	if string(raw) != "null" {
		glance, err := object(raw)
		if err != nil {
			return err
		}
		var title string
		if err := required(glance, "title", &title); err != nil {
			return err
		}
		return validateRows(glance["rows"])
	}
	return nil
}
func validateRows(data []byte) error {
	var rows []json.RawMessage
	if err := json.Unmarshal(data, &rows); err != nil {
		return err
	}
	if rows == nil {
		return fieldError("rows")
	}
	for _, raw := range rows {
		row, err := object(raw)
		if err != nil {
			return err
		}
		for _, key := range []string{"id", "text", "badge", "detail"} {
			var value string
			if err := required(row, key, &value); err != nil {
				return err
			}
		}
		var tone string
		if err := required(row, "tone", &tone); err != nil {
			return err
		}
		switch tone {
		case "plain", "active", "warning", "muted":
		default:
			return fieldError("tone")
		}
	}
	return nil
}
func validateHook(data []byte) error {
	hook, err := object(data)
	if err != nil {
		return err
	}
	for _, key := range []string{"id", "session", "name", "url", "signatureHeader", "signaturePrefix"} {
		var value string
		if err := required(hook, key, &value); err != nil {
			return err
		}
		if key == "id" && value == "" {
			return fieldError("id")
		}
	}
	var enabled bool
	if err := required(hook, "enabled", &enabled); err != nil {
		return err
	}
	var revision int
	return required(hook, "revision", &revision)
}
func webhookArguments(body map[string]any) (action, details string) {
	args, _ := body["args"].(map[string]string)
	if len(args) > 0 {
		return args["action"], strings.TrimSpace(args["details"])
	}
	arguments, _ := body["arguments"].(string)
	action, details, _ = strings.Cut(strings.TrimSpace(arguments), " ")
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

func validateWebhooks(data []byte, body map[string]any) error {
	fields, err := object(data)
	if err != nil {
		return err
	}
	action, details := webhookArguments(body)
	switch action {
	case "", "list":
		var session string
		if err := required(fields, "session", &session); err != nil {
			return err
		}
		var management bool
		if err := required(fields, "agentManagement", &management); err != nil {
			return err
		}
		var hooks []json.RawMessage
		if err := required(fields, "hooks", &hooks); err != nil {
			return err
		}
		for _, raw := range hooks {
			entry, err := object(raw)
			if err != nil {
				return err
			}
			if err := validateHook(entry["hook"]); err != nil {
				return err
			}
			var queued int
			if err := required(entry, "queued", &queued); err != nil {
				return err
			}
			if queued < 0 {
				return fieldError("queued")
			}
			var deferred *string
			if err := nullable(entry, "deferred", &deferred); err != nil {
				return err
			}
		}
	case "agent_on", "agent_off":
		var message string
		return required(fields, "message", &message)
	case "create", "create_with_secret", "create_in", "rotate", "rotate_with_secret":
		if err := validateHook(fields["hook"]); err != nil {
			return err
		}
		var message string
		if err := required(fields, "message", &message); err != nil {
			return err
		}
		_, hasSecret := fields["secret"]
		if hasSecret || webhookGeneratesSecret(action, details) {
			var secret string
			if err := required(fields, "secret", &secret); err != nil {
				return err
			}
			if secret == "" {
				return fieldError("secret")
			}
		}
	case "signature", "enable", "disable", "delete":
		return validateHook(data)
	default:
		return errors.New("unsupported webhook action")
	}
	return nil
}
