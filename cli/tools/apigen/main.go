// apigen derives Go wire types and HTTP requests from the daemon contract.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"strings"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/oapi-codegen/oapi-codegen/v2/pkg/codegen"
	"go.yaml.in/yaml/v3"
)

func main() {
	check := flag.Bool("check", false, "fail if generated code differs")
	flag.Parse()
	if err := generate(*check); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func generate(check bool) error {
	root := filepath.Join("..", "..", "..")
	data, err := os.ReadFile(filepath.Join(root, "docs", "openapi.yaml"))
	if err != nil {
		return err
	}
	var document map[string]any
	if err := yaml.Unmarshal(data, &document); err != nil {
		return err
	}
	// oapi-codegen supports 3.1. SSE item schemas stay in the canonical 3.2
	// document; the adapter owns framing, delivery and cursor recovery.
	document["openapi"] = "3.1.0"
	schemas := document["components"].(map[string]any)["schemas"].(map[string]any)
	for name, schema := range schemas {
		project(schema)
		if name == "DynamicJSON" {
			schema.(map[string]any)["x-go-type"] = "json.RawMessage"
		}
	}
	projectParameters(document["paths"])
	projectParameters(document["components"].(map[string]any)["parameters"])
	data, err = json.Marshal(document)
	if err != nil {
		return err
	}
	spec, err := openapi3.NewLoader().LoadFromData(data)
	if err != nil {
		return err
	}
	version := "v2.8.0"
	source, err := codegen.Generate(spec, codegen.Configuration{
		PackageName:   "protocol",
		Generate:      codegen.GenerateOptions{Models: true, Client: true},
		Compatibility: codegen.CompatibilityOptions{DisableRequiredReadOnlyAsPointer: true},
		OutputOptions: codegen.OutputOptions{
			SkipPrune:             true,
			SkipEnumValidate:      true,
			NameNormalizer:        "ToCamelCaseWithInitialisms",
			AdditionalInitialisms: []string{"UTF8", "TTL", "MCP", "HTTP", "JJ"},
			UserTemplates:         map[string]string{"client-with-responses.tmpl": "// Response decoding is owned by the daemon adapter.\n"},
		},
		NoVCSVersionOverride: &version,
	})
	if err != nil {
		return err
	}
	target := filepath.Join(root, "cli", "internal", "daemon", "protocol", "api.gen.go")
	if check {
		current, err := os.ReadFile(target)
		if err != nil {
			return err
		}
		if !bytes.Equal(current, []byte(source)) {
			return fmt.Errorf("generated API is stale; run go generate ./internal/daemon")
		}
		return nil
	}
	return os.WriteFile(target, []byte(source), 0644)
}

// project selects Go representations without changing the wire contract.
// Unions remain raw JSON for the adapter's discriminated decoding. Scalars
// keep their wire values; timestamps are parsed by the application adapter.
func project(value any) {
	switch node := value.(type) {
	case []any:
		for _, child := range node {
			project(child)
		}
	case map[string]any:
		for _, key := range []string{"properties", "$defs", "items", "prefixItems", "anyOf", "oneOf", "allOf", "additionalProperties"} {
			child := node[key]
			if key == "properties" || key == "$defs" {
				if members, ok := child.(map[string]any); ok {
					for _, member := range members {
						project(member)
					}
				}
			} else {
				project(child)
			}
		}
		if properties, ok := node["properties"].(map[string]any); ok {
			for name, child := range properties {
				property := child.(map[string]any)
				if name == "etag" {
					property["x-go-name"] = "ETag"
				}
				if baseName, hasIDsSuffix := strings.CutSuffix(name, "_ids"); hasIDsSuffix {
					property["x-go-name"] = codegen.ToCamelCaseWithInitialisms(baseName) + "IDs"
				}
				kind, _ := property["type"].(string)
				if kind == "array" || property["x-go-type"] == "json.RawMessage" || (kind == "object" && property["properties"] == nil) {
					property["x-go-type-skip-optional-pointer"] = true
				}
			}
		}
		if items, ok := node["items"].(bool); ok && !items {
			// Object-form false schema keeps the tuple restriction while
			// avoiding the loader's unsupported boolean items schema.
			node["items"] = map[string]any{"not": map[string]any{}}
		}
		if constant, ok := node["const"]; ok {
			switch constant.(type) {
			case string:
				node["type"] = "string"
			case int, int64:
				node["type"] = "integer"
			case bool:
				node["type"] = "boolean"
			}
		}
		kind, _ := node["type"].(string)
		nullable := kind == "null"
		if kinds, ok := node["type"].([]any); ok {
			for _, member := range kinds {
				if member == "null" {
					nullable = true
				}
			}
			if len(kinds) == 2 && nullable {
				for _, member := range kinds {
					if member != "null" {
						kind = member.(string)
					}
				}
			} else {
				node["x-go-type"] = "json.RawMessage"
			}
		}
		for _, keyword := range []string{"anyOf", "oneOf"} {
			members, ok := node[keyword].([]any)
			if !ok {
				continue
			}
			var nonnull []any
			for _, member := range members {
				if member.(map[string]any)["type"] == "null" {
					nullable = true
				} else {
					nonnull = append(nonnull, member)
				}
			}
			if len(nonnull) == 1 && nullable && nonnull[0].(map[string]any)["type"] == "array" {
				// Inline nullable arrays otherwise lose their array shape in
				// oapi-codegen's single-branch union handling.
				maps.Copy(node, nonnull[0].(map[string]any))
				node["type"] = []any{"array", "null"}
				delete(node, keyword)
				kind = "array"
			} else if node["properties"] != nil {
				delete(node, keyword)
			} else if len(nonnull) != 1 || !nullable {
				node["x-go-type"] = "json.RawMessage"
			}
		}
		switch kind {
		case "string":
			node["x-go-type"] = "string"
		case "integer":
			node["x-go-type"] = "int64"
		case "number":
			node["x-go-type"] = "float64"
		case "boolean":
			node["x-go-type"] = "bool"
		}
		if node["x-go-type"] == "json.RawMessage" {
			delete(node, "anyOf")
			delete(node, "oneOf")
			delete(node, "type")
			node["x-go-type-skip-optional-pointer"] = true
		}
		if kind == "array" {
			node["x-go-type-skip-optional-pointer"] = true
		}
		if nullable {
			node["x-oapi-codegen-extra-tags"] = map[string]any{"nullable": "true"}
		}
		if len(node) == 0 {
			node["x-go-type"] = "json.RawMessage"
		}

	}
}

func projectParameters(value any) {
	switch node := value.(type) {
	case []any:
		for _, child := range node {
			projectParameters(child)
		}
	case map[string]any:
		for key, child := range node {
			if key == "schema" || key == "itemSchema" {
				project(child)
			} else if key != "examples" && key != "example" {
				projectParameters(child)
			}
		}
	}
}
