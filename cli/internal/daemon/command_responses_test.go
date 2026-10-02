// These wire-parser tests catch numeric rounding and missing generated secrets
// that a healthy daemon cannot emit. Workflow fault tests cover durable effects.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

func webhookReceipt(revision, secretField string) string {
	return fmt.Sprintf(`{"result":{"hook":{"id":"h","session":"s","name":"notes","url":"/webhooks/h","signatureHeader":"x-albedo-signature","signaturePrefix":"sha256=","revision":%s,"enabled":true},"message":"created"%s}}`, revision, secretField)
}

func TestWebhookRevisionRejectsFractionalWireValue(t *testing.T) {
	for _, revision := range []string{"1.0000000000000001", "1.5"} {
		t.Run(revision, func(t *testing.T) {
			conn, transport := mutationConnection(webhookReceipt(revision, `,"secret":"generated"`), 200)
			result, err := ExecuteCommand(context.Background(), conn, "s", CommandRequest{
				Name: "/webhooks", Args: &CommandArgs{Action: "create", Details: "notes"},
			})
			uncertainty, ok := errors.AsType[*UncertainOutcomeError](err)
			if !ok {
				t.Fatalf("missing uncertainty: %v", err)
			}
			protocol, ok := errors.AsType[*ProtocolError](uncertainty)
			if !ok || protocol.Field != "revision" {
				t.Fatalf("missing revision protocol error: %v", err)
			}
			if result.Webhooks != nil || transport.calls != 1 {
				t.Fatalf("unconfirmed webhook or replay: %+v, calls=%d", result.Webhooks, transport.calls)
			}
		})
	}
}

func TestCreateInGeneratedSecretRequired(t *testing.T) {
	requests := map[string]CommandRequest{
		"declared": {Name: "/webhooks", Args: &CommandArgs{Action: "create_in", Details: " s notes "}},
		"raw":      {Name: "/webhooks", Arguments: " create_in s notes "},
	}
	for name, body := range requests {
		t.Run(name, func(t *testing.T) {
			for _, secretField := range []string{"", `,"secret":null`, `,"secret":""`, `,"secret":false`} {
				conn, transport := mutationConnection(webhookReceipt("1", secretField), 200)
				result, err := ExecuteCommand(context.Background(), conn, "s", body)
				uncertainty, ok := errors.AsType[*UncertainOutcomeError](err)
				if !ok {
					t.Fatalf("accepted generated receipt %s: %v", secretField, err)
				}
				protocol, ok := errors.AsType[*ProtocolError](uncertainty)
				if !ok || protocol.Code != "invalid_response" || protocol.Field != "secret" {
					t.Fatalf("missing protocol error: %v", err)
				}
				if result.Webhooks != nil || transport.calls != 1 {
					t.Fatalf("unconfirmed webhook or replay: %+v, calls=%d", result.Webhooks, transport.calls)
				}
			}
			conn, _ := mutationConnection(webhookReceipt("1", `,"secret":"generated"`), 200)
			result, err := ExecuteCommand(context.Background(), conn, "s", body)
			if err != nil || result.Webhooks == nil || result.Webhooks.Secret != "generated" {
				t.Fatalf("valid generated receipt rejected: %+v, %v", result.Webhooks, err)
			}
		})
	}
}

func TestCreateInSuppliedSecretReceipt(t *testing.T) {
	for name, body := range map[string]CommandRequest{
		"declared": {Name: "/webhooks", Args: &CommandArgs{Action: "create_in", Details: "s notes supplied-secret"}},
		"raw":      {Name: "/webhooks", Arguments: "create_in s notes supplied-secret"},
	} {
		t.Run(name, func(t *testing.T) {
			conn, transport := mutationConnection(webhookReceipt("1", ""), 200)
			result, err := ExecuteCommand(context.Background(), conn, "s", body)
			if err != nil || result.Webhooks == nil || result.Webhooks.Hook == nil || result.Webhooks.Secret != "" {
				t.Fatalf("supplied-secret receipt rejected: %+v, %v", result.Webhooks, err)
			}
			if result.Webhooks.Hook.Revision != 1 || transport.calls != 1 {
				t.Fatalf("receipt changed or replayed: %+v, calls=%d", result.Webhooks, transport.calls)
			}
		})
	}
}
