package accountauth

import (
	"bytes"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"math"
	"time"

	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
)

type pendingSummary struct {
	RequestID  string `json:"requestID"`
	AccountID  string `json:"accountID"`
	GroupID    string `json:"groupID"`
	Generation uint64 `json:"generation"`
	DeviceID   string `json:"deviceID"`
	PublicKey  string `json:"publicKey"`
	Status     string `json:"status"`
	CreatedAt  int64  `json:"createdAt"`
	ExpiresAt  int64  `json:"expiresAt"`
}
type pendingRecordWire struct {
	pendingSummary
	Draft     *accountgroup.WireApprovalDraft `json:"draft"`
	Event     *accountgroup.WireEvent         `json:"event"`
	EventHash *string                         `json:"eventHash"`
}

func pendingActive(s string) bool { return s == "requested" || s == "proposed" || s == "countersigned" }
func pendingProofBinding(p accountgroup.PendingJoin, e accountgroup.Event) bool {
	return e.Action == accountgroup.ActionApprove && e.AccountID == p.AccountID && e.GroupID == p.GroupID && e.Generation == p.Generation && e.SubjectDeviceID == p.DeviceID && bytes.Equal(e.SubjectPublicKey, p.PublicKey)
}

// Validate the complete dependency record even when the response only carries a
// summary. Proofs are receipts, never a claim about the current membership head.
func pendingWire(p accountgroup.PendingJoin, account string) (pendingRecordWire, error) {
	bad := func() (pendingRecordWire, error) { return pendingRecordWire{}, errPayloadMalformed }
	if !validUUID(p.RequestID) || !validUUID(p.AccountID) || p.AccountID != account || !validUUID(p.GroupID) || !validUUID(p.DeviceID) || p.Generation == 0 || p.Generation > math.MaxInt64 || (len(p.PublicKey) != 64 && len(p.PublicKey) != 65) || auth.DeviceID(p.PublicKey) != p.DeviceID {
		return bad()
	}
	key := p.PublicKey
	if len(key) == 64 {
		key = append([]byte{4}, key...)
	}
	if x, _ := elliptic.Unmarshal(elliptic.P256(), key); x == nil {
		return bad()
	}
	const maxMillis int64 = 9007199254740991
	lower, upper := time.UnixMilli(1), time.UnixMilli(maxMillis)
	if p.CreatedAt.Before(lower) || p.CreatedAt.After(upper) || p.ExpiresAt.Before(lower) || p.ExpiresAt.After(upper) {
		return bad()
	}
	created, expires := p.CreatedAt.UnixMilli(), p.ExpiresAt.UnixMilli()
	if expires-created != 300000 || !p.ExpiresAt.Equal(p.CreatedAt.Add(5*time.Minute)) {
		return bad()
	}
	switch p.Status {
	case "requested":
		if p.Draft != nil || p.Event != nil || len(p.EventHash) != 0 {
			return bad()
		}
	case "proposed":
		if p.Draft == nil || p.Event != nil || len(p.EventHash) != 0 {
			return bad()
		}
	case "countersigned":
		if p.Draft == nil || p.Event == nil || len(p.EventHash) != 0 {
			return bad()
		}
	case "committed":
		if p.Draft == nil || p.Event == nil || len(p.EventHash) != 32 {
			return bad()
		}
	case "cancelled", "rejected", "expired", "invalidated":
		if len(p.EventHash) != 0 {
			return bad()
		}
	default:
		return bad()
	}
	if p.Event != nil && p.Draft == nil {
		return bad()
	}
	if p.Draft != nil {
		d, err := accountgroup.DecodeWireApprovalDraft(*p.Draft)
		if err != nil || !pendingProofBinding(p, d.Event()) {
			return bad()
		}
	}
	if p.Event != nil {
		e, err := accountgroup.DecodeWireEvent(*p.Event)
		if err != nil || !pendingProofBinding(p, e) || p.Draft.Payload != p.Event.Payload || p.Draft.Signature != p.Event.Signature {
			return bad()
		}
		if p.Status == "committed" {
			digest, err := e.Digest()
			if err != nil || !bytes.Equal(digest[:], p.EventHash) {
				return bad()
			}
		}
	}
	out := pendingRecordWire{pendingSummary: pendingSummary{p.RequestID, p.AccountID, p.GroupID, p.Generation, p.DeviceID, base64.StdEncoding.EncodeToString(p.PublicKey), p.Status, created, expires}, Draft: p.Draft, Event: p.Event}
	if len(p.EventHash) > 0 {
		hash := base64.StdEncoding.EncodeToString(p.EventHash)
		out.EventHash = &hash
	}
	return out, nil
}

func pendingResultMatches(p accountgroup.PendingJoin, f pendingInput, op string, a accountgroup.SessionActor, key []byte) bool {
	// Successful mutations cannot return a state preceding their transition.
	if (op == "propose" && p.Status == "requested") ||
		(op == "countersign" && (p.Status == "requested" || p.Status == "proposed")) ||
		((op == "commit" || op == "cancel" || op == "reject") && pendingActive(p.Status)) {
		return false
	}
	switch op {
	case "create":
		return p.GroupID == f.intent.GroupID && p.Generation == f.intent.Generation && p.DeviceID == a.DeviceID && bytes.Equal(p.PublicKey, key)
	case "cancel":
		return p.DeviceID == a.DeviceID && bytes.Equal(p.PublicKey, key)
	case "propose":
		e := f.draft.Event()
		if !pendingProofBinding(p, e) {
			return false
		}
		if p.Draft != nil {
			d, err := accountgroup.DecodeWireApprovalDraft(*p.Draft)
			if err != nil {
				return false
			}
			actual := d.Event()
			want, _ := e.CanonicalPayload()
			got, _ := actual.CanonicalPayload()
			return bytes.Equal(want, got)
		}
	case "countersign", "commit":
		if p.Draft == nil {
			return false
		}
		d, err := accountgroup.DecodeWireApprovalDraft(*p.Draft)
		if err != nil {
			return false
		}
		e := d.Event()
		raw, _ := e.CanonicalPayload()
		digest := sha256.Sum256(raw)
		if !bytes.Equal(digest[:], f.hash) {
			return false
		}
		if op == "countersign" {
			return p.DeviceID == a.DeviceID && bytes.Equal(p.PublicKey, key)
		}
		return e.ActorDeviceID == a.DeviceID && bytes.Equal(e.ActorPublicKey, key)
	}
	return true
}
