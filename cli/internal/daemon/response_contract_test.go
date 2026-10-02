// Malformed mutation response combinations are client wire-parser invariants.
// A live daemon only emits valid shapes, so focused fixtures cover absent,
// nullable and conflicting fields that workflow scenarios cannot enumerate.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"slices"
	"strings"
	"testing"
)

type mutationFixture struct {
	Body   json.RawMessage `json:"body"`
	Status int             `json:"status"`
}

func mutationFixtures(t *testing.T) map[string]mutationFixture {
	t.Helper()
	data, err := os.ReadFile("../../../test/fixtures/mutation_responses.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtures map[string]mutationFixture
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	return fixtures
}

type mutationTransport struct {
	body   string
	calls  int
	status int
}

func (transport *mutationTransport) RoundTrip(*http.Request) (*http.Response, error) {
	transport.calls++
	return &http.Response{StatusCode: transport.status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(transport.body))}, nil
}
func mutationConnection(body string, status int) (*Connection, *mutationTransport) {
	conn := NewConnection(ConnectionSnapshot{Port: 12345}, nil)
	transport := &mutationTransport{body: body, status: status}
	conn.HTTPClient().Transport = transport
	return conn, transport
}

func TestMutationContracts(t *testing.T) {
	fixtures := mutationFixtures(t)
	decoders := map[string]func([]byte, int) error{
		"acknowledgement":   decodeAck,
		"submission":        func(data []byte, status int) error { _, err := decodeSubmission(data, status); return err },
		"interruption":      func(data []byte, status int) error { _, err := decodeInterruption(data, status); return err },
		"session":           func(data []byte, _ int) error { _, err := decodeSession(data); return err },
		"child":             func(data []byte, _ int) error { _, err := decodeChild(data); return err },
		"deletion":          func(data []byte, _ int) error { _, err := decodeDeletion(data); return err },
		"model":             func(data []byte, _ int) error { _, err := decodeModelSelection(data); return err },
		"extensions":        func(data []byte, _ int) error { _, err := decodeExtensions(data); return err },
		"reload_message":    func(data []byte, status int) error { _, err := decodeReload(data, status); return err },
		"reload_warning":    func(data []byte, status int) error { _, err := decodeReload(data, status); return err },
		"ui":                func(data []byte, status int) error { _, err := decodeUI(data, status); return err },
		"command_result":    func(data []byte, status int) error { _, err := decodeCommand(data, status); return err },
		"command_submitted": func(data []byte, status int) error { _, err := decodeCommand(data, status); return err },
	}
	contracts := []struct {
		name     string
		required []string
		nullable []string
		numeric  []string
	}{
		{"acknowledgement", []string{"ok"}, nil, nil},
		{"submission", []string{"ok", "queued"}, nil, nil},
		{"interruption", []string{"interrupted"}, nil, nil},
		{"session", []string{"id", "title", "workspace", "provider", "model", "effort", "protocol", "last_assistant_at"}, []string{"effort", "last_assistant_at"}, []string{"last_assistant_at"}},
		{"child", []string{"session", "member"}, nil, nil},
		{"deletion", []string{"ok", "deleted"}, nil, []string{"deleted"}},
		{"model", []string{"provider", "model", "protocol", "effort"}, []string{"effort"}, nil},
		{"extensions", []string{"name", "description", "quarantined", "tools", "python_modules", "requires", "plugins", "enabled", "context", "overridden", "global_enabled"}, []string{"quarantined"}, nil},
		{"reload_message", []string{"reloaded", "message"}, nil, nil},
		{"reload_warning", []string{"reloaded", "warning"}, nil, nil},
		{"ui", []string{"thinking", "tools", "pinned", "archived", "opens"}, nil, nil},
		{"command_result", []string{"result"}, []string{"result"}, []string{"result"}},
		{"command_submitted", []string{"submitted"}, nil, nil},
	}
	for _, contract := range contracts {
		t.Run(contract.name, func(t *testing.T) {
			fixture := fixtures[contract.name]
			decode := decoders[contract.name]
			if err := decode(fixture.Body, fixture.Status); err != nil {
				t.Fatalf("valid fixture: %v", err)
			}
			for _, body := range []string{"", "{", "null", "[]", "42", "{}"} {
				if contract.name == "extensions" && body == "[]" {
					continue
				}
				if err := decode([]byte(body), fixture.Status); err == nil {
					t.Errorf("accepted %s", body)
				}
			}
			var fields map[string]json.RawMessage
			raw := fixture.Body
			if contract.name == "extensions" {
				var entries []json.RawMessage
				if err := json.Unmarshal(raw, &entries); err != nil {
					t.Fatal(err)
				}
				raw = entries[0]
			}
			if err := json.Unmarshal(raw, &fields); err != nil {
				t.Fatal(err)
			}
			encode := func() []byte {
				body, err := json.Marshal(fields)
				if err != nil {
					t.Fatal(err)
				}
				if contract.name == "extensions" {
					body = append(append([]byte{'['}, body...), ']')
				}
				return body
			}
			for _, key := range contract.required {
				t.Run(key, func(t *testing.T) {
					original := fields[key]
					delete(fields, key)
					if err := decode(encode(), fixture.Status); err == nil {
						t.Error("accepted missing field")
					}
					fields[key] = json.RawMessage("null")
					if err := decode(encode(), fixture.Status); (err == nil) != slices.Contains(contract.nullable, key) {
						t.Errorf("nullable contract: %v", err)
					}
					fields[key] = json.RawMessage("42")
					if err := decode(encode(), fixture.Status); (err == nil) != slices.Contains(contract.numeric, key) {
						t.Errorf("numeric contract: %v", err)
					}
					fields[key] = original
				})
			}
		})
	}
}

