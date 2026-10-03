package daemon

import (
	"encoding/json"
	"errors"
)

func object(data []byte) (map[string]json.RawMessage, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return nil, err
	}
	if fields == nil {
		return nil, errors.New("expected an object")
	}
	return fields, nil
}

func required(fields map[string]json.RawMessage, key string, target any) error {
	raw, ok := fields[key]
	if !ok || string(raw) == "null" {
		return fieldError(key)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return &responseFieldError{field: key, cause: err}
	}
	return nil
}
