package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"albedo/cli/internal/daemon/protocol"
)

// Binding keys are canonical JSON pointers. Reject ancestor assignments before
// resolving optional values so omission cannot make an ambiguous form valid.
func validateBodyBindings(bindings map[string]protocol.Binding) error {
	for pointer := range bindings {
		if !strings.HasPrefix(pointer, "/") {
			return errors.New("body binding keys must be JSON pointers")
		}
		for i := 0; i < len(pointer); i++ {
			switch pointer[i] {
			case '~':
				if i+1 == len(pointer) || pointer[i+1] != '0' && pointer[i+1] != '1' {
					return fmt.Errorf("invalid JSON pointer escape in %q", pointer)
				}
				i++
			case '/':
				if i > 0 {
					if _, exists := bindings[pointer[:i]]; exists {
						return errors.New("overlapping body bindings")
					}
				}
			}
		}
	}
	return nil
}

func bindingText(raw json.RawMessage) (string, error) {
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text, nil
	}
	var scalar any
	if json.Unmarshal(raw, &scalar) != nil {
		return "", errors.New("invalid binding value")
	}
	switch scalar.(type) {
	case bool, float64:
		return string(raw), nil
	}
	return "", errors.New("path, query, and header bindings require scalar values")
}
func resolveBinding(raw, row, form, session json.RawMessage) (json.RawMessage, error) {
	var binding struct {
		Source  string          `json:"source"`
		Value   json.RawMessage `json:"value"`
		Pointer string          `json:"pointer"`
	}
	if err := json.Unmarshal(raw, &binding); err != nil {
		return nil, err
	}
	switch binding.Source {
	case "literal":
		if binding.Value == nil {
			return nil, errors.New("literal binding requires a value")
		}
		return binding.Value, nil
	case "row":
		raw = row
	case "form":
		raw = form
	case "session":
		raw = session
	default:
		return nil, errors.New("unknown binding source")
	}
	if raw == nil {
		return nil, errors.New("action requires its displayed row or session")
	}
	if binding.Pointer == "" {
		return raw, nil
	}
	if !strings.HasPrefix(binding.Pointer, "/") {
		return nil, errors.New("invalid JSON pointer")
	}
	for token := range strings.SplitSeq(binding.Pointer[1:], "/") {
		token = strings.ReplaceAll(strings.ReplaceAll(token, "~1", "/"), "~0", "~")
		if len(raw) > 0 && raw[0] == '[' {
			var array []json.RawMessage
			if err := json.Unmarshal(raw, &array); err != nil {
				return nil, err
			}
			index, err := strconv.Atoi(token)
			if err != nil || index < 0 || index >= len(array) {
				return nil, errors.New("binding array index is missing")
			}
			raw = array[index]
		} else {
			var object map[string]json.RawMessage
			if err := json.Unmarshal(raw, &object); err != nil {
				return nil, errors.New("binding pointer does not name an object field")
			}
			var exists bool
			raw, exists = object[token]
			if !exists {
				if binding.Source == "form" {
					return nil, &missingFormBindingError{Field: token}
				}
				return nil, fmt.Errorf("binding field %q is missing", token)
			}
		}
	}
	return raw, nil
}
func setBodyPointer(root map[string]any, pointer string, value any) error {
	if !strings.HasPrefix(pointer, "/") {
		return errors.New("body binding keys must be JSON pointers")
	}
	tokens := strings.Split(pointer[1:], "/")
	current := root
	for i, token := range tokens {
		token = strings.ReplaceAll(strings.ReplaceAll(token, "~1", "/"), "~0", "~")
		if i == len(tokens)-1 {
			current[token] = value
			return nil
		}
		child, ok := current[token].(map[string]any)
		if !ok {
			if _, exists := current[token]; exists {
				return errors.New("overlapping body bindings")
			}
			child = map[string]any{}
			current[token] = child
		}
		current = child
	}
	return nil
}

type missingFormBindingError struct{ Field string }

func (e *missingFormBindingError) Error() string { return "form field " + e.Field + " is omitted" }
