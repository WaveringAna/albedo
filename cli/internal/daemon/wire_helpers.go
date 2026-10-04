package daemon

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"reflect"
	"strings"
	"time"

	"albedo/cli/internal/daemon/protocol"
)

func value[T any](pointer *T) T {
	if pointer != nil {
		return *pointer
	}
	var zero T
	return zero
}
func timestampMilliseconds(value string) *int64 {
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return nil
	}
	ms := parsed.UnixMilli()
	return &ms
}
func timestampSeconds(value string) *int64 {
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return nil
	}
	seconds := parsed.Unix()
	return &seconds
}

func intPointer(value *int64) *int {
	if value == nil {
		return nil
	}
	n := int(*value)
	return &n
}
func observedHeaders(etag string) (http.Header, error) {
	if etag == "" {
		return nil, errors.New("this change requires the resource's observed ETag; refresh it first")
	}
	return http.Header{"If-Match": {etag}, "Content-Type": {"application/merge-patch+json"}}, nil
}
func decodeRequired(data []byte, target any, names ...string) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || data[0] != '{' {
		return fieldError("object")
	}
	kind := reflect.TypeOf(target).Elem()
	generated := kind.PkgPath() == reflect.TypeFor[protocol.Session]().PkgPath()
	if generated || len(names) > 0 {
		var tree any
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.UseNumber()
		if err := decoder.Decode(&tree); err != nil {
			return err
		}
		fields, ok := tree.(map[string]any)
		if !ok {
			return fieldError("object")
		}
		for _, name := range names {
			if _, ok := fields[name]; !ok {
				return fieldError(name)
			}
		}
		if generated {
			if err := validateWireValue(tree, kind); err != nil {
				return err
			}
		}
	}
	return json.Unmarshal(data, target)
}

// Validate one parsed tree so nested required members and nulls never become
// Go zero values. Raw unions are decoded by their discriminated adapters.
func validateWireValue(value any, kind reflect.Type) error {
	if kind == reflect.TypeFor[json.RawMessage]() {
		return nil
	}
	if kind.Kind() == reflect.Pointer {
		if value == nil {
			return nil
		}
		return validateWireValue(value, kind.Elem())
	}
	if value == nil {
		return fieldError("null " + kind.String())
	}
	switch kind.Kind() {
	case reflect.Struct:
		fields, ok := value.(map[string]any)
		if !ok {
			return fieldError("object")
		}
		for field := range kind.Fields() {
			name, options, _ := strings.Cut(field.Tag.Get("json"), ",")
			if name == "" || name == "-" {
				continue
			}
			child, present := fields[name]
			if !present {
				if !strings.Contains(options, "omitempty") {
					return fieldError(name)
				}
				continue
			}
			if child == nil && field.Type != reflect.TypeFor[json.RawMessage]() {
				if field.Tag.Get("nullable") != "true" {
					return fieldError(name)
				}
				continue
			}
			if err := validateWireValue(child, field.Type); err != nil {
				return fmtField(name, err)
			}
		}
	case reflect.Slice:
		items, ok := value.([]any)
		if !ok {
			return fieldError("array")
		}
		for _, item := range items {
			if err := validateWireValue(item, kind.Elem()); err != nil {
				return err
			}
		}
	case reflect.Map:
		fields, ok := value.(map[string]any)
		if !ok {
			return fieldError("object")
		}
		for _, child := range fields {
			if err := validateWireValue(child, kind.Elem()); err != nil {
				return err
			}
		}
	}
	return nil
}
func fmtField(name string, err error) error { return errors.New(name + ": " + err.Error()) }

// optionalText omits unset optional request fields.
func optionalText(text string) *string {
	if text == "" {
		return nil
	}
	return &text
}