func TestInvalidCoveredMutationRetainsHandleAfterOneReplay(t *testing.T) {
	for _, test := range []struct {
		body   string
		status int
	}{{"{}", 202}, {`{"ok":false,"queued":false}`, 202}, {`{"ok":true}`, 202}, {`{"ok":true,"queued":null}`, 202}, {`{"ok":true,"queued":false}`, 200}, {"", 204}, {"{", 202}, {`{"ok":true,"queued":"false"}`, 202}} {
		conn, transport := mutationConnection(test.body, test.status)
		_, err := Submit(context.Background(), conn, "s", SubmissionRequest{Content: new("hello")})
		uncertainty, ok := errors.AsType[*UncertainOutcomeError](err)
		if !ok {
			t.Fatalf("missing uncertainty for %s/%d: %v", test.body, test.status, err)
		}
		protocol, ok := errors.AsType[*ProtocolError](uncertainty)
		if !ok || protocol.Code != "invalid_response" || protocol.Operation != "submit message" || protocol.Cause == nil {
			t.Fatalf("missing protocol details: %v", err)
		}
		if strings.Contains(test.body, `"queued":"false"`) && protocol.Field != "queued" {
			t.Fatalf("missing known field: %+v", protocol)
		}
		if transport.calls != 4 {
			t.Fatalf("want two posts and two receipt queries, got %d requests", transport.calls)
		}
		if uncertainty.Handle == nil || uncertainty.Handle.ID() == "" {
			t.Fatal("lost operation handle")
		}
	}
	conn, transport := mutationConnection(`{"code":"invalid_submission","error":"bad"}`, 400)
	_, err := Submit(context.Background(), conn, "s", SubmissionRequest{})
	if api, ok := errors.AsType[*APIError](err); !ok || api.Code != "invalid_submission" {
		t.Fatalf("non-2xx error changed: %v", err)
	}
	if _, ok := errors.AsType[*UncertainOutcomeError](err); ok {
		t.Fatal("400 wrapped as uncertain")
	}
	if transport.calls != 1 {
		t.Fatal("400 retried")
	}
}

