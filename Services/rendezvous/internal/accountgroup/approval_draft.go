package accountgroup

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
)

// ApprovalDraft is only an actor-signed proposal, never membership or consent.
// Its private storage and copied outputs preserve the exact signed key forms.
type ApprovalDraft struct{ event Event }

func NewApprovalDraft(event Event) (ApprovalDraft, error) {
	owned := copyStateEvent(event)
	if owned.Action != ActionApprove || len(owned.SubjectSignature) != 0 {
		return ApprovalDraft{}, ErrInvalidEvent
	}
	if _, err := owned.validateActorProof(); err != nil {
		return ApprovalDraft{}, ErrInvalidEvent
	}
	return ApprovalDraft{event: owned}, nil
}

func (d ApprovalDraft) Event() Event { return copyStateEvent(d.event) }

// Finalize adds only the joining proof. It does not establish freshness, session
// authority, current actor membership, or either user's explicit confirmation.
func (d ApprovalDraft) Finalize(subjectSignature []byte) (Event, error) {
	checked, err := NewApprovalDraft(d.event)
	if err != nil {
		return Event{}, ErrInvalidEvent
	}
	result := checked.Event()
	result.SubjectSignature = append([]byte(nil), subjectSignature...)
	if result.Validate() != nil {
		return Event{}, ErrInvalidEvent
	}
	return result, nil
}

type WireApprovalDraft struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

func EncodeWireApprovalDraft(d ApprovalDraft) (WireApprovalDraft, error) {
	checked, err := NewApprovalDraft(d.event)
	if err != nil {
		return WireApprovalDraft{}, ErrInvalidEvent
	}
	payload, err := checked.event.CanonicalPayload()
	if err != nil || base64.StdEncoding.EncodedLen(len(payload)) > 4096 {
		return WireApprovalDraft{}, ErrInvalidEvent
	}
	return WireApprovalDraft{base64.StdEncoding.EncodeToString(payload), base64.StdEncoding.EncodeToString(checked.event.Signature)}, nil
}

func DecodeWireApprovalDraft(w WireApprovalDraft) (ApprovalDraft, error) {
	payload, ok := wireBase64(w.Payload, 4096)
	if !ok {
		return ApprovalDraft{}, ErrInvalidEvent
	}
	signature, ok := wireBase64(w.Signature, 108)
	if !ok {
		return ApprovalDraft{}, ErrInvalidEvent
	}
	event, err := decodeCanonicalPayload(payload)
	if err != nil {
		return ApprovalDraft{}, ErrInvalidEvent
	}
	event.Signature = signature
	return NewApprovalDraft(event)
}

// DecodeWireApprovalDraftJSON is required at raw untrusted boundaries. Plain
// encoding/json struct decoding silently accepts duplicate and unknown keys.
func DecodeWireApprovalDraftJSON(data []byte) (WireApprovalDraft, error) {
	if len(data) > 8192 {
		return WireApprovalDraft{}, ErrInvalidEvent
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return WireApprovalDraft{}, ErrInvalidEvent
	}
	fields := map[string]string{}
	for decoder.More() {
		token, err = decoder.Token()
		if err != nil {
			return WireApprovalDraft{}, ErrInvalidEvent
		}
		key, ok := token.(string)
		if !ok || (key != "payload" && key != "signature") {
			return WireApprovalDraft{}, ErrInvalidEvent
		}
		if _, exists := fields[key]; exists {
			return WireApprovalDraft{}, ErrInvalidEvent
		}
		token, err = decoder.Token()
		if err != nil {
			return WireApprovalDraft{}, ErrInvalidEvent
		}
		value, ok := token.(string)
		if !ok {
			return WireApprovalDraft{}, ErrInvalidEvent
		}
		fields[key] = value
	}
	token, err = decoder.Token()
	if err != nil || token != json.Delim('}') || len(fields) != 2 {
		return WireApprovalDraft{}, ErrInvalidEvent
	}
	if _, err = decoder.Token(); err != io.EOF {
		return WireApprovalDraft{}, ErrInvalidEvent
	}
	w := WireApprovalDraft{fields["payload"], fields["signature"]}
	if _, ok := wireBase64(w.Payload, 4096); !ok {
		return WireApprovalDraft{}, ErrInvalidEvent
	}
	if _, ok := wireBase64(w.Signature, 108); !ok {
		return WireApprovalDraft{}, ErrInvalidEvent
	}
	return w, nil
}
