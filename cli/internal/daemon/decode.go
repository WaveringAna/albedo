package daemon

import (
	"bytes"
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

func nullable(fields map[string]json.RawMessage, key string, target any) error {
	raw, ok := fields[key]
	if !ok {
		return fieldError(key)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return &responseFieldError{field: key, cause: err}
	}
	return nil
}

// stringCollection rejects null entries rather than decoding them as empty strings.
type stringCollection []string

func (values *stringCollection) UnmarshalJSON(data []byte) error {
	if bytes.Equal(bytes.TrimSpace(data), []byte("[]")) {
		*values = stringCollection{}
		return nil
	}
	var wire []*string
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	if wire == nil {
		return errors.New("expected a string array")
	}
	result := make(stringCollection, len(wire))
	for i, value := range wire {
		if value == nil {
			return errors.New("string array contains null")
		}
		result[i] = *value
	}
	*values = result
	return nil
}
