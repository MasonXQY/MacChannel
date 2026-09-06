package evidence

import (
	"encoding/json"
	"regexp"
	"slices"
	"strconv"
	"time"
)

const utcLayout = "2006-01-02T15:04:05Z"

var (
	lowerHex40      = regexp.MustCompile(`^[0-9a-f]{40}$`)
	lowerHex64      = regexp.MustCompile(`^[0-9a-f]{64}$`)
	signerIDPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
	canaryIDPattern = regexp.MustCompile(`^[A-Za-z0-9-]{16,128}$`)
	uuidPattern     = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

var requiredArtifacts = []string{
	"backups.json", "canaries.json", "client.log", "compose.json", "coturn.log",
	"database-after.json", "database-before.json", "destination.bin", "host.log",
	"inspect.json", "metrics.txt", "monitoring.json", "mounts.json", "proxy.log",
	"receipt.json", "rendezvous.log", "source.bin",
}

type Artifact struct {
	Name     string
	Size     uint64
	SHA256   string
	Complete bool
}

type Manifest struct {
	SchemaVersion                                     uint64
	EvidenceClass, SignerID, CodeCommit, ServerCommit string
	ClientArchiveSHA256, ServerImageSHA256            string
	TransferID, CanaryID, Route                       string
	SourceSHA256, DestinationSHA256                   string
	StartUTC, EndUTC, CaptureStartUTC, CaptureEndUTC  string
	ContainerIDs                                      []string
	Artifacts                                         []Artifact
}

type Receipt struct {
	TransferID, Route, CodeCommit, ServerCommit string
	ClientArchiveSHA256, ServerImageSHA256      string
	SourceSHA256, DestinationSHA256             string
	StartUTC, EndUTC                            string
	ContainerIDs                                []string
	Completed                                   bool
}

type PolicyKey struct {
	ID, PublicKeyHex, NotBeforeUTC, NotAfterUTC string
	Revoked                                     bool
}

type Policy struct {
	SchemaVersion uint64
	Keys          []PolicyKey
}

func RequiredArtifactNames() []string { return slices.Clone(requiredArtifacts) }

func ParseManifest(object map[string]any) (Manifest, *Failure) {
	var out Manifest
	if !exactKeys(object, "artifacts", "canaryID", "captureEndUTC", "captureStartUTC", "clientArchiveSHA256", "codeCommit", "containerIDs", "destinationSHA256", "endUTC", "evidenceClass", "route", "schemaVersion", "serverCommit", "serverImageSHA256", "signerID", "sourceSHA256", "startUTC", "transferID") {
		return out, schemaFailure()
	}
	var ok bool
	if out.SchemaVersion, ok = integer(object, "schemaVersion"); !ok || out.SchemaVersion != 1 {
		return out, schemaFailure()
	}
	if out.EvidenceClass, ok = stringValue(object, "evidenceClass"); !ok || out.EvidenceClass != "synthetic-fixture" {
		return out, schemaFailure()
	}
	if out.SignerID, ok = stringValue(object, "signerID"); !ok || !signerIDPattern.MatchString(out.SignerID) {
		return out, schemaFailure()
	}
	for key, destination := range map[string]*string{
		"codeCommit": &out.CodeCommit, "serverCommit": &out.ServerCommit,
	} {
		if *destination, ok = stringValue(object, key); !ok || !lowerHex40.MatchString(*destination) {
			return out, schemaFailure()
		}
	}
	for key, destination := range map[string]*string{
		"clientArchiveSHA256": &out.ClientArchiveSHA256, "serverImageSHA256": &out.ServerImageSHA256,
		"sourceSHA256": &out.SourceSHA256, "destinationSHA256": &out.DestinationSHA256,
	} {
		if *destination, ok = stringValue(object, key); !ok || !lowerHex64.MatchString(*destination) {
			return out, schemaFailure()
		}
	}
	if out.SourceSHA256 != out.DestinationSHA256 {
		return out, schemaFailure()
	}
	if out.TransferID, ok = stringValue(object, "transferID"); !ok || !uuidPattern.MatchString(out.TransferID) {
		return out, schemaFailure()
	}
	if out.CanaryID, ok = stringValue(object, "canaryID"); !ok || !canaryIDPattern.MatchString(out.CanaryID) {
		return out, schemaFailure()
	}
	if out.Route, ok = stringValue(object, "route"); !ok || (out.Route != "directInternet" && out.Route != "relay") {
		return out, schemaFailure()
	}
	for key, destination := range map[string]*string{"startUTC": &out.StartUTC, "endUTC": &out.EndUTC, "captureStartUTC": &out.CaptureStartUTC, "captureEndUTC": &out.CaptureEndUTC} {
		if *destination, ok = stringValue(object, key); !ok || !validUTC(*destination) {
			return out, schemaFailure()
		}
	}
	if out.ContainerIDs, ok = stringArray(object, "containerIDs", 1, 32, lowerHex64); !ok {
		return out, schemaFailure()
	}
	values, ok := object["artifacts"].([]any)
	if !ok || len(values) != len(requiredArtifacts) {
		return out, schemaFailure()
	}
	out.Artifacts = make([]Artifact, len(values))
	for i, value := range values {
		entry, ok := value.(map[string]any)
		if !ok || !exactKeys(entry, "complete", "name", "sha256", "size") {
			return Manifest{}, schemaFailure()
		}
		artifact := Artifact{}
		if artifact.Name, ok = stringValue(entry, "name"); !ok || artifact.Name != requiredArtifacts[i] {
			return Manifest{}, schemaFailure()
		}
		if artifact.Size, ok = integer(entry, "size"); !ok {
			return Manifest{}, schemaFailure()
		}
		if artifact.SHA256, ok = stringValue(entry, "sha256"); !ok || !lowerHex64.MatchString(artifact.SHA256) {
			return Manifest{}, schemaFailure()
		}
		if artifact.Complete, ok = boolValue(entry, "complete"); !ok || !artifact.Complete {
			return Manifest{}, schemaFailure()
		}
		out.Artifacts[i] = artifact
	}
	return out, nil
}

func ParseReceipt(object map[string]any) (Receipt, *Failure) {
	var out Receipt
	if !exactKeys(object, "clientArchiveSHA256", "codeCommit", "completed", "containerIDs", "destinationSHA256", "endUTC", "route", "serverCommit", "serverImageSHA256", "sourceSHA256", "startUTC", "transferID") {
		return out, &Failure{Category: InvalidReceipt}
	}
	var ok bool
	for key, destination := range map[string]*string{"codeCommit": &out.CodeCommit, "serverCommit": &out.ServerCommit} {
		if *destination, ok = stringValue(object, key); !ok || !lowerHex40.MatchString(*destination) {
			return Receipt{}, &Failure{Category: InvalidReceipt}
		}
	}
	for key, destination := range map[string]*string{"clientArchiveSHA256": &out.ClientArchiveSHA256, "serverImageSHA256": &out.ServerImageSHA256, "sourceSHA256": &out.SourceSHA256, "destinationSHA256": &out.DestinationSHA256} {
		if *destination, ok = stringValue(object, key); !ok || !lowerHex64.MatchString(*destination) {
			return Receipt{}, &Failure{Category: InvalidReceipt}
		}
	}
	if out.TransferID, ok = stringValue(object, "transferID"); !ok || !uuidPattern.MatchString(out.TransferID) {
		return Receipt{}, &Failure{Category: InvalidReceipt}
	}
	if out.Route, ok = stringValue(object, "route"); !ok || (out.Route != "directInternet" && out.Route != "relay") {
		return Receipt{}, &Failure{Category: InvalidReceipt}
	}
	for key, destination := range map[string]*string{"startUTC": &out.StartUTC, "endUTC": &out.EndUTC} {
		if *destination, ok = stringValue(object, key); !ok || !validUTC(*destination) {
			return Receipt{}, &Failure{Category: InvalidReceipt}
		}
	}
	if out.ContainerIDs, ok = stringArray(object, "containerIDs", 1, 32, lowerHex64); !ok {
		return Receipt{}, &Failure{Category: InvalidReceipt}
	}
	if out.Completed, ok = boolValue(object, "completed"); !ok || !out.Completed {
		return Receipt{}, &Failure{Category: InvalidReceipt}
	}
	return out, nil
}

func ParsePolicy(object map[string]any) (Policy, *Failure) {
	var out Policy
	failure := &Failure{Category: InvalidPolicy}
	if !exactKeys(object, "keys", "schemaVersion") {
		return out, failure
	}
	var ok bool
	if out.SchemaVersion, ok = integer(object, "schemaVersion"); !ok || out.SchemaVersion != 1 {
		return out, failure
	}
	values, ok := object["keys"].([]any)
	if !ok || len(values) < 1 || len(values) > 8 {
		return out, failure
	}
	seen := make(map[string]bool, len(values))
	for _, value := range values {
		entry, ok := value.(map[string]any)
		if !ok || !exactKeys(entry, "id", "notAfterUTC", "notBeforeUTC", "publicKeyHex", "revoked") {
			return Policy{}, failure
		}
		key := PolicyKey{}
		if key.ID, ok = stringValue(entry, "id"); !ok || !signerIDPattern.MatchString(key.ID) || seen[key.ID] {
			return Policy{}, failure
		}
		seen[key.ID] = true
		if key.PublicKeyHex, ok = stringValue(entry, "publicKeyHex"); !ok || !lowerHex64.MatchString(key.PublicKeyHex) {
			return Policy{}, failure
		}
		if key.NotBeforeUTC, ok = stringValue(entry, "notBeforeUTC"); !ok || !validUTC(key.NotBeforeUTC) {
			return Policy{}, failure
		}
		if key.NotAfterUTC, ok = stringValue(entry, "notAfterUTC"); !ok || !validUTC(key.NotAfterUTC) {
			return Policy{}, failure
		}
		if key.Revoked, ok = boolValue(entry, "revoked"); !ok {
			return Policy{}, failure
		}
		out.Keys = append(out.Keys, key)
	}
	return out, nil
}

func exactKeys(object map[string]any, keys ...string) bool {
	if len(object) != len(keys) {
		return false
	}
	for _, key := range keys {
		if _, ok := object[key]; !ok {
			return false
		}
	}
	return true
}

func stringValue(object map[string]any, key string) (string, bool) {
	value, ok := object[key].(string)
	return value, ok
}
func boolValue(object map[string]any, key string) (bool, bool) {
	value, ok := object[key].(bool)
	return value, ok
}
func integer(object map[string]any, key string) (uint64, bool) {
	number, ok := object[key].(json.Number)
	if !ok || !unsignedInteger.MatchString(number.String()) {
		return 0, false
	}
	value, err := strconv.ParseUint(number.String(), 10, 64)
	return value, err == nil
}
func validUTC(value string) bool {
	parsed, err := time.Parse(utcLayout, value)
	return err == nil && parsed.Format(utcLayout) == value
}
func stringArray(object map[string]any, key string, min, max int, pattern *regexp.Regexp) ([]string, bool) {
	values, ok := object[key].([]any)
	if !ok || len(values) < min || len(values) > max {
		return nil, false
	}
	out := make([]string, len(values))
	previous := ""
	for i, value := range values {
		text, ok := value.(string)
		if !ok || !pattern.MatchString(text) || (i > 0 && text <= previous) {
			return nil, false
		}
		out[i], previous = text, text
	}
	return out, true
}