func TestCommandAlternativesAndOpaqueResults(t *testing.T) {
	for _, result := range []string{"null", "false", "42", `"text"`, "[]", `{"message":42}`, "{}", "9007199254740993", "1.0000000000000001", "1e400", `{"nested":[9007199254740993,1.0000000000000001]}`} {
		conn, transport := mutationConnection(`{"result":`+result+`}`, 200)
		got, err := ExecuteCommand(context.Background(), conn, "s", CommandRequest{Name: "/extension"})
		if err != nil || got.Submitted || string(got.Result) != result {
			t.Fatalf("opaque %s: %+v %v", result, got, err)
		}
		if transport.calls != 1 {
			t.Fatal("replayed")
		}
	}
	for _, test := range []struct {
		body   string
		status int
	}{{`{"result":null,"submitted":null}`, 200}, {`{"result":null,"submitted":false}`, 200}, {`{"submitted":false}`, 202}, {`{"submitted":null}`, 202}, {`{"submitted":true,"result":null}`, 202}} {
		if _, err := decodeCommand([]byte(test.body), test.status); err == nil {
			t.Errorf("accepted conflicting command %s", test.body)
		}
	}
}

func TestMutationCollectionsRejectNullEntries(t *testing.T) {
	fixture := mutationFixtures(t)["extensions"]
	var entries []map[string]any
	if err := json.Unmarshal(fixture.Body, &entries); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"tools", "python_modules", "requires", "plugins"} {
		entries[0][key] = []any{nil}
		data, _ := json.Marshal(entries)
		if _, err := decodeExtensions(data); err == nil {
			t.Errorf("accepted null in %s", key)
		}
		entries[0][key] = []any{}
	}
	if _, err := decodeUI([]byte(`{"thinking":false,"tools":false,"pinned":[],"archived":[],"opens":{"s":null}}`), 200); err == nil {
		t.Fatal("accepted null open count")
	}
}

func TestAuthMutationContracts(t *testing.T) {
	fixtures := mutationFixtures(t)
	for _, family := range []string{"sign_in", "migration"} {
		t.Run(family, func(t *testing.T) {
			fixture := fixtures[family]
			call := func(body string) error {
				conn, transport := mutationConnection(body, fixture.Status)
				var err error
				if family == "sign_in" {
					_, err = StartSignIn(context.Background(), conn, "offline")
				} else {
					_, err = TakeMigration(context.Background(), conn)
				}
				if transport.calls != 1 {
					t.Fatal("mutation replayed")
				}
				return err
			}
			if err := call(string(fixture.Body)); err != nil {
				t.Fatal(err)
			}
			malformed := []string{"", "{", "null", "[]", "{}"}
			if family == "sign_in" {
				malformed = append(malformed, `{"id":null,"url":"https://example.com"}`, `{"id":"","url":"https://example.com"}`, `{"id":42,"url":"https://example.com"}`, `{"id":"login","url":null}`, `{"id":"login","url":"/relative"}`, `{"id":"login","url":"https:"}`, `{"id":"login","url":"javascript:alert(1)"}`)
			} else {
				malformed = append(malformed, `{"moved":null}`, `{"moved":"file"}`, `{"moved":[null]}`, `{"moved":[42]}`)
			}
			for _, body := range malformed {
				err := call(body)
				if _, ok := errors.AsType[*ProtocolError](err); !ok {
					t.Errorf("expected invalid_response for %s: %v", body, err)
				}
				if _, ok := errors.AsType[*UncertainOutcomeError](err); !ok {
					t.Errorf("missing uncertainty for %s", body)
				}
			}
		})
	}
}

