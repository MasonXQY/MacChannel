package accountinvite

import (
	"context"
	"database/sql"
	"macchannel/rendezvous/internal/accountgroup"
)

// Actor MUST come from authenticated device-bound access session plus signed
// outer request. Never construct AccountID from a caller payload. Each operation
// rechecks the exact session under account lifecycle locks.
type Actor struct {
	accountgroup.SessionActor
	PublicKey []byte
}
type Link struct {
	Version string `json:"version"`
	Hash    string `json:"hash"`
}
type Record struct {
	RequestID              string      `json:"requestID"`
	GrantID                string      `json:"grantID"`
	Revision               string      `json:"revision"`
	State                  string      `json:"state"`
	ProofDigest            string      `json:"proofDigest"`
	VerifiedAtMilliseconds string      `json:"verifiedAtMilliseconds"`
	Request                WireRequest `json:"request"`
	Pair                   *WirePair   `json:"pair"`
}

// Service carries no routing authority. Exact endpoint session/key and current
// member checks are still required by the later route integration.
type Service interface {
	GetLink(context.Context, Actor) (Link, error)
	RotateLink(context.Context, Actor, []byte) (Link, error)
	Request(context.Context, Actor, RequestProof) (Record, error)
	Get(context.Context, Actor, string) (Record, error)
	List(context.Context, Actor, bool, string, int) ([]Record, error) // inbox, afterRequestID, limit<=50
	Select(context.Context, Actor, string, Endpoint) (Record, error)
	Countersign(context.Context, Actor, string, []byte) (Record, error)
	Commit(context.Context, Actor, string, string) (Record, error)                    // requestID, proofDigest
	Transition(context.Context, Actor, string, string, int64, string) (Record, error) // requestID, reject/cancel/revoke, expectedRevision, proofDigest
	Block(context.Context, Actor, string, bool) error                                 // target account, disconnect existing
}
type PostgresStore struct {
	db        *sql.DB
	audiences map[string]bool
	origin    string
}

func NewPostgresStore(db *sql.DB, a []string, o string) (*PostgresStore, error) {
	if db == nil || len(a) == 0 || len(a) > 16 || !origin(o) {
		return nil, ErrInvalid
	}
	allowed := map[string]bool{}
	for _, v := range a {
		if !audience(v) {
			return nil, ErrInvalid
		}
		allowed[v] = true
	}
	return &PostgresStore{db, allowed, o}, nil
}
