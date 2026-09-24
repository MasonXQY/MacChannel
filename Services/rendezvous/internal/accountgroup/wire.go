package accountgroup

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
)

type WireEvent struct {
	Payload          string `json:"payload"`
	Signature        string `json:"signature"`
	SubjectSignature string `json:"subjectSignature"`
}

// EncodeWireEvent carries the existing signed bytes without inventing another
// event identity or normalizing the 64/65-byte public key representation.
func EncodeWireEvent(e Event) (WireEvent, error) {
	if e.Validate() != nil {
		return WireEvent{}, ErrInvalidEvent
	}
	payload, err := e.CanonicalPayload()
	if err != nil || base64.StdEncoding.EncodedLen(len(payload)) > 4096 {
		return WireEvent{}, ErrInvalidEvent
	}
	return WireEvent{base64.StdEncoding.EncodeToString(payload), base64.StdEncoding.EncodeToString(e.Signature), base64.StdEncoding.EncodeToString(e.SubjectSignature)}, nil
}

// DecodeWireEvent accepts only the precise canonical JSON bytes signed by the
// event's devices. Re-encoding equality also rejects duplicate, omitted, extra,
// case-folded, null, reordered and noncanonical JSON fields and numeric forms.
// All decoded buffers belong to the caller.
func DecodeWireEvent(w WireEvent) (Event, error) {
	payload, ok := wireBase64(w.Payload, 4096)
	if !ok {
		return Event{}, ErrInvalidEvent
	}
	signature, ok := wireBase64(w.Signature, 108)
	if !ok {
		return Event{}, ErrInvalidEvent
	}
	subjectSignature, ok := wireBase64(w.SubjectSignature, 108)
	if !ok {
		return Event{}, ErrInvalidEvent
	}
	e, err := decodeCanonicalPayload(payload)
	if err != nil {
		return Event{}, ErrInvalidEvent
	}
	e.Signature, e.SubjectSignature = signature, subjectSignature
	if e.Validate() != nil {
		return Event{}, ErrInvalidEvent
	}
	return e, nil
}

// Structure and exact canonical bytes only; each envelope checks its own proofs.
func decodeCanonicalPayload(payload []byte) (Event, error) {
	var p struct {
		AccountID         string `json:"accountID"`
		Action            Action `json:"action"`
		ActorDeviceID     string `json:"actorDeviceID"`
		ActorPublicKey    string `json:"actorPublicKey"`
		EpochMilliseconds int64  `json:"epochMilliseconds"`
		Generation        uint64 `json:"generation"`
		GroupID           string `json:"groupID"`
		PreviousHash      string `json:"previousHash"`
		Purpose           string `json:"purpose"`
		Sequence          uint64 `json:"sequence"`
		SubjectDeviceID   string `json:"subjectDeviceID"`
		SubjectPublicKey  string `json:"subjectPublicKey"`
	}
	if json.Unmarshal(payload, &p) != nil || p.Purpose != "dropmesh.account.group.event.v1" {
		return Event{}, ErrInvalidEvent
	}
	actor, ok := wireBase64(p.ActorPublicKey, 88)
	if !ok {
		return Event{}, ErrInvalidEvent
	}
	subject, ok := wireBase64(p.SubjectPublicKey, 88)
	if !ok {
		return Event{}, ErrInvalidEvent
	}
	previous, ok := wireBase64(p.PreviousHash, 44)
	if !ok {
		return Event{}, ErrInvalidEvent
	}
	e := Event{AccountID: p.AccountID, GroupID: p.GroupID, Generation: p.Generation, Sequence: p.Sequence, PreviousHash: previous, Action: p.Action, ActorDeviceID: p.ActorDeviceID, ActorPublicKey: actor, SubjectDeviceID: p.SubjectDeviceID, SubjectPublicKey: subject, EpochMilliseconds: p.EpochMilliseconds}
	canonical, err := e.CanonicalPayload()
	if err != nil || !bytes.Equal(payload, canonical) {
		return Event{}, ErrInvalidEvent
	}
	return e, nil
}

func wireBase64(s string, max int) ([]byte, bool) {
	if len(s) > max {
		return nil, false
	}
	b, err := base64.StdEncoding.Strict().DecodeString(s)
	return b, err == nil && base64.StdEncoding.EncodeToString(b) == s
}
