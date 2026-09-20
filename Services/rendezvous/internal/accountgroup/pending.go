package accountgroup

import "time"

type JoinIntent struct {
	RequestID, GroupID string
	Generation         uint64
	PublicKey          []byte
}

// PendingJoin contains proofs and historical receipts, never session metadata.
// A pending proof does not grant membership. Even a committed receipt does not
// assert membership at the current journal head.
type PendingJoin struct {
	RequestID, AccountID, GroupID string
	Generation                    uint64
	DeviceID                      string
	PublicKey                     []byte
	Status                        string
	CreatedAt, ExpiresAt          time.Time
	Draft                         *WireApprovalDraft
	Event                         *WireEvent
	EventHash                     []byte
}

type pendingRecord struct {
	PendingJoin
	subject, actor SessionActor
	digest         []byte
	draft          *ApprovalDraft
	event          *Event
}

func (p *pendingRecord) active() bool {
	return p.Status == "requested" || p.Status == "proposed" || p.Status == "countersigned"
}
