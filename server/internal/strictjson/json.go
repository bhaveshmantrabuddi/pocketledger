// Package strictjson decodes finite JSON objects with an exact required schema.
package strictjson

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"unicode/utf8"
)

func Object(data []byte, target any, fields ...string) error {
	if !utf8.Valid(data) {
		return fmt.Errorf("JSON must use valid UTF-8")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return fmt.Errorf("expected a JSON object")
	}
	allowed := make(map[string]bool, len(fields))
	for _, field := range fields {
		allowed[field] = true
	}
	seen := make(map[string]bool, len(fields))
	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return fmt.Errorf("invalid JSON: %w", err)
		}
		name, ok := key.(string)
		if !ok || !allowed[name] {
			return fmt.Errorf("unknown field %q", key)
		}
		if seen[name] {
			return fmt.Errorf("duplicate field %q", name)
		}
		seen[name] = true
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return fmt.Errorf("invalid field %q: %w", name, err)
		}
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return fmt.Errorf("field %q cannot be null", name)
		}
	}
	if _, err := decoder.Token(); err != nil {
		return fmt.Errorf("invalid JSON: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return fmt.Errorf("expected exactly one JSON document")
	}
	for _, field := range fields {
		if !seen[field] {
			return fmt.Errorf("missing field %q", field)
		}
	}
	typed := json.NewDecoder(bytes.NewReader(data))
	typed.DisallowUnknownFields()
	if err := typed.Decode(target); err != nil {
		return fmt.Errorf("invalid field type: %w", err)
	}
	return nil
}