func TestSessionNullableFields(t *testing.T) {
	sessionFixture := mutationFixtures(t)["session"]
	var sessionFields map[string]json.RawMessage
	if err := json.Unmarshal(sessionFixture.Body, &sessionFields); err != nil {
		t.Fatal(err)
	}
	sessionFields["effort"] = json.RawMessage(`"high"`)
	sessionFields["last_assistant_at"] = json.RawMessage(`42`)
	sessionData, _ := json.Marshal(sessionFields)
	session, err := decodeSession(sessionData)
	if err != nil || session.Effort != "high" || session.LastAssistantAt == nil || *session.LastAssistantAt != 42 {
		t.Fatalf("present nullable session values rejected: %+v %v", session, err)
	}
}

func TestChildMemberCompleteness(t *testing.T) {
	fixture := mutationFixtures(t)["child"]
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(fixture.Body, &fields); err != nil {
		t.Fatal(err)
	}
	var member map[string]json.RawMessage
	if err := json.Unmarshal(fields["member"], &member); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"session", "parent", "name", "depth", "closed"} {
		value := member[key]
		delete(member, key)
		fields["member"], _ = json.Marshal(member)
		body, _ := json.Marshal(fields)
		if _, err := decodeChild(body); err == nil {
			t.Errorf("accepted child member without %s", key)
		}
		member[key] = value
	}
}

func TestDeletionRequiresPositiveIntegerCount(t *testing.T) {
	for _, body := range []string{`{"ok":true,"deleted":0}`, `{"ok":true,"deleted":-1}`, `{"ok":true,"deleted":1.5}`, `{"ok":false,"deleted":1}`} {
		if _, err := decodeDeletion([]byte(body)); err == nil {
			t.Errorf("accepted deletion %s", body)
		}
	}
}

func TestReloadRequiresOneOutcome(t *testing.T) {
	for _, body := range []string{`{"reloaded":"session","message":"done","warning":"partial"}`, `{"reloaded":"other","message":"done"}`, `{"reloaded":"session","warning":null}`} {
		if _, err := decodeReload([]byte(body), 200); err == nil {
			t.Errorf("accepted reload %s", body)
		}
	}
}

func TestInterpretedCommandContracts(t *testing.T) {
	for _, test := range []struct {
		name   string
		result string
	}{
		{"/model", `{"model":"selected"}`},
		{"/effort", `{"effort":null,"available":[null],"message":"levels"}`},
		{"/webhooks", `{"session":"s","agentManagement":false,"hooks":[{}]}`},
		{"/page", `{"page":{"title":"title","summary":"","empty":"","rows":[{"id":"i","text":"t","badge":"","tone":"plain"}],"actions":[],"glance":null}}`},
	} {
		conn, transport := mutationConnection(`{"result":`+test.result+`}`, 200)
		var err error
		if test.name == "/page" {
			_, err = LoadPage(context.Background(), conn, "s", test.name)
		} else {
			_, err = ExecuteCommand(context.Background(), conn, "s", CommandRequest{Name: test.name})
		}
		if _, ok := errors.AsType[*ProtocolError](err); !ok {
			t.Errorf("accepted interpreted %s result: %v", test.name, err)
		}
		if transport.calls != 1 {
			t.Fatal("replayed interpreted command")
		}
	}
	for _, body := range []CommandRequest{{Name: "/effort", Args: &CommandArgs{Level: "high"}}, {Name: "/effort", Arguments: "high"}} {
		conn, _ := mutationConnection(`{"result":{"effort":"high","message":"set"}}`, 200)
		result, err := ExecuteCommand(context.Background(), conn, "s", body)
		if err != nil || result.Effort == nil || result.Effort.Effort != "high" {
			t.Fatalf("effort selection rejected: %+v %v", result, err)
		}
	}
	conn, _ := mutationConnection(`{"result":{"message":"enabled"}}`, 200)
	result, err := ExecuteCommand(context.Background(), conn, "s", CommandRequest{Name: "/webhooks", Arguments: "agent_on"})
	if err != nil || result.Webhooks == nil || result.Webhooks.Message != "enabled" || result.Message != "enabled" {
		t.Fatalf("webhook raw arguments rejected: %+v %v", result, err)
	}
}
