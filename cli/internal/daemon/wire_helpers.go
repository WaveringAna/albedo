package daemon

import (
	"encoding/json"
	"errors"
	"net/http"
	"reflect"
	"strings"
	"time"
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
	fields, err := object(data)
	if err != nil {
		return err
	}
	for _, name := range names {
		if _, ok := fields[name]; !ok {
			return fieldError(name)
		}
	}
	targetType := reflect.TypeOf(target)
	if targetType.Kind() == reflect.Pointer {
		targetType = targetType.Elem()
	}
	if strings.HasPrefix(targetType.Name(), "wire") {
		if err := validateWireFields(fields, targetType); err != nil {
			return err
		}
	}
	return json.Unmarshal(data, target)
}

// Required wire members must be present, and JSON null cannot masquerade as a
// scalar zero value. Nullable fields have pointer types in the wire structs.
func validateWireJSON(data []byte, kind reflect.Type) error {
	if kind == reflect.TypeFor[json.RawMessage]() {
		return nil
	}
	if kind.Kind() == reflect.Pointer {
		if string(data) == "null" {
			return nil
		}
		return validateWireJSON(data, kind.Elem())
	}
	if string(data) == "null" {
		return fieldError("null " + kind.String())
	}
	switch kind.Kind() {
	case reflect.Struct:
		fields, err := object(data)
		if err != nil {
			return err
		}
		return validateWireFields(fields, kind)
	case reflect.Slice:
		var items []json.RawMessage
		if err := json.Unmarshal(data, &items); err != nil {
			return err
		}
		for _, item := range items {
			if err := validateWireJSON(item, kind.Elem()); err != nil {
				return err
			}
		}
	case reflect.Map:
		fields, err := object(data)
		if err != nil {
			return err
		}
		for _, raw := range fields {
			if err := validateWireJSON(raw, kind.Elem()); err != nil {
				return err
			}
		}
	}
	return nil
}

func validateWireFields(fields map[string]json.RawMessage, kind reflect.Type) error {
	for i := range kind.NumField() {
		field := kind.Field(i)
		name, options, _ := strings.Cut(field.Tag.Get("json"), ",")
		if name == "" || name == "-" {
			continue
		}
		raw, ok := fields[name]
		if !ok {
			if !strings.Contains(options, "omitempty") {
				return fieldError(name)
			}
			continue
		}
		if string(raw) == "null" && field.Tag.Get("nullable") == "true" {
			continue
		}
		if err := validateWireJSON(raw, field.Type); err != nil {
			return fmtField(name, err)
		}
	}
	return nil
}
func fmtField(name string, err error) error { return errors.New(name + ": " + err.Error()) }
