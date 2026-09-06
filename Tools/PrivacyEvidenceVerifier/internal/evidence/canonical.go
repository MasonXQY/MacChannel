package evidence

import (
	"bytes"
	"encoding/json"
	"io"
	"regexp"
)

var unsignedInteger = regexp.MustCompile(`^(0|[1-9][0-9]*)$`)

func ParseCanonical(raw []byte, maxBytes int) (map[string]any, *Failure) {
	if maxBytes < 0 || len(raw) > maxBytes || len(raw) == 0 || !restrictedASCII(raw) {
		return nil, schemaFailure()
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	value, ok := consumeValue(decoder, 1)
	if !ok {
		return nil, schemaFailure()
	}
	object, ok := value.(map[string]any)
	if !ok {
		return nil, schemaFailure()
	}
	if _, err := decoder.Token(); err != io.EOF || !canonicalEqual(raw, object) {
		return nil, schemaFailure()
	}
	return object, nil
}

func restrictedASCII(raw []byte) bool {
	inString := false
	for _, b := range raw {
		if b < 0x20 || b > 0x7e || b == '\\' {
			return false
		}
		if b == '"' {
			inString = !inString
			continue
		}
		if !inString && (b == ' ' || b == '\t' || b == '\r' || b == '\n') {
			return false
		}
	}
	return !inString
}

func consumeValue(decoder *json.Decoder, depth int) (any, bool) {
	token, err := decoder.Token()
	if err != nil {
		return nil, false
	}
	switch value := token.(type) {
	case nil:
		return nil, false
	case bool, string:
		return value, true
	case json.Number:
		if !unsignedInteger.MatchString(value.String()) {
			return nil, false
		}
		return value, true
	case json.Delim:
		if depth > 8 {
			return nil, false
		}
		switch value {
		case '{':
			object := make(map[string]any)
			previous := ""
			first := true
			for decoder.More() {
				keyToken, err := decoder.Token()
				key, isString := keyToken.(string)
				if err != nil || !isString || (!first && key <= previous) {
					return nil, false
				}
				child, ok := consumeValue(decoder, depth+1)
				if !ok {
					return nil, false
				}
				object[key] = child
				previous, first = key, false
			}
			end, err := decoder.Token()
			if err != nil || end != json.Delim('}') {
				return nil, false
			}
			return object, true
		case '[':
			array := make([]any, 0)
			for decoder.More() {
				child, ok := consumeValue(decoder, depth+1)
				if !ok {
					return nil, false
				}
				array = append(array, child)
			}
			end, err := decoder.Token()
			if err != nil || end != json.Delim(']') {
				return nil, false
			}
			return array, true
		}
	}
	return nil, false
}

func canonicalEqual(raw []byte, value map[string]any) bool {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if encoder.Encode(value) != nil {
		return false
	}
	encoded := buffer.Bytes()
	return len(encoded) > 0 && bytes.Equal(raw, encoded[:len(encoded)-1])
}

func schemaFailure() *Failure { return &Failure{Category: InvalidSchema} }
