package evidence

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"slices"
	"strings"
	"time"
)

const (
	manifestLimit    = 64 * 1024
	policyLimit      = 16 * 1024
	receiptLimit     = 64 * 1024
	artifactLimit    = 16 * 1024 * 1024
	totalBundleLimit = 128 * 1024 * 1024
	signatureDomain  = "DropMesh-Privacy-Fixture-v1\n"
	maxCaptureWindow = 48 * time.Hour
	maxEvidenceAge   = 24 * time.Hour
)

// Verify validates a fully loaded synthetic evidence bundle against a caller-
// supplied test trust policy. It performs no filesystem or network access.
func Verify(bundle Bundle, policyBytes []byte, now time.Time) *Failure {
	manifestObject, failure := ParseCanonical(bundle.Manifest, manifestLimit)
	if failure != nil {
		return failure
	}
	manifest, failure := ParseManifest(manifestObject)
	if failure != nil {
		return failure
	}

	policyObject, failure := ParseCanonical(policyBytes, policyLimit)
	if failure != nil {
		return &Failure{Category: InvalidPolicy}
	}
	policy, failure := ParsePolicy(policyObject)
	if failure != nil {
		return failure
	}
	key, ok := policyKey(policy, manifest.SignerID)
	if !ok || key.Revoked {
		return &Failure{Category: InvalidSignature}
	}
	publicKey, err := hex.DecodeString(key.PublicKeyHex)
	if err != nil || !verifySignature(publicKey, bundle.Signature, bundle.Manifest) {
		return &Failure{Category: InvalidSignature}
	}

	if failure := verifyInventory(bundle, manifest); failure != nil {
		return failure
	}
	receiptObject, failure := ParseCanonical(bundle.Artifacts["receipt.json"], receiptLimit)
	if failure != nil {
		return &Failure{Category: InvalidReceipt}
	}
	receipt, failure := ParseReceipt(receiptObject)
	if failure != nil || !receiptMatches(manifest, receipt) {
		return &Failure{Category: InvalidReceipt}
	}
	if !validTimes(manifest, key, now) {
		return &Failure{Category: InvalidTime}
	}
	return nil
}

func verifySignature(publicKey, signature, manifest []byte) bool {
	if len(publicKey) != ed25519.PublicKeySize || len(signature) != ed25519.SignatureSize {
		return false
	}
	message := make([]byte, 0, len(signatureDomain)+len(manifest))
	message = append(message, signatureDomain...)
	message = append(message, manifest...)
	return ed25519.Verify(ed25519.PublicKey(publicKey), message, signature)
}

func policyKey(policy Policy, signerID string) (PolicyKey, bool) {
	for _, key := range policy.Keys {
		if key.ID == signerID {
			return key, true
		}
	}
	return PolicyKey{}, false
}

func verifyInventory(bundle Bundle, manifest Manifest) *Failure {
	required := RequiredArtifactNames()
	if len(bundle.Artifacts) != len(required) {
		return &Failure{Category: InvalidInventory}
	}
	total := uint64(len(bundle.Manifest) + len(bundle.Signature))
	artifacts := make(map[string]Artifact, len(manifest.Artifacts))
	for _, artifact := range manifest.Artifacts {
		artifacts[artifact.Name] = artifact
	}
	for _, name := range required {
		content, ok := bundle.Artifacts[name]
		if !ok {
			return &Failure{Category: InvalidInventory}
		}
		if len(content) > artifactByteLimit(name) || (mustBeNonempty(name) && len(content) == 0) {
			return &Failure{Category: InvalidInventory}
		}
		total += uint64(len(content))
		if total > totalBundleLimit {
			return &Failure{Category: InvalidInventory}
		}
		expected, ok := artifacts[name]
		if !ok || !expected.Complete || expected.Size != uint64(len(content)) {
			return &Failure{Category: InvalidInventory}
		}
		digest := sha256.Sum256(content)
		if hex.EncodeToString(digest[:]) != expected.SHA256 {
			return &Failure{Category: InvalidInventory}
		}
		if name == "source.bin" && expected.SHA256 != manifest.SourceSHA256 {
			return &Failure{Category: InvalidInventory}
		}
		if name == "destination.bin" && expected.SHA256 != manifest.DestinationSHA256 {
			return &Failure{Category: InvalidInventory}
		}
	}
	return nil
}

func artifactByteLimit(name string) int {
	if name == "receipt.json" || name == "canaries.json" {
		return receiptLimit
	}
	return artifactLimit
}

func mustBeNonempty(name string) bool {
	return strings.HasSuffix(name, ".json") || name == "source.bin" || name == "destination.bin"
}

func receiptMatches(manifest Manifest, receipt Receipt) bool {
	return receipt.Completed &&
		receipt.TransferID == manifest.TransferID &&
		receipt.Route == manifest.Route &&
		receipt.CodeCommit == manifest.CodeCommit &&
		receipt.ServerCommit == manifest.ServerCommit &&
		receipt.ClientArchiveSHA256 == manifest.ClientArchiveSHA256 &&
		receipt.ServerImageSHA256 == manifest.ServerImageSHA256 &&
		receipt.SourceSHA256 == manifest.SourceSHA256 &&
		receipt.DestinationSHA256 == manifest.DestinationSHA256 &&
		receipt.StartUTC == manifest.StartUTC &&
		receipt.EndUTC == manifest.EndUTC &&
		slices.Equal(receipt.ContainerIDs, manifest.ContainerIDs)
}

func validTimes(manifest Manifest, key PolicyKey, now time.Time) bool {
	start, startOK := parseUTC(manifest.StartUTC)
	end, endOK := parseUTC(manifest.EndUTC)
	captureStart, captureStartOK := parseUTC(manifest.CaptureStartUTC)
	captureEnd, captureEndOK := parseUTC(manifest.CaptureEndUTC)
	notBefore, notBeforeOK := parseUTC(key.NotBeforeUTC)
	notAfter, notAfterOK := parseUTC(key.NotAfterUTC)
	if !startOK || !endOK || !captureStartOK || !captureEndOK || !notBeforeOK || !notAfterOK {
		return false
	}
	if captureStart.After(start) || start.After(end) || end.After(captureEnd) || captureEnd.After(now) {
		return false
	}
	if captureEnd.Sub(captureStart) > maxCaptureWindow || now.Sub(captureEnd) > maxEvidenceAge {
		return false
	}
	return !start.Before(notBefore) && !end.After(notAfter) && !now.Before(notBefore) && !now.After(notAfter)
}

func parseUTC(value string) (time.Time, bool) {
	parsed, err := time.Parse(utcLayout, value)
	return parsed, err == nil
}
