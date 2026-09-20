package routeauth

import (
	"context"
	"errors"
	"sync/atomic"

	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/signal"
)

// ErrDenied is the only external route failure. It does not distinguish absent
// peers, missing memberships, account service failure or local saturation.
var ErrDenied = errors.New("route unavailable")

type AuthoritySource uint8

const (
	NoAuthority AuthoritySource = iota
	Manual
	AccountGroup
)

// RouteOutcome describes a frame already enqueued, not authority for another
// frame. CleanupFailed is a redacted diagnostic; never retry an admitted frame.
type RouteOutcome struct {
	Source        AuthoritySource
	CleanupFailed bool
}

// AccountGate must call its callback synchronously, at most once, under current
// two-endpoint authority. It must not retain the callback. The Postgres adapter
// implements this with accountgroup.AdmitRoute; it cannot promise distributed
// atomicity if the database session fails independently of this process.
type AccountGate interface {
	Admit(context.Context, accountgroup.RouteAdmissionRequest, func() bool) (accountgroup.RouteAdmissionOutcome, error)
}
type Policy struct {
	owner   *ConnectionOwner
	manual  signal.TrustGraph
	account AccountGate
}

func NewManualPolicy(o *ConnectionOwner, g signal.TrustGraph) *Policy {
	return &Policy{owner: o, manual: g}
}
func NewCompositePolicy(o *ConnectionOwner, g signal.TrustGraph, a AccountGate) *Policy {
	return &Policy{o, g, a}
}

// Route tries manual authority first, then direct account-pair admission. It
// copies payload before either authority call; callers must not mutate payload
// concurrently with that copy. No network send or graph publication occurs.
func (p *Policy) Route(ctx context.Context, from ConnectionHandle, target string, payload []byte) (RouteOutcome, error) {
	if p == nil || p.owner == nil || ctx == nil || ctx.Err() != nil || len(payload) == 0 || len(payload) > signal.MaximumFrameSize {
		return RouteOutcome{}, ErrDenied
	}
	// Copy before any graph/gate call; the caller can reuse its input once this
	// call returns, and the destination queue owns its frame until dequeue.
	frame := signal.Frame{Type: "signal", From: from.deviceID, Payload: append([]byte(nil), payload...)}
	pair, ok := p.owner.snapshot(from, target, false)
	if !ok {
		return RouteOutcome{}, ErrDenied
	}
	// No owner lock is held across either authority provider. The manual graph
	// remains independent and retains its existing transitive semantics.
	if p.manual != nil && p.manual.ShareGraph(from.deviceID, target) {
		if ctx.Err() == nil && p.owner.enqueue(pair, frame, false) {
			return RouteOutcome{Source: Manual}, nil
		}
		return RouteOutcome{}, ErrDenied
	}
	if p.account == nil || ctx.Err() != nil {
		return RouteOutcome{}, ErrDenied
	}
	pair, ok = p.owner.snapshot(from, target, true)
	if !ok {
		return RouteOutcome{}, ErrDenied
	}
	a, b := pair.from.binding, pair.to.binding
	if a.Actor.AccountID != b.Actor.AccountID || a.GroupID != b.GroupID || a.Generation != b.Generation {
		return RouteOutcome{}, ErrDenied
	}
	req := accountgroup.RouteAdmissionRequest{
		From:    accountgroup.RouteEndpoint{Actor: a.Actor, PublicKey: pair.from.publicKey, ConnectionGeneration: pair.from.handle.generation},
		To:      accountgroup.RouteEndpoint{Actor: b.Actor, PublicKey: pair.to.publicKey, ConnectionGeneration: pair.to.handle.generation},
		GroupID: a.GroupID, Generation: a.Generation,
	}
	// Defensively reject repeated or retained callbacks. Gates must still obey
	// the synchronous authority contract: arbitrary asynchronous execution cannot
	// retain a SQL transaction's authority after that transaction has returned.
	var state atomic.Uint32 // 0 open, 1 used, 2 closed without callback
	var enqueued atomic.Bool
	out, err := p.account.Admit(ctx, req, func() bool {
		if !state.CompareAndSwap(0, 1) || ctx.Err() != nil {
			return false
		}
		ok := p.owner.enqueue(pair, frame, true)
		enqueued.Store(ok)
		return ok
	})
	state.CompareAndSwap(0, 2)
	if !enqueued.Load() {
		return RouteOutcome{}, ErrDenied
	}
	// Actual insertion is irrevocable even if a gate reports an inconsistent
	// post-insertion failure. Do not fallback or enqueue again.
	return RouteOutcome{Source: AccountGroup, CleanupFailed: out.CleanupError != nil || err != nil || !out.Admitted}, nil
}

func (*Policy) String() string     { return "<routeauth.Policy>" }
func (p *Policy) GoString() string { return p.String() }
