//go:build unix

// Live daemon responses must agree with the published contract. Adapter tests
// alone cannot detect fields that their decoder ignores or never reads.
package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
	"go.yaml.in/yaml/v3"
)

type wireContract struct {
	document map[string]any
	mu       sync.Mutex
	schemas  map[string]*jsonschema.Resolved
	failures []error
}

func loadWireContract(root string) (*wireContract, error) {
	data, err := os.ReadFile(filepath.Join(root, "docs", "openapi.yaml"))
	if err != nil {
		return nil, err
	}
	var document map[string]any
	if err := yaml.Unmarshal(data, &document); err != nil {
		return nil, err
	}
	return &wireContract{document: document, schemas: make(map[string]*jsonschema.Resolved)}, nil
}

func (contract *wireContract) dereference(value map[string]any) map[string]any {
	if reference, ok := value["$ref"].(string); ok {
		var current any = contract.document
		for _, part := range strings.Split(strings.TrimPrefix(reference, "#/"), "/") {
			current = current.(map[string]any)[strings.ReplaceAll(strings.ReplaceAll(part, "~1", "/"), "~0", "~")]
		}
		return current.(map[string]any)
	}
	return value
}

func schemaReferences(value any) any {
	switch value := value.(type) {
	case map[string]any:
		result := make(map[string]any, len(value))
		for key, child := range value {
			if key == "$ref" {
				result[key] = strings.Replace(child.(string), "#/components/schemas/", "#/$defs/", 1)
			} else {
				result[key] = schemaReferences(child)
			}
		}
		return result
	case []any:
		result := make([]any, len(value))
		for index, child := range value {
			result[index] = schemaReferences(child)
		}
		return result
	default:
		return value
	}
}

func (contract *wireContract) validate(schema map[string]any, value any) error {
	encoded, err := json.Marshal(schema)
	if err != nil {
		return err
	}
	key := string(encoded)
	contract.mu.Lock()
	resolved := contract.schemas[key]
	if resolved == nil {
		root := schemaReferences(schema).(map[string]any)
		root["$defs"] = schemaReferences(contract.document["components"].(map[string]any)["schemas"])
		root["$schema"] = "https://json-schema.org/draft/2020-12/schema"
		encoded, err = json.Marshal(root)
		var parsed jsonschema.Schema
		if err == nil {
			err = json.Unmarshal(encoded, &parsed)
		}
		if err == nil {
			resolved, err = parsed.Resolve(nil)
		}
		if err == nil {
			contract.schemas[key] = resolved
		}
	}
	contract.mu.Unlock()
	if err != nil {
		return err
	}
	return resolved.Validate(value)
}

func (contract *wireContract) responseSchema(request *http.Request, response *http.Response) (map[string]any, error) {
	paths := contract.document["paths"].(map[string]any)
	var operation map[string]any
	for path, definition := range paths {
		expected, actual := strings.Split(path, "/"), strings.Split(request.URL.Path, "/")
		if len(expected) != len(actual) {
			continue
		}
		matches := true
		for index, segment := range expected {
			if !strings.HasPrefix(segment, "{") && segment != actual[index] {
				matches = false
				break
			}
		}
		if matches {
			operation, _ = definition.(map[string]any)[strings.ToLower(request.Method)].(map[string]any)
			break
		}
	}
	if operation == nil {
		return nil, fmt.Errorf("undocumented operation %s %s", request.Method, request.URL.Path)
	}
	responses := operation["responses"].(map[string]any)
	definition, ok := responses[strconv.Itoa(response.StatusCode)].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("undocumented response %s", response.Status)
	}
	definition = contract.dereference(definition)
	content, ok := definition["content"].(map[string]any)
	if !ok {
		return nil, nil
	}
	mediaType := strings.Split(response.Header.Get("Content-Type"), ";")[0]
	media, ok := content[mediaType].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("undocumented response media type %q", mediaType)
	}
	if mediaType == "text/event-stream" {
		return contract.dereference(media["itemSchema"].(map[string]any)), nil
	}
	if mediaType != "application/json" && mediaType != "application/problem+json" {
		return nil, nil
	}
	schema, _ := media["schema"].(map[string]any)
	return schema, nil
}

func (contract *wireContract) record(request *http.Request, err error) {
	if err == nil {
		return
	}
	contract.mu.Lock()
	defer contract.mu.Unlock()
	contract.failures = append(contract.failures, fmt.Errorf("%s %s: %w", request.Method, request.URL.Path, err))
}

type contractTransport struct {
	upstream http.RoundTripper
	contract *wireContract
}

