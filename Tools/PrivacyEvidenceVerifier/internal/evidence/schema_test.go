package evidence

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
)

const hash40 = "0123456789abcdef0123456789abcdef01234567"
const hash64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func validManifestMap() map[string]any {
	names := RequiredArtifactNames()
	artifacts := make([]any, len(names))
	for i, name := range names {
		artifacts[i] = map[string]any{"complete": true, "name": name, "sha256": hash64, "size": json.Number("1")}
	}
	return map[string]any{
		"artifacts": artifacts, "canaryID": "canary-123456789", "captureEndUTC": "2026-09-07T10:00:00Z",
		"captureStartUTC": "2026-09-07T09:00:00Z", "clientArchiveSHA256": hash64, "codeCommit": hash40,
		"containerIDs": []any{hash64}, "destinationSHA256": hash64, "endUTC": "2026-09-07T09:30:00Z",
		"evidenceClass": "synthetic-fixture", "route": "relay", "schemaVersion": json.Number("1"),
		"serverCommit": hash40, "serverImageSHA256": hash64, "signerID": "test-signer", "sourceSHA256": hash64,
		"startUTC": "2026-09-07T09:10:00Z", "transferID": "123e4567-e89b-12d3-a456-426614174000",
	}
}

func validReceiptMap() map[string]any {
	m := validManifestMap()
	return map[string]any{
		"clientArchiveSHA256": m["clientArchiveSHA256"], "codeCommit": m["codeCommit"], "completed": true,
		"containerIDs": m["containerIDs"], "destinationSHA256": m["destinationSHA256"], "endUTC": m["endUTC"],
		"route": m["route"], "serverCommit": m["serverCommit"], "serverImageSHA256": m["serverImageSHA256"],
		"sourceSHA256": m["sourceSHA256"], "startUTC": m["startUTC"], "transferID": m["transferID"],
	}
}

func validPolicyMap() map[string]any {
	return map[string]any{"keys": []any{map[string]any{
		"id": "test-signer", "notAfterUTC": "2026-09-08T00:00:00Z", "notBeforeUTC": "2026-09-06T00:00:00Z",
		"publicKeyHex": strings.Repeat("ab", 32), "revoked": false,
	}}, "schemaVersion": json.Number("1")}
}

func cloneMap(t *testing.T, value map[string]any) map[string]any {
	t.Helper()
	b, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(strings.NewReader(string(b)))
	decoder.UseNumber()
	var cloned map[string]any
	if err := decoder.Decode(&cloned); err != nil {
		t.Fatal(err)
	}
	return cloned
}

func TestManifestRequiresExactFieldsAndTypes(t *testing.T) {
	valid := validManifestMap()
	if _, failure := ParseManifest(valid); failure != nil {
		t.Fatalf("valid manifest rejected: %v", failure)
	}
	for field := range valid {
		candidate := cloneMap(t, valid)
		delete(candidate, field)
		if _, failure := ParseManifest(candidate); failure == nil {
			t.Errorf("missing field %q accepted", field)
		}
	}
	candidate := cloneMap(t, valid)
	candidate["unknown"] = true
	if _, failure := ParseManifest(candidate); failure == nil {
		t.Error("unknown field accepted")
	}
	for _, field := range []string{"canaryID", "captureEndUTC", "captureStartUTC", "clientArchiveSHA256", "codeCommit", "destinationSHA256", "endUTC", "evidenceClass", "route", "serverCommit", "serverImageSHA256", "signerID", "sourceSHA256", "startUTC", "transferID"} {
		candidate := cloneMap(t, valid)
		candidate[field] = true
		if _, failure := ParseManifest(candidate); failure == nil {
			t.Errorf("boolean %q accepted", field)
		}
	}
	candidate = cloneMap(t, valid)
	candidate["schemaVersion"] = "1"
	if _, failure := ParseManifest(candidate); failure == nil {
		t.Error("string integer accepted")
	}
}

func TestManifestRejectsInvalidValues(t *testing.T) {
	tests := map[string]func(map[string]any){
		"version zero":         func(m map[string]any) { m["schemaVersion"] = json.Number("0") },
		"version nine":         func(m map[string]any) { m["schemaVersion"] = json.Number("9") },
		"unknown route":        func(m map[string]any) { m["route"] = "lan" },
		"uppercase hash":       func(m map[string]any) { m["codeCommit"] = strings.ToUpper(hash40) },
		"short hash":           func(m map[string]any) { m["sourceSHA256"] = hash64[:63] },
		"invalid uuid":         func(m map[string]any) { m["transferID"] = "NOT-A-UUID" },
		"non UTC":              func(m map[string]any) { m["startUTC"] = "2026-09-07T09:10:00+00:00" },
		"fractional date":      func(m map[string]any) { m["endUTC"] = "2026-09-07T09:30:00.000Z" },
		"duplicate containers": func(m map[string]any) { m["containerIDs"] = []any{hash64, hash64} },
		"unsorted containers":  func(m map[string]any) { m["containerIDs"] = []any{strings.Repeat("b", 64), strings.Repeat("a", 64)} },
		"incomplete artifact":  func(m map[string]any) { m["artifacts"].([]any)[0].(map[string]any)["complete"] = false },
		"string size":          func(m map[string]any) { m["artifacts"].([]any)[0].(map[string]any)["size"] = "1" },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			m := cloneMap(t, validManifestMap())
			mutate(m)
			if _, failure := ParseManifest(m); failure == nil {
				t.Fatal("invalid manifest accepted")
			}
		})
	}
}

