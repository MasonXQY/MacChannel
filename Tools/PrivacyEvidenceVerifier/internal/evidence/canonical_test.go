package evidence

import (
	"strings"
	"testing"
)

func TestCanonicalRejectsAmbiguity(t *testing.T) {
	cases := []string{
		`{"a":1,"a":2}`, `{"a":1.0}`, `{"a":-1}`, `{"a":01}`,
		`{"a":null}`, `{"a":"\u0061"}`, `{"b":1,"a":2}`, "{\"a\":1}\n",
		`[]`, `{"a":1} `, `{"a":1e2}`, `{"a":+1}`, `{"a":"é"}`,
	}
	for _, raw := range cases {
		if _, failure := ParseCanonical([]byte(raw), 65536); failure == nil {
			t.Errorf("ParseCanonical(%q) accepted ambiguous JSON", raw)
		}
	}
}

func TestCanonicalAcceptsRestrictedObject(t *testing.T) {
	if _, failure := ParseCanonical([]byte(`{"a":[0,true,"value"],"b":false}`), 65536); failure != nil {
		t.Fatalf("canonical JSON rejected: %v", failure)
	}
}

func TestCanonicalEnforcesBoundsAndDepth(t *testing.T) {
	if _, failure := ParseCanonical([]byte(`{"a":1}`), 6); failure == nil {
		t.Fatal("oversize JSON accepted")
	}
	deep := `{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":{}}}}}}}}}`
	if _, failure := ParseCanonical([]byte(deep), 65536); failure == nil {
		t.Fatal("JSON deeper than eight levels accepted")
	}
	atLimit := `{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":0}}}}}}}}`
	if _, failure := ParseCanonical([]byte(atLimit), 65536); failure != nil {
		t.Fatalf("JSON at eight container levels rejected: %v", failure)
	}
	if _, failure := ParseCanonical([]byte(`{"a":"`+strings.Repeat("x", 20)+`"}`), 65536); failure != nil {
		t.Fatalf("bounded canonical string rejected: %v", failure)
	}
}
