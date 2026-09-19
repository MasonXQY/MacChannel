// Package accountgroup defines the signed, device-authenticated event envelope
// for account group history. It deliberately does not decide whether an actor
// owns an account or is an authorized current member.
package accountgroup

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"

	"macchannel/rendezvous/internal/auth"
)

// ErrInvalidEvent is returned for every malformed or cryptographically invalid
// event. Callers must not rely on validation errors to disclose which evidence
// failed.
var ErrInvalidEvent = errors.New("invalid account group event")

type Action string

const (
	ActionBootstrap Action = "bootstrap"
	ActionApprove   Action = "approve"
	ActionRemove    Action = "remove"
)

type Event struct {
	AccountID         string
	GroupID           string
	Generation        uint64
	Sequence          uint64
	PreviousHash      []byte
	Action            Action
	ActorDeviceID     string
	ActorPublicKey    []byte
	SubjectDeviceID   string
	SubjectPublicKey  []byte
	EpochMilliseconds int64
	Signature         []byte
	SubjectSignature  []byte
}

// CanonicalPayload returns the deterministic bytes signed by devices. It checks
// structure and identity binding but intentionally permits missing signatures so
// a caller can construct an event before signing it.
func (e Event) CanonicalPayload() ([]byte, error) {
	if e.validateStructure() != nil {
		return nil, ErrInvalidEvent
	}
	payload := map[string]any{
		"accountID":         e.AccountID,
		"action":            e.Action,
		"actorDeviceID":     e.ActorDeviceID,
		"actorPublicKey":    base64.StdEncoding.EncodeToString(e.ActorPublicKey),
		"epochMilliseconds": e.EpochMilliseconds,
		"generation":        e.Generation,
		"groupID":           e.GroupID,
		"previousHash":      base64.StdEncoding.EncodeToString(e.PreviousHash),
		"purpose":           "dropmesh.account.group.event.v1",
		"sequence":          e.Sequence,
		"subjectDeviceID":   e.SubjectDeviceID,
		"subjectPublicKey":  base64.StdEncoding.EncodeToString(e.SubjectPublicKey),
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return nil, ErrInvalidEvent
	}
	return encoded, nil
}

// Validate verifies the event's structure and required device signatures. It
// does not check freshness, replay, account ownership, actor authority, pinned
// history, or user confirmation. Callers must authenticate the account session
// and actor possession; verify membership, generation, sequence, previous hash,
// and epoch against durably pinned history; accept bootstrap only after explicit
// owner confirmation; accept approve only after fingerprint confirmation and
// fresh joining-device consent; and scope removed-member events correctly.
func (e Event) Validate() error {
	payload, err := e.CanonicalPayload()
	if err != nil {
		return ErrInvalidEvent
	}
	if len(e.Signature) == 0 || len(e.Signature) > 80 {
		return ErrInvalidEvent
	}
	actor, err := parsePublicKey(e.ActorPublicKey)
	if err != nil {
		return ErrInvalidEvent
	}
	digest := sha256.Sum256(payload)
	if !ecdsa.VerifyASN1(actor, digest[:], e.Signature) {
		return ErrInvalidEvent
	}
	if e.Action == ActionApprove {
		if len(e.SubjectSignature) == 0 || len(e.SubjectSignature) > 80 {
			return ErrInvalidEvent
		}
		subject, err := parsePublicKey(e.SubjectPublicKey)
		if err != nil || !ecdsa.VerifyASN1(subject, digest[:], e.SubjectSignature) {
			return ErrInvalidEvent
		}
	} else if len(e.SubjectSignature) != 0 {
		return ErrInvalidEvent
	}
	return nil
}

// Digest identifies a validated event by its signature-independent canonical
// payload, so ECDSA signature randomness cannot fork the event identity.
func (e Event) Digest() ([32]byte, error) {
	if err := e.Validate(); err != nil {
		return [32]byte{}, ErrInvalidEvent
	}
	payload, err := e.CanonicalPayload()
	if err != nil {
		return [32]byte{}, ErrInvalidEvent
	}
	return sha256.Sum256(payload), nil
}

func (e Event) validateStructure() error {
	if !canonicalUUID(e.AccountID) || !canonicalUUID(e.GroupID) ||
		e.Generation == 0 || e.Generation > math.MaxInt64 ||
		e.Sequence == 0 || e.Sequence > math.MaxInt64 || e.EpochMilliseconds <= 0 {
		return ErrInvalidEvent
	}
	if _, err := parsePublicKey(e.ActorPublicKey); err != nil || auth.DeviceID(e.ActorPublicKey) != e.ActorDeviceID {
		return ErrInvalidEvent
	}
	if _, err := parsePublicKey(e.SubjectPublicKey); err != nil || auth.DeviceID(e.SubjectPublicKey) != e.SubjectDeviceID {
		return ErrInvalidEvent
	}

	switch e.Action {
	case ActionBootstrap:
		if e.Sequence != 1 || len(e.PreviousHash) != 0 || e.ActorDeviceID != e.SubjectDeviceID ||
			!bytes.Equal(e.ActorPublicKey, e.SubjectPublicKey) {
			return ErrInvalidEvent
		}
	case ActionApprove:
		if e.Sequence < 2 || len(e.PreviousHash) != sha256.Size || e.ActorDeviceID == e.SubjectDeviceID {
			return ErrInvalidEvent
		}
	case ActionRemove:
		if e.Sequence < 2 || len(e.PreviousHash) != sha256.Size {
			return ErrInvalidEvent
		}
		if e.ActorDeviceID == e.SubjectDeviceID && !bytes.Equal(e.ActorPublicKey, e.SubjectPublicKey) {
			return ErrInvalidEvent
		}
	default:
		return ErrInvalidEvent
	}
	return nil
}

func parsePublicKey(raw []byte) (*ecdsa.PublicKey, error) {
	encoded := raw
	if len(raw) == 64 {
		encoded = make([]byte, 65)
		encoded[0] = 4
		copy(encoded[1:], raw)
	} else if len(raw) != 65 || raw[0] != 4 {
		return nil, ErrInvalidEvent
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), encoded)
	if x == nil || y == nil {
		return nil, ErrInvalidEvent
	}
	return &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, nil
}

func canonicalUUID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}
	for index, character := range value {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			continue
		}
		if !((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')) {
			return false
		}
	}
	return true
}