func TestManifestRequiresExactSortedArtifactInventory(t *testing.T) {
	for _, mutate := range []func([]any) []any{
		func(a []any) []any { return a[1:] },
		func(a []any) []any {
			return append(a, map[string]any{"complete": true, "name": "extra", "sha256": hash64, "size": json.Number("1")})
		},
		func(a []any) []any { a[0], a[1] = a[1], a[0]; return a },
	} {
		m := cloneMap(t, validManifestMap())
		m["artifacts"] = mutate(m["artifacts"].([]any))
		if _, failure := ParseManifest(m); failure == nil {
			t.Error("invalid artifact inventory accepted")
		}
	}
	if got := RequiredArtifactNames(); !slices.IsSorted(got) {
		t.Fatal("required names are not sorted")
	}
}

func TestPolicyRequiresExactShapeUniqueIDsAndTypedBooleans(t *testing.T) {
	if _, failure := ParsePolicy(validPolicyMap()); failure != nil {
		t.Fatalf("valid policy rejected: %v", failure)
	}
	for _, count := range []int{0, 9} {
		p := cloneMap(t, validPolicyMap())
		keys := make([]any, count)
		for i := range keys {
			k := cloneMap(t, validPolicyMap()["keys"].([]any)[0].(map[string]any))
			k["id"] = "key-" + string(rune('a'+i))
			keys[i] = k
		}
		p["keys"] = keys
		if _, failure := ParsePolicy(p); failure == nil {
			t.Errorf("%d keys accepted", count)
		}
	}
	p := cloneMap(t, validPolicyMap())
	p["keys"] = append(p["keys"].([]any), cloneMap(t, p["keys"].([]any)[0].(map[string]any)))
	if _, failure := ParsePolicy(p); failure == nil {
		t.Error("duplicate key IDs accepted")
	}
	p = cloneMap(t, validPolicyMap())
	p["keys"].([]any)[0].(map[string]any)["revoked"] = "false"
	if _, failure := ParsePolicy(p); failure == nil {
		t.Error("string revoked accepted")
	}
}

func TestPolicyRejectsMissingUnknownAndInvalidKeyFields(t *testing.T) {
	valid := validPolicyMap()
	for field := range valid {
		candidate := cloneMap(t, valid)
		delete(candidate, field)
		if _, failure := ParsePolicy(candidate); failure == nil {
			t.Errorf("missing policy field %q accepted", field)
		}
	}
	candidate := cloneMap(t, valid)
	candidate["unknown"] = true
	if _, failure := ParsePolicy(candidate); failure == nil {
		t.Error("unknown policy field accepted")
	}
	key := valid["keys"].([]any)[0].(map[string]any)
	for field := range key {
		candidate = cloneMap(t, valid)
		delete(candidate["keys"].([]any)[0].(map[string]any), field)
		if _, failure := ParsePolicy(candidate); failure == nil {
			t.Errorf("missing key field %q accepted", field)
		}
	}
	mutations := map[string]any{
		"id":           "Uppercase",
		"publicKeyHex": strings.ToUpper(strings.Repeat("ab", 32)),
		"notBeforeUTC": "2026-09-06T00:00:00+00:00",
		"notAfterUTC":  true,
	}
	for field, value := range mutations {
		candidate = cloneMap(t, valid)
		candidate["keys"].([]any)[0].(map[string]any)[field] = value
		if _, failure := ParsePolicy(candidate); failure == nil {
			t.Errorf("invalid key field %q accepted", field)
		}
	}
}

func TestReceiptRequiresExactShapeAndCompletedTrue(t *testing.T) {
	valid := validReceiptMap()
	if _, failure := ParseReceipt(valid); failure != nil {
		t.Fatalf("valid receipt rejected: %v", failure)
	}
	for field := range valid {
		candidate := cloneMap(t, valid)
		delete(candidate, field)
		if _, failure := ParseReceipt(candidate); failure == nil {
			t.Errorf("missing %q accepted", field)
		}
	}
	for _, completed := range []any{false, "true"} {
		candidate := cloneMap(t, valid)
		candidate["completed"] = completed
		if _, failure := ParseReceipt(candidate); failure == nil {
			t.Errorf("completed=%v accepted", completed)
		}
	}
	candidate := cloneMap(t, valid)
	candidate["unknown"] = true
	if _, failure := ParseReceipt(candidate); failure == nil {
		t.Error("unknown receipt field accepted")
	}
	for _, field := range []string{"clientArchiveSHA256", "codeCommit", "destinationSHA256", "endUTC", "route", "serverCommit", "serverImageSHA256", "sourceSHA256", "startUTC", "transferID"} {
		candidate = cloneMap(t, valid)
		candidate[field] = true
		if _, failure := ParseReceipt(candidate); failure == nil {
			t.Errorf("boolean %q accepted", field)
		}
	}
}

func TestUnsignedIntegerRejectsNonCanonicalAndOverflowValues(t *testing.T) {
	for _, number := range []json.Number{"-1", "01", "1.0", "18446744073709551616"} {
		m := cloneMap(t, validManifestMap())
		m["artifacts"].([]any)[0].(map[string]any)["size"] = number
		if _, failure := ParseManifest(m); failure == nil {
			t.Errorf("size %q accepted", number)
		}
	}
}