func (transport contractTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := transport.upstream.RoundTrip(request)
	if err != nil {
		return response, err
	}
	schema, err := transport.contract.responseSchema(request, response)
	transport.contract.record(request, err)
	if schema == nil || err != nil {
		return response, nil
	}
	response.Body = &contractBody{ReadCloser: response.Body, contract: transport.contract, request: request, schema: schema, stream: strings.HasPrefix(response.Header.Get("Content-Type"), "text/event-stream")}
	return response, nil
}

func (transport contractTransport) CloseIdleConnections() {
	if closer, ok := transport.upstream.(interface{ CloseIdleConnections() }); ok {
		closer.CloseIdleConnections()
	}
}

type contractBody struct {
	io.ReadCloser
	contract   *wireContract
	request    *http.Request
	schema     map[string]any
	pending    []byte
	stream     bool
	finished   bool
	frame      map[string]any
	data       []string
	frameBytes int
}

func (body *contractBody) check(data []byte) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	var value any
	err := decoder.Decode(&value)
	if err == nil {
		schema := body.schema
		if body.stream {
			data := schema["properties"].(map[string]any)["data"].(map[string]any)
			schema, _ = data["contentSchema"].(map[string]any)
			if schema == nil {
				for _, variant := range data["anyOf"].([]any) {
					if candidate, ok := variant.(map[string]any)["contentSchema"].(map[string]any); ok {
						schema = candidate
						break
					}
				}
			}
		}
		err = body.contract.validate(schema, value)
	}
	body.contract.record(body.request, err)
}

// Parse the envelope as well as its JSON payload. Data lines join with newline;
// comments are legal, while fields forbidden by the contract remain visible.
func (body *contractBody) streamLine(line []byte) {
	body.frameBytes += len(line) + 1
	if body.frameBytes > 1<<20 {
		body.contract.record(body.request, fmt.Errorf("SSE frame exceeds 1 MiB"))
		body.pending, body.frame, body.data, body.finished = nil, nil, nil, true
		return
	}
	if len(line) == 0 {
		if len(body.data) != 0 {
			body.frame["data"] = strings.Join(body.data, "\n")
		}
		if len(body.frame) != 0 {
			body.contract.record(body.request, body.contract.validate(body.schema, body.frame))
			if data, ok := body.frame["data"].(string); ok && data != "[DONE]" {
				body.check([]byte(data))
			}
		}
		body.frame, body.data, body.frameBytes = nil, nil, 0
		return
	}
	if line[0] == ':' {
		return
	}
	name, value, _ := bytes.Cut(line, []byte(":"))
	value = bytes.TrimPrefix(value, []byte(" "))
	if body.frame == nil {
		body.frame = make(map[string]any)
	}
	if string(name) == "data" {
		body.data = append(body.data, string(value))
	} else {
		body.frame[string(name)] = string(value)
	}
}

func (body *contractBody) Read(target []byte) (int, error) {
	count, err := body.ReadCloser.Read(target)
	if !body.finished {
		body.pending = append(body.pending, target[:count]...)
		if len(body.pending) > 1<<20 {
			body.contract.record(body.request, fmt.Errorf("response or SSE frame exceeds 1 MiB"))
			body.pending, body.finished = nil, true
		} else if body.stream {
			for {
				line, remaining, found := bytes.Cut(body.pending, []byte("\n"))
				if !found {
					break
				}
				body.streamLine(bytes.TrimSuffix(line, []byte("\r")))
				if body.finished {
					break
				}
				body.pending = remaining
			}
		} else if err == io.EOF {
			body.check(body.pending)
			body.pending, body.finished = nil, true
		}
	}
	return count, err
}

func (body *contractBody) Close() error {
	if !body.stream && !body.finished && json.Valid(body.pending) {
		body.check(body.pending)
		body.finished = true
	}
	return body.ReadCloser.Close()
}

func TestOpenAPIRejectsDriftInRealDaemonResponse(t *testing.T) {
	response, err := conn(t).HTTPClient().Get(conn(t).BaseURL() + "/server")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	// This deliberate unauthenticated request is a real problem representation.
	var problem map[string]any
	if err := json.NewDecoder(response.Body).Decode(&problem); err != nil {
		t.Fatal(err)
	}
	schema, err := suite.contract.responseSchema(response.Request, response)
	if err != nil {
		t.Fatal(err)
	}
	if err := suite.contract.validate(schema, problem); err != nil {
		t.Fatal(err)
	}
	delete(problem, "code")
	if err := suite.contract.validate(schema, problem); err == nil {
		t.Fatal("contract accepted a problem missing its required code")
	}
}
